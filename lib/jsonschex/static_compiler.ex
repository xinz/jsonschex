defmodule JSONSchex.StaticCompiler do
  @moduledoc """
  Compiles a static `JSONSchex.Types.Schema` into native Elixir AST for BEAM JIT execution.

  Used by `JSONSchex.Schema.defvalidator/3` to emit specialized function clauses,
  map pattern matches, guard checks, and tail-recursive list validators at compile time.

  Keywords outside the static subset (such as `$ref`, `$dynamicRef`, `unevaluatedProperties`,
  `unevaluatedItems`, or `contentSchema`) use the short-circuit validator with the
  original root schema and the enclosing resource's reference scope.
  """

  alias JSONSchex.Guards
  alias JSONSchex.Types.{Rule, Schema, ValidationContext}
  alias JSONSchex.Validator.{Reference, ShortCircuit}

  @doc false
  @spec compile(atom(), Schema.t()) :: {Macro.t(), [Macro.t()], boolean()}
  def compile(prefix, %Schema{} = schema) when is_atom(prefix) do
    var = Macro.var(:data, __MODULE__)
    state = %{
      prefix: prefix,
      counter: 0,
      helpers: [],
      may_abort_on_pattern?: false,
      context: ValidationContext.from_root_schema(schema),
      context_helper: nil
    }
    {expr, final_state} = compile_schema(schema, var, state)
    {expr, Enum.reverse(final_state.helpers), final_state.may_abort_on_pattern?}
  end

  # --- Schema Node Compilation ---

  # Static traversal only follows structural children. Compute their context at
  # compile time; crossing a reference (and its dynamic scope) is the engine's job.
  defp compile_schema(%Schema{source_id: id} = schema, var, %{context: parent} = state)
       when id != nil and id != parent.source_id do
    child = Reference.context_for_child(schema, parent)
    {ast, next} = compile_rules_node(schema, var, %{state | context: child, context_helper: nil})
    {ast, %{next | context: parent, context_helper: state.context_helper}}
  end

  defp compile_schema(%Schema{} = schema, var, state) do
    compile_rules_node(schema, var, state)
  end

  defp compile_rules_node(%Schema{needs_evaluated_annotations: true} = schema, var, state) do
    fallback_schema(schema, var, state)
  end

  defp compile_rules_node(%Schema{rules: []}, _var, state), do: {true, state}

  defp compile_rules_node(%Schema{rules: [%Rule{name: :boolean_schema}]}, _var, state),
    do: {false, state}

  defp compile_rules_node(%Schema{rules: rules} = schema, var, state) do
    # If there is a :ref or :dynamicRef rule, fall back for the whole node so
    # root defs and ValidationContext remain intact.
    if has_ref_rule?(rules) do
      fallback_schema(schema, var, state)
    else
      narrowed_type = extract_single_type(rules)

      # Optimize the common object pattern: type == "object" + required + properties
      case extract_object_bundle(rules, narrowed_type) do
        {:ok, required_keys, props_list, remaining_rules} ->
          compile_object_bundle(required_keys, props_list, remaining_rules, schema, var, state)

        :none ->
          compile_rule_list(rules, narrowed_type, schema, var, state)
      end
    end
  end

  defp extract_single_type(rules) do
    case Enum.find(rules, &(&1.name == :type)) do
      %Rule{params: t} when is_binary(t) -> t
      _ -> nil
    end
  end

  defp has_ref_rule?(rules) do
    Enum.any?(rules, &(&1.name in [:ref, :dynamicRef]))
  end

  defp extract_object_bundle(rules, "object") do
    req_rule = Enum.find(rules, &(&1.name == :required))
    props_rule = Enum.find(rules, &(&1.name == :properties))

    case {req_rule, props_rule} do
      {%Rule{params: req_keys}, %Rule{params: props_list}} when req_keys != [] ->
        remaining =
          Enum.reject(rules, &(&1.name in [:type, :required, :properties]))

        {:ok, Enum.uniq(req_keys), props_list, remaining}

      _ ->
        :none
    end
  end

  defp extract_object_bundle(_rules, _narrowed_type), do: :none

  defp compile_object_bundle(required_keys, props_list, remaining_rules, schema, var, state) do
    props_map = Map.new(props_list)
    required_set = MapSet.new(required_keys)

    # Build a single BEAM map pattern `%{"k1" => v1, "k2" => v2, ...}` that checks
    # all required keys AND binds values for those that also appear in `properties`.
    {map_pairs, req_checks, state} =
      Enum.reduce(required_keys, {[], [], state}, fn key, {pairs, checks, acc_state} ->
        case Map.fetch(props_map, key) do
          {:ok, sub_schema} ->
            {prop_var, acc_state} = next_var("v", acc_state)
            {sub_ast, acc_state} = compile_schema(sub_schema, prop_var, acc_state)

            case split_const_bool(sub_ast) do
              {:ok, [], true} ->
                {[{key, quote(do: _)} | pairs], checks, acc_state}

              _ ->
                {[{key, prop_var} | pairs], [sub_ast | checks], acc_state}
            end

          :error ->
            {[{key, quote(do: _)} | pairs], checks, acc_state}
        end
      end)

    # Optional properties (in `properties` but not in `required`)
    optional_props = Enum.reject(props_list, fn {k, _} -> MapSet.member?(required_set, k) end)

    {opt_checks, state} =
      compile_optional_properties(optional_props, "opt", var, state)

    # Remaining rules on the object (e.g. additionalProperties, minProperties, maxProperties)
    {rem_ast, state} =
      case remaining_rules do
        [] -> {true, state}
        _ -> compile_rule_list(remaining_rules, "object", schema, var, state)
      end

    all_checks =
      (Enum.reverse(req_checks) ++ opt_checks ++ [rem_ast])
      |> combine_and()

    ast =
      case split_const_bool(all_checks) do
        {:ok, [], false} ->
          false

        {:ok, stmts, false} ->
          map_pattern = {:%{}, [], Enum.reverse(map_pairs)}

          quote do
            case unquote(var) do
              unquote(map_pattern) -> unquote(prepend_stmts(stmts, :ok))
              _ -> :ok
            end

            false
          end

        _ ->
          map_pattern = {:%{}, [], Enum.reverse(map_pairs)}

          quote do
            case unquote(var) do
              unquote(map_pattern) -> unquote(all_checks)
              _ -> false
            end
          end
      end

    {ast, state}
  end

  defp compile_rule_list(rules, narrowed_type, schema, var, state) do
    # Ensure `:type` rule runs first so subsequent rules can rely on `narrowed_type`
    ordered =
      case Enum.split_with(rules, &(&1.name == :type)) do
        {[], rest} -> rest
        {type_rules, rest} -> type_rules ++ rest
      end

    has_min_length? = Enum.any?(ordered, &(&1.name == :minLength))

    {asts, state} =
      Enum.reduce(ordered, {[], state}, fn rule, {acc, acc_state} ->
        {rule_ast, acc_state} =
          compile_rule(rule, narrowed_type, has_min_length?, schema, var, acc_state)

        {[rule_ast | acc], acc_state}
      end)

    {asts |> Enum.reverse() |> combine_and(), state}
  end

  # --- Individual Rule Compilation ---

  defp compile_rule(%Rule{name: :maxLength, params: max}, "string", true, _schema, var, state) do
    # A sibling `minLength` rule in the same `and` chain validates UTF-8, so
    # `maxLength` can accept `byte_size(var) <= max` without an extra scan.
    ast =
      quote do
        byte_size(unquote(var)) <= unquote(max) or
          JSONSchex.Compiler.Predicates.valid_max_length?(unquote(var), unquote(max))
      end

    {ast, state}
  end

  defp compile_rule(rule, narrowed_type, _has_min_length?, schema, var, state) do
    compile_rule(rule, narrowed_type, schema, var, state)
  end

  defp compile_rule(%Rule{name: :boolean_schema}, _type, _schema, _var, state), do: {false, state}

  defp compile_rule(%Rule{name: :type, params: type}, _type, _schema, var, state) do
    {compile_type_check(type, var), state}
  end

  defp compile_rule(%Rule{name: :minimum, params: min}, type, _schema, var, state) do
    ast =
      if type in ["integer", "number"] do
        quote do: unquote(var) >= unquote(min)
      else
        quote do: not is_number(unquote(var)) or unquote(var) >= unquote(min)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :maximum, params: max}, type, _schema, var, state) do
    ast =
      if type in ["integer", "number"] do
        quote do: unquote(var) <= unquote(max)
      else
        quote do: not is_number(unquote(var)) or unquote(var) <= unquote(max)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :exclusiveMinimum, params: min}, type, _schema, var, state) do
    ast =
      if type in ["integer", "number"] do
        quote do: unquote(var) > unquote(min)
      else
        quote do: not is_number(unquote(var)) or unquote(var) > unquote(min)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :exclusiveMaximum, params: max}, type, _schema, var, state) do
    ast =
      if type in ["integer", "number"] do
        quote do: unquote(var) < unquote(max)
      else
        quote do: not is_number(unquote(var)) or unquote(var) < unquote(max)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :multipleOf, params: 0}, _type, _schema, _var, state),
    do: {false, state}

  defp compile_rule(%Rule{name: :multipleOf, params: +0.0}, _type, _schema, _var, state),
    do: {false, state}

  defp compile_rule(%Rule{name: :multipleOf, params: factor}, type, _schema, var, state) do
    check =
      quote do
        JSONSchex.Compiler.Predicates.MultipleOf.valid?(unquote(var), unquote(factor))
      end

    ast =
      if type in ["integer", "number"] do
        check
      else
        quote do: not is_number(unquote(var)) or unquote(check)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :minLength, params: 0}, type, _schema, var, state) do
    # Still must reject malformed UTF-8 strings per JSONSchex semantics
    check = quote(do: String.valid?(unquote(var)))

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :minLength, params: 1}, type, _schema, var, state) do
    # Any valid UTF-8 binary with byte_size >= 1 has at least 1 code point
    check = quote(do: byte_size(unquote(var)) >= 1 and String.valid?(unquote(var)))

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :minLength, params: min}, type, _schema, var, state) do
    check =
      quote do
        byte_size(unquote(var)) >= unquote(min) and
          JSONSchex.Compiler.Predicates.valid_min_length?(unquote(var), unquote(min))
      end

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :maxLength, params: max}, type, _schema, var, state) do
    # In UTF-8, codepoint count <= byte_size always; if byte_size <= max and valid UTF-8,
    # no codepoint counting is needed!
    check =
      quote do
        (byte_size(unquote(var)) <= unquote(max) and String.valid?(unquote(var))) or
          JSONSchex.Compiler.Predicates.valid_max_length?(unquote(var), unquote(max))
      end

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :pattern, params: %{matcher: matcher}}, type, _schema, var, state) do
    check =
      quote do
        JSONSchex.PredefinedPattern.match?(unquote(Macro.escape(matcher)), unquote(var))
      end

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :pattern, params: %{regex: regex}}, type, _schema, var, state) do
    check =
      quote do
        JSONSchex.Validator.Pattern.match?(unquote(Macro.escape(regex)), unquote(var), [])
      end

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, %{state | may_abort_on_pattern?: true}}
  end

  defp compile_rule(%Rule{name: :format, params: format}, type, _schema, var, state) do
    check = quote(do: JSONSchex.Formats.valid?(unquote(format), unquote(var)))

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :minProperties, params: min}, type, _schema, var, state) do
    ast =
      if type == "object" do
        quote do: map_size(unquote(var)) >= unquote(min)
      else
        quote do: not is_map(unquote(var)) or map_size(unquote(var)) >= unquote(min)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :maxProperties, params: max}, type, _schema, var, state) do
    ast =
      if type == "object" do
        quote do: map_size(unquote(var)) <= unquote(max)
      else
        quote do: not is_map(unquote(var)) or map_size(unquote(var)) <= unquote(max)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :minItems, params: min}, type, _schema, var, state) do
    ast =
      if type == "array" do
        quote do: length(unquote(var)) >= unquote(min)
      else
        quote do: not is_list(unquote(var)) or length(unquote(var)) >= unquote(min)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :maxItems, params: max}, type, _schema, var, state) do
    ast =
      if type == "array" do
        quote do: length(unquote(var)) <= unquote(max)
      else
        quote do: not is_list(unquote(var)) or length(unquote(var)) <= unquote(max)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :uniqueItems, params: true}, type, _schema, var, state) do
    check = quote(do: JSONSchex.Compiler.Predicates.valid_unique_items?(unquote(var)))

    ast =
      if type == "array", do: check, else: quote(do: not is_list(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :uniqueItems, params: false}, _type, _schema, _var, state),
    do: {true, state}

  defp compile_rule(%Rule{name: :const, params: value}, _type, _schema, var, state) do
    {quote(do: unquote(var) == unquote(Macro.escape(value))), state}
  end

  defp compile_rule(%Rule{name: :enum, params: values}, _type, _schema, var, state) do
    # `in` uses `===` which breaks JSON numeric equality (`1 == 1.0`), so only use `in`
    # when all enum values are strings/atoms/booleans/nil.
    ast =
      if Enum.all?(values, &(is_binary(&1) or is_boolean(&1) or is_nil(&1))) do
        quote do: unquote(var) in unquote(Macro.escape(values))
      else
        quote do: Enum.any?(unquote(Macro.escape(values)), &(&1 == unquote(var)))
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :required, params: required}, type, _schema, var, state) do
    checks =
      required
      |> Enum.uniq()
      |> Enum.map(fn key -> quote(do: :maps.is_key(unquote(key), unquote(var))) end)
      |> combine_and()

    ast =
      if type == "object" do
        checks
      else
        quote do: not is_map(unquote(var)) or unquote(checks)
      end

    {ast, state}
  end

  defp compile_rule(%Rule{name: :properties, params: compiled_props}, type, _schema, var, state) do
    {checks, state} = compile_optional_properties(compiled_props, "prop", var, state)
    combined = combine_and(checks)

    ast =
      case split_const_bool(combined) do
        {:ok, [], true} ->
          true

        {:ok, stmts, true} ->
          if type == "object" do
            combined
          else
            quote do
              if is_map(unquote(var)), do: unquote(prepend_stmts(stmts, :ok))
              true
            end
          end

        _ ->
          if type == "object", do: combined, else: quote(do: not is_map(unquote(var)) or unquote(combined))
      end

    {ast, state}
  end

  defp compile_rule(
         %Rule{name: :additionalProperties, params: %{always_valid?: true, patterns: []}},
         _type,
         _schema,
         _var,
         state
       ) do
    {true, state}
  end

  defp compile_rule(
         %Rule{
           name: :additionalProperties,
           params: %{schema: %Schema{rules: [%Rule{name: :boolean_schema}]}, known_props: known, patterns: []}
         },
         type,
         _schema,
         var,
         state
       ) do
    known_list = MapSet.to_list(known)

    check =
      if known_list == [] do
        quote do: map_size(unquote(var)) == 0
      else
        quote do: Enum.all?(Map.keys(unquote(var)), &(&1 in unquote(known_list)))
      end

    ast =
      if type == "object" do
        check
      else
        quote do: not is_map(unquote(var)) or unquote(check)
      end

    {ast, state}
  end

  defp compile_rule(
         %Rule{name: :items, params: %{start_index: 0, schema: sub_schema}},
         type,
         _schema,
         var,
         state
       ) do
    item_var = Macro.var(:item, __MODULE__)
    {item_ast, state} = compile_schema(sub_schema, item_var, state)

    case split_const_bool(item_ast) do
      {:ok, [], true} ->
        {true, state}

      {:ok, [], false} ->
        check = quote(do: unquote(var) == [])
        ast = if type == "array", do: check, else: quote(do: not is_list(unquote(var)) or unquote(check))
        {ast, state}

      {:ok, stmts, false} ->
        check =
          quote do
            case unquote(var) do
              [] -> true
              [unquote(item_var) | _] -> unquote(prepend_stmts(stmts, false))
            end
          end

        ast = if type == "array", do: check, else: quote(do: not is_list(unquote(var)) or unquote(check))
        {ast, state}

      {:ok, stmts, true} ->
        {helper_name, state} = next_helper_name("items", state)
        rest_var = Macro.var(:rest, __MODULE__)

        helper_def =
          quote do
            defp unquote(helper_name)([]), do: :ok

            defp unquote(helper_name)([unquote(item_var) | unquote(rest_var)]) do
              unquote(prepend_stmts(stmts, quote(do: unquote(helper_name)(unquote(rest_var)))))
            end
          end

        state = %{state | helpers: [helper_def | state.helpers]}
        call = quote(do: unquote(helper_name)(unquote(var)))

        ast =
          if type == "array" do
            quote do
              unquote(call)
              true
            end
          else
            quote do
              if is_list(unquote(var)), do: unquote(call)
              true
            end
          end

        {ast, state}

      :dynamic ->
        {helper_name, state} = next_helper_name("items", state)
        rest_var = Macro.var(:rest, __MODULE__)

        helper_def =
          quote do
            defp unquote(helper_name)([]), do: true

            defp unquote(helper_name)([unquote(item_var) | unquote(rest_var)]) do
              unquote(item_ast) and unquote(helper_name)(unquote(rest_var))
            end
          end

        state = %{state | helpers: [helper_def | state.helpers]}
        call = quote(do: unquote(helper_name)(unquote(var)))

        ast =
          if type == "array" do
            call
          else
            quote do: not is_list(unquote(var)) or unquote(call)
          end

        {ast, state}
    end
  end

  defp compile_rule(%Rule{name: :allOf, params: schemas}, _type, _schema, var, state) do
    {asts, state} =
      Enum.reduce(schemas, {[], state}, fn sub, {acc, acc_state} ->
        {sub_ast, acc_state} = compile_schema(sub, var, acc_state)
        {[sub_ast | acc], acc_state}
      end)

    {asts |> Enum.reverse() |> combine_and(), state}
  end

  defp compile_rule(%Rule{name: :anyOf, params: schemas}, _type, _schema, var, state) do
    {asts, state} =
      Enum.reduce(schemas, {[], state}, fn sub, {acc, acc_state} ->
        {sub_ast, acc_state} = compile_schema(sub, var, acc_state)
        {[sub_ast | acc], acc_state}
      end)

    {asts |> Enum.reverse() |> combine_or(), state}
  end

  defp compile_rule(%Rule{name: :oneOf, params: schemas}, _type, _schema, var, state) do
    {reversed_branches, state} =
      Enum.reduce(schemas, {[], state}, fn sub, {acc, acc_state} ->
        {sub_ast, acc_state} = compile_schema(sub, var, acc_state)
        {[sub_ast | acc], acc_state}
      end)

    {count_var, state} = next_var("one_of_count", state)

    # Build from the last branch backwards so execution follows schema order.
    # Embed the continuation only once; a second match skips it altogether.
    ast =
      Enum.reduce(reversed_branches, quote(do: unquote(count_var) == 1), fn branch_ast, rest ->
        case split_const_bool(branch_ast) do
          {:ok, stmts, true} ->
            step =
              quote do
                unquote(count_var) = unquote(count_var) + 1
                unquote(count_var) < 2 and unquote(rest)
              end

            prepend_stmts(stmts, step)

          {:ok, stmts, false} ->
            prepend_stmts(stmts, rest)

          :dynamic ->
            quote do
              unquote(count_var) =
                if unquote(branch_ast), do: unquote(count_var) + 1, else: unquote(count_var)

              unquote(count_var) < 2 and unquote(rest)
            end
        end
      end)

    wrapped =
      quote do
        unquote(count_var) = 0
        unquote(ast)
      end

    {wrapped, state}
  end

  defp compile_rule(%Rule{name: :not, params: sub_schema}, _type, _schema, var, state) do
    {sub_ast, state} = compile_schema(sub_schema, var, state)

    ast =
      case split_const_bool(sub_ast) do
        {:ok, stmts, bool} -> prepend_stmts(stmts, not bool)
        :dynamic -> quote(do: not unquote(sub_ast))
      end

    {ast, state}
  end

  defp compile_rule(
         %Rule{name: :if, params: %{if: compiled_if, then: compiled_then, else: compiled_else}},
         _type,
         _schema,
         var,
         state
       ) do
    prev_abort? = state.may_abort_on_pattern?
    {if_ast, state} = compile_schema(compiled_if, var, %{state | may_abort_on_pattern?: false})
    if_may_abort? = state.may_abort_on_pattern?
    state = %{state | may_abort_on_pattern?: prev_abort? or if_may_abort?}

    {then_ast, state} =
      if compiled_then != nil, do: compile_schema(compiled_then, var, state), else: {true, state}

    {else_ast, state} =
      if compiled_else != nil, do: compile_schema(compiled_else, var, state), else: {true, state}

    ast =
      case {split_const_bool(if_ast), split_const_bool(then_ast), split_const_bool(else_ast)} do
        {{:ok, stmts, true}, _, _} ->
          prepend_stmts(stmts, then_ast)

        {{:ok, stmts, false}, _, _} ->
          prepend_stmts(stmts, else_ast)

        {:dynamic, {:ok, [], bool}, {:ok, [], bool}} ->
          if if_may_abort? do
            prepend_stmts([quote(do: _ = unquote(if_ast))], bool)
          else
            bool
          end

        {:dynamic, {:ok, then_stmts, bool}, {:ok, else_stmts, bool}} ->
          branch_stmt =
            quote do
              if unquote(if_ast) do
                unquote(prepend_stmts(then_stmts, :ok))
              else
                unquote(prepend_stmts(else_stmts, :ok))
              end
            end

          prepend_stmts([branch_stmt], bool)

        _ ->
          quote do
            if unquote(if_ast) do
              unquote(then_ast)
            else
              unquote(else_ast)
            end
          end
      end

    {ast, state}
  end

  # Hybrid fallback for any remaining rule (e.g. patternProperties, additionalProperties with schema/patterns,
  # prefixItems, tuple items, contains, dependentRequired/Schemas, content*, etc.)
  defp compile_rule(%Rule{} = rule, _type, schema, var, state) do
    single_rule_schema = %{schema | rules: [rule]}
    fallback_schema(single_rule_schema, var, state)
  end

  # --- Helpers ---

  defp compile_optional_properties(props, var_prefix, var, state) do
    {checks, state} =
      Enum.reduce(props, {[], state}, fn {key, sub_schema}, {acc, acc_state} ->
        {prop_var, acc_state} = next_var(var_prefix, acc_state)
        {sub_ast, acc_state} = compile_schema(sub_schema, prop_var, acc_state)

        case split_const_bool(sub_ast) do
          {:ok, [], true} ->
            {acc, acc_state}

          {:ok, stmts, true} ->
            check =
              quote do
                case unquote(var) do
                  %{unquote(key) => unquote(prop_var)} -> unquote(prepend_stmts(stmts, :ok))
                  _ -> :ok
                end

                true
              end

            {[check | acc], acc_state}

          _ ->
            check =
              quote do
                case unquote(var) do
                  %{unquote(key) => unquote(prop_var)} -> unquote(sub_ast)
                  _ -> true
                end
              end

            {[check | acc], acc_state}
        end
      end)

    {Enum.reverse(checks), state}
  end

  defp fallback_schema(%Schema{} = schema, var, state) do
    {context_helper, state} = fallback_context(state)

    ast =
      quote do
        ShortCircuit.valid_entry?(unquote(Macro.escape(schema)), unquote(var), unquote(context_helper)())
      end

    # An interpreted rule (including a runtime reference target) can run PCRE.
    {ast, %{state | may_abort_on_pattern?: true}}
  end

  # Embed the scope once, not once per fallback expression. Fully specialized
  # predicates never emit a context helper or construct a context at runtime.
  defp fallback_context(%{context_helper: nil} = state) do
    {name, state} = next_helper_name("scope", state)
    helper = quote do: defp(unquote(name)(), do: unquote(Macro.escape(state.context)))
    {name, %{state | helpers: [helper | state.helpers], context_helper: name}}
  end

  defp fallback_context(%{context_helper: name} = state), do: {name, state}

  defp compile_type_check(types, var) when is_list(types) do
    types |> Enum.map(&Guards.type_check_ast(&1, var)) |> combine_or()
  end

  defp compile_type_check(type, var), do: Guards.type_check_ast(type, var)

  defp combine_and([]), do: true
  defp combine_and([single]), do: single

  defp combine_and([head | tail]) do
    case split_const_bool(head) do
      {:ok, stmts, true} ->
        prepend_stmts(stmts, combine_and(tail))

      {:ok, stmts, false} ->
        prepend_stmts(stmts, false)

      :dynamic ->
        case combine_and(tail) do
          true -> head
          rest -> quote(do: unquote(head) and unquote(rest))
        end
    end
  end

  defp combine_or([]), do: false
  defp combine_or([single]), do: single

  defp combine_or([head | tail]) do
    case split_const_bool(head) do
      {:ok, stmts, false} ->
        prepend_stmts(stmts, combine_or(tail))

      {:ok, stmts, true} ->
        prepend_stmts(stmts, true)

      :dynamic ->
        case combine_or(tail) do
          false -> head
          rest -> quote(do: unquote(head) or unquote(rest))
        end
    end
  end

  defp prepend_stmts([], expr), do: expr

  defp prepend_stmts(stmts, {:__block__, meta, tail_stmts}) do
    {:__block__, meta, stmts ++ tail_stmts}
  end

  defp prepend_stmts(stmts, expr) do
    {:__block__, [], stmts ++ [expr]}
  end

  # Extracts `{prefix_statements, constant_boolean}` from a literal boolean or a
  # block ending in a literal boolean (such as an abort-preserving `if` fold).
  defp split_const_bool(bool) when is_boolean(bool), do: {:ok, [], bool}

  defp split_const_bool({:__block__, _, [_ | _] = stmts}) do
    case List.pop_at(stmts, -1) do
      {bool, prefix} when is_boolean(bool) -> {:ok, prefix, bool}
      _ -> :dynamic
    end
  end

  defp split_const_bool(_), do: :dynamic

  defp next_var(base, %{counter: n} = state) do
    next = n + 1
    {Macro.var(:"#{base}_#{next}", __MODULE__), %{state | counter: next}}
  end

  defp next_helper_name(kind, %{prefix: prefix, counter: n} = state) do
    next = n + 1
    {:"__jsonschex_#{prefix}_#{kind}_#{next}__", %{state | counter: next}}
  end
end

defmodule JSONSchex.StaticCompiler do
  @moduledoc """
  Compiles a static `JSONSchex.Types.Schema` into native Elixir AST for BEAM JIT execution.

  Used by `JSONSchex.Schema.defvalidator/3` to emit specialized function clauses,
  map pattern matches, guard checks, and tail-recursive list validators at compile time.

  Keywords outside the static subset (such as `$ref`, `$dynamicRef`, `unevaluatedProperties`,
  `unevaluatedItems`, or `contentSchema`) automatically fall back to `JSONSchex.valid?/2`
  on the embedded compiled sub-schema, preserving 100% JSON Schema specification compliance.
  """

  alias JSONSchex.Types.{Rule, Schema}

  @doc false
  @spec compile(atom(), Schema.t()) :: {Macro.t(), [Macro.t()], boolean()}
  def compile(prefix, %Schema{} = schema) when is_atom(prefix) do
    var = Macro.var(:data, __MODULE__)
    state = %{prefix: prefix, counter: 0, helpers: [], needs_catch?: false}
    {expr, final_state} = compile_schema(schema, var, state)
    {expr, Enum.reverse(final_state.helpers), final_state.needs_catch?}
  end

  # --- Schema Node Compilation ---

  defp compile_schema(%Schema{needs_evaluated_annotations: true} = schema, var, state) do
    fallback_schema(schema, var, state)
  end

  defp compile_schema(%Schema{source_id: id} = schema, var, state) when id != nil do
    # Only fall back if the schema actually uses refs that depend on source_id scope
    if has_ref_rule?(schema.rules) do
      fallback_schema(schema, var, state)
    else
      compile_rules_node(schema, var, state)
    end
  end

  defp compile_schema(%Schema{} = schema, var, state) do
    compile_rules_node(schema, var, state)
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
            {[{key, prop_var} | pairs], [sub_ast | checks], acc_state}

          :error ->
            {[{key, quote(do: _)} | pairs], checks, acc_state}
        end
      end)

    # Optional properties (in `properties` but not in `required`)
    optional_props = Enum.reject(props_list, fn {k, _} -> MapSet.member?(required_set, k) end)

    {opt_checks, state} =
      Enum.reduce(optional_props, {[], state}, fn {key, sub_schema}, {checks, acc_state} ->
        {prop_var, acc_state} = next_var("opt", acc_state)
        {sub_ast, acc_state} = compile_schema(sub_schema, prop_var, acc_state)

        check_ast =
          quote do
            case unquote(var) do
              %{unquote(key) => unquote(prop_var)} -> unquote(sub_ast)
              _ -> true
            end
          end

        {[check_ast | checks], acc_state}
      end)

    # Remaining rules on the object (e.g. additionalProperties, minProperties, maxProperties)
    {rem_ast, state} =
      case remaining_rules do
        [] -> {true, state}
        _ -> compile_rule_list(remaining_rules, "object", schema, var, state)
      end

    all_checks =
      (Enum.reverse(req_checks) ++ Enum.reverse(opt_checks) ++ [rem_ast])
      |> combine_and()

    map_pattern = {:%{}, [], Enum.reverse(map_pairs)}

    ast =
      quote do
        case unquote(var) do
          unquote(map_pattern) -> unquote(all_checks)
          _ -> false
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
    # `minLength` in the same node already verified `String.valid?(var)`, so we
    # can skip the redundant UTF-8 scan when `byte_size(var) <= max`.
    ast =
      quote do
        byte_size(unquote(var)) <= unquote(max) or
          JSONSchex.Compiler.Predicates.check_max_length(unquote(var), unquote(max)) == :ok
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
          JSONSchex.Compiler.Predicates.check_min_length(unquote(var), unquote(min)) == :ok
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
          JSONSchex.Compiler.Predicates.check_max_length(unquote(var), unquote(max)) == :ok
      end

    ast =
      if type == "string", do: check, else: quote(do: not is_binary(unquote(var)) or unquote(check))

    {ast, state}
  end

  defp compile_rule(%Rule{name: :pattern, params: %{matcher: matcher}}, type, _schema, var, state) do
    check =
      quote do
        JSONSchex.Validator.Pattern.match_fast?(unquote(Macro.escape(matcher)), unquote(var))
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

    {ast, %{state | needs_catch?: true}}
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
    check = quote(do: JSONSchex.Compiler.Predicates.check_unique_items(unquote(var), true) == :ok)

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
    {checks, state} =
      Enum.reduce(compiled_props, {[], state}, fn {key, sub_schema}, {acc, acc_state} ->
        {prop_var, acc_state} = next_var("prop", acc_state)
        {sub_ast, acc_state} = compile_schema(sub_schema, prop_var, acc_state)

        check =
          quote do
            case unquote(var) do
              %{unquote(key) => unquote(prop_var)} -> unquote(sub_ast)
              _ -> true
            end
          end

        {[check | acc], acc_state}
      end)

    combined = checks |> Enum.reverse() |> combine_and()

    ast =
      if type == "object" do
        combined
      else
        quote do: not is_map(unquote(var)) or unquote(combined)
      end

    {ast, state}
  end

  defp compile_rule(
         %Rule{name: :additionalProperties, params: %{always_valid?: true}},
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
      quote do
        Enum.all?(Map.keys(unquote(var)), &(&1 in unquote(known_list)))
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
    {helper_name, state} = next_helper_name("items", state)
    item_var = Macro.var(:item, __MODULE__)
    rest_var = Macro.var(:rest, __MODULE__)
    {item_ast, state} = compile_schema(sub_schema, item_var, state)

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
    {branch_asts, state} =
      Enum.reduce(schemas, {[], state}, fn sub, {acc, acc_state} ->
        {sub_ast, acc_state} = compile_schema(sub, var, acc_state)
        {[sub_ast | acc], acc_state}
      end)

    {count_var, state} = next_var("one_of_count", state)

    # Fold branches with early exit as soon as 2 branches match
    ast =
      branch_asts
      |> Enum.reverse()
      |> Enum.reduce(quote(do: unquote(count_var) == 1), fn branch_ast, next_ast ->
        quote do
          if unquote(branch_ast) do
            if unquote(count_var) == 1 do
              false
            else
              unquote(count_var) = 1
              unquote(next_ast)
            end
          else
            unquote(next_ast)
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
    {quote(do: not unquote(sub_ast)), state}
  end

  defp compile_rule(
         %Rule{name: :if, params: %{if: compiled_if, then: compiled_then, else: compiled_else}},
         _type,
         _schema,
         var,
         state
       ) do
    {if_ast, state} = compile_schema(compiled_if, var, state)

    {then_ast, state} =
      if compiled_then != nil, do: compile_schema(compiled_then, var, state), else: {true, state}

    {else_ast, state} =
      if compiled_else != nil, do: compile_schema(compiled_else, var, state), else: {true, state}

    ast =
      quote do
        if unquote(if_ast) do
          unquote(then_ast)
        else
          unquote(else_ast)
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

  defp fallback_schema(%Schema{} = schema, var, state) do
    ast =
      quote do
        JSONSchex.valid?(unquote(Macro.escape(schema)), unquote(var))
      end

    {ast, %{state | needs_catch?: true}}
  end

  defp compile_type_check("string", var), do: quote(do: is_binary(unquote(var)))

  defp compile_type_check("integer", var) do
    quote do: is_integer(unquote(var)) or (is_float(unquote(var)) and unquote(var) == trunc(unquote(var)))
  end

  defp compile_type_check("number", var), do: quote(do: is_number(unquote(var)))
  defp compile_type_check("boolean", var), do: quote(do: is_boolean(unquote(var)))
  defp compile_type_check("object", var), do: quote(do: is_map(unquote(var)))
  defp compile_type_check("array", var), do: quote(do: is_list(unquote(var)))
  defp compile_type_check("null", var), do: quote(do: is_nil(unquote(var)))

  defp compile_type_check(types, var) when is_list(types) do
    types |> Enum.map(&compile_type_check(&1, var)) |> combine_or()
  end

  defp combine_and([]), do: true
  defp combine_and([single]), do: single

  defp combine_and(exprs) do
    filtered = Enum.reject(exprs, &(&1 === true))

    case filtered do
      [] -> true
      [single] -> single
      list -> Enum.reduce(Enum.reverse(list), fn expr, acc -> quote(do: unquote(expr) and unquote(acc)) end)
    end
  end

  defp combine_or([]), do: false
  defp combine_or([single]), do: single

  defp combine_or(exprs) do
    Enum.reduce(Enum.reverse(exprs), fn expr, acc -> quote(do: unquote(expr) or unquote(acc)) end)
  end

  defp next_var(base, %{counter: n} = state) do
    next = n + 1
    {Macro.var(:"#{base}_#{next}", __MODULE__), %{state | counter: next}}
  end

  defp next_helper_name(kind, %{prefix: prefix, counter: n} = state) do
    next = n + 1
    {:"__jsonschex_#{prefix}_#{kind}_#{next}__", %{state | counter: next}}
  end
end

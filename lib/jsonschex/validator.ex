defmodule JSONSchex.Validator do
  @moduledoc """
  Executes compiled `Schema` rules against data, accumulating errors and tracking
  evaluated keys for `unevaluatedProperties`/`unevaluatedItems`.

  During validation, a context tuple is threaded through each rule:

      {path, evaluated_keys, validation_context}

  - `path` — Reversed list of JSON Pointer segments (e.g., `["email", 0, "users"]`)
  - `evaluated_keys` — `MapSet` of property names or array indices validated so far
  - `validation_context` — `ValidationContext` struct referencing the root schema

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})
      iex> JSONSchex.Validator.validate(schema, %{"name" => "Alice"})
      :ok
  """

  alias JSONSchex.Types.{Error, Rule, Schema, ValidationContext}
  alias JSONSchex.Validator.Rules

  @empty_mapset MapSet.new()

  @typep validation_error_list ::
           [Error.t() | {list(), atom(), map()} | validation_error_list()]

  @doc """
  Validates data against a compiled schema.

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "integer", "minimum" => 0})
      iex> JSONSchex.Validator.validate(schema, 10)
      :ok

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "integer", "minimum" => 0})
      iex> {:error, errors} = JSONSchex.Validator.validate(schema, -5)
      iex> Enum.any?(errors, fn e -> e.rule == :minimum end)
      true
  """
  @spec validate(Schema.t(), term()) :: :ok | {:error, list(Error.t())}
  def validate(%Schema{source_id: id} = root_schema, data) do
    initial_stack = if id != nil, do: [id], else: []

    ctx = %ValidationContext{
      root_schema: root_schema,
      scope_stack: initial_stack,
      source_id: id,
      raw: root_schema.raw
    }

    case validate_entry(root_schema, data, [], ctx) do
      {:ok, _annotations} ->
        :ok

      {:error, errors} ->
        {:error, flatten_and_format_errors(errors, data)}
    end
  end

  defp flatten_and_format_errors(errors, data) do
    if flat_error_list?(errors) do
      errors
    else
      flatten_and_format_errors(errors, data, [])
    end
  end

  # Keyword reducers commonly return an already-flat list of Error structs. A
  # linear shape check avoids rebuilding that list at the public boundary.
  defp flat_error_list?([]), do: true
  defp flat_error_list?([%Error{} | rest]), do: flat_error_list?(rest)
  defp flat_error_list?(_errors), do: false

  defp flatten_and_format_errors([], _data, formatted_tail), do: formatted_tail

  # Process the remaining siblings first so prepending the current leaf retains
  # the depth-first, left-to-right order produced by List.flatten/1.
  defp flatten_and_format_errors([error | rest], data, formatted_tail) do
    formatted_tail = flatten_and_format_errors(rest, data, formatted_tail)
    flatten_and_format_error(error, data, formatted_tail)
  end

  defp flatten_and_format_error(errors, data, formatted_tail) when is_list(errors),
    do: flatten_and_format_errors(errors, data, formatted_tail)

  defp flatten_and_format_error({path, rule, context}, data, formatted_tail)
       when is_map(context) do
    [%Error{path: path, rule: rule, context: context, value: data} | formatted_tail]
  end

  defp flatten_and_format_error(%Error{} = error, _data, formatted_tail),
    do: [error | formatted_tail]

  @doc """
  Recursive validation engine called by the rule dispatcher.

  Executes all rules in the schema sequentially, accumulating errors and evaluated keys.

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "string"})
      iex> ctx = %JSONSchex.Types.ValidationContext{root_schema: schema, scope_stack: [], source_id: nil, raw: nil}
      iex> JSONSchex.Validator.validate_entry(schema, "hello", [], ctx)
      {:ok, MapSet.new()}
  """
  @spec validate_entry(Schema.t(), term(), list(), ValidationContext.t(), term()) ::
          {:ok, MapSet.t()} | {:error, validation_error_list()}
  def validate_entry(schema, data, path, context, initial_evaluted \\ @empty_mapset)

  def validate_entry(%Schema{rules: [], source_id: nil}, _data, _path, _context, evaluated) do
    {:ok, evaluated}
  end

  def validate_entry(%Schema{rules: [rule], source_id: nil}, data, path, context, evaluated) do
    case Rules.apply(rule, data, {path, evaluated, context}) do
      :ok ->
        {:ok, evaluated}

      {:ok, new_eval_keys} ->
        {:ok, MapSet.union(evaluated, new_eval_keys)}

      {:error, new_errs} when is_list(new_errs) ->
        {:error, new_errs}

      {:error, error_context} when is_map(error_context) ->
        {:error, [%Error{path: path, rule: rule.name, context: error_context, value: data}]}
    end
  end

  def validate_entry(
        %Schema{rules: [rule1, rule2] = rules, source_id: nil},
        data,
        path,
        context,
        evaluated
      ) do
    ctx = {path, evaluated, context}

    case two_rule_pattern_match_cache(rule1, rule2, data) do
      nil ->
        run_two_rules(rule1, rule2, data, path, context, evaluated, ctx)
      cache ->
        run_rules_with_pattern_cache(rules, data, path, context, evaluated, ctx, [], cache)
    end
  end

  def validate_entry(
        %Schema{rules: rules, source_id: nil},
        data,
        path,
        context,
        initial_evaluated
      ) do
    ctx = {path, initial_evaluated, context}
    run_rules(rules, data, path, context, initial_evaluated, ctx, [])
  end

  def validate_entry(
        %Schema{rules: rules} = current_schema,
        data,
        path,
        %ValidationContext{} = root_context,
        initial_evaluated
      ) do
    current_context = update_context_if_needed(current_schema, root_context)
    initial_ctx = {path, initial_evaluated, current_context}
    run_rules(rules, data, path, current_context, initial_evaluated, initial_ctx, [])
  end

  defp to_error_entry(errs, _path, _rule_name, _data) when is_list(errs), do: errs

  defp to_error_entry(err_ctx, path, rule_name, data) when is_map(err_ctx),
    do: [%Error{path: path, rule: rule_name, context: err_ctx, value: data}]

  # Keep the specialized two-rule execution path for ordinary schemas. Only a
  # direct pair of sibling object keywords enters the cache-aware runner.
  defp run_two_rules(rule1, rule2, data, path, context, evaluated, ctx) do
    {eval1, ctx1, err1} =
      case Rules.apply(rule1, data, ctx) do
        :ok ->
          {evaluated, ctx, nil}

        {:ok, new_keys} ->
          new_eval = MapSet.union(evaluated, new_keys)
          {new_eval, {path, new_eval, context}, nil}

        {:error, error} ->
          {evaluated, ctx, to_error_entry(error, path, rule1.name, data)}
      end

    {eval2, err2} =
      case Rules.apply(rule2, data, ctx1) do
        :ok ->
          {eval1, nil}

        {:ok, new_keys} ->
          {MapSet.union(eval1, new_keys), nil}

        {:error, error} ->
          {eval1, to_error_entry(error, path, rule2.name, data)}
      end

    case {err1, err2} do
      {nil, nil} -> {:ok, eval2}
      {error, nil} -> {:error, error}
      {nil, error} -> {:error, error}
      {error1, error2} -> {:error, [error2 | [error1]]}
    end
  end


  defp run_rules_with_pattern_cache([], _data, _path, _context, evaluated, _ctx, [], _cache) do
    {:ok, evaluated}
  end

  defp run_rules_with_pattern_cache([], _data, _path, _context, _evaluated, _ctx, errors, _cache) do
    {:error, errors}
  end

  defp run_rules_with_pattern_cache([rule | rest], data, path, context, evaluated, ctx, errors, cache) do
    {result, updated_cache} = Rules.apply(rule, data, ctx, cache)
    complete? = pattern_match_cache_complete?(rule, updated_cache)

    case result do
      :ok ->
        continue_cached_rules(
          complete?,
          rest,
          data,
          path,
          context,
          evaluated,
          ctx,
          errors,
          updated_cache
        )

      {:ok, new_eval_keys} ->
        cond do
          MapSet.size(new_eval_keys) == 0 ->
            continue_cached_rules(
              complete?,
              rest,
              data,
              path,
              context,
              evaluated,
              ctx,
              errors,
              updated_cache
            )

          MapSet.size(evaluated) == 0 ->
            new_ctx = {path, new_eval_keys, context}

            continue_cached_rules(
              complete?,
              rest,
              data,
              path,
              context,
              new_eval_keys,
              new_ctx,
              errors,
              updated_cache
            )

          true ->
            new_evaluated = MapSet.union(evaluated, new_eval_keys)
            new_ctx = {path, new_evaluated, context}

            continue_cached_rules(
              complete?,
              rest,
              data,
              path,
              context,
              new_evaluated,
              new_ctx,
              errors,
              updated_cache
            )
        end

      {:error, new_errs} when is_list(new_errs) ->
        continue_cached_rules(
          complete?,
          rest,
          data,
          path,
          context,
          evaluated,
          ctx,
          [new_errs | errors],
          updated_cache
        )

      {:error, err_context} when is_map(err_context) ->
        error = %Error{path: path, rule: rule.name, context: err_context, value: data}

        continue_cached_rules(
          complete?,
          rest,
          data,
          path,
          context,
          evaluated,
          ctx,
          [error | errors],
          updated_cache
        )
    end
  end

  defp continue_cached_rules(true, rest, data, path, context, evaluated, ctx, errors, _cache) do
    run_rules(rest, data, path, context, evaluated, ctx, errors)
  end

  defp continue_cached_rules(false, rest, data, path, context, evaluated, ctx, errors, cache) do
    run_rules_with_pattern_cache(rest, data, path, context, evaluated, ctx, errors, cache)
  end

  defp pattern_match_cache_complete?(
         %Rule{name: :additionalProperties},
         %{source: :pattern_properties}
       ),
       do: true

  defp pattern_match_cache_complete?(
         %Rule{name: :patternProperties},
         %{source: :additional_properties}
       ),
       do: true

  defp pattern_match_cache_complete?(_rule, _cache), do: false

  defp two_rule_pattern_match_cache(
         %Rule{name: first_name} = first_rule,
         %Rule{name: second_name} = second_rule,
         data
       )
       when first_name in [:patternProperties, :additionalProperties] and
              second_name in [:patternProperties, :additionalProperties] and
              first_name != second_name do
    pattern_match_cache([first_rule, second_rule], data)
  end

  defp two_rule_pattern_match_cache(_first_rule, _second_rule, _data), do: nil

  # A cache map cannot repay its setup work when the two sibling rules would
  # repeat exactly one match check. All larger candidate workloads stay eligible.
  defp pattern_match_cache(
         [%Rule{name: :patternProperties, params: [_single_pattern]} | _rest],
         data
       )
       when is_map(data) and map_size(data) == 1,
       do: nil

  defp pattern_match_cache(
         [%Rule{name: :additionalProperties, params: %{patterns: [_single_pattern]}} | _rest],
         data
       )
       when is_map(data) and map_size(data) == 1,
       do: nil

  # This cache records structural pattern matches only. It stays local to this
  # validate_entry/5 call, so child schemas and later validations cannot reuse
  # annotations, errors, reference state, or match facts from this object.
  defp pattern_match_cache(rules, data) when is_map(data) and map_size(data) > 0 do
    case sibling_pattern_rules(rules) do
      {%Rule{params: compiled_patterns},
       %Rule{
         params: %{
           patterns: patterns,
           known_props: %MapSet{} = known_props,
           schema: _schema,
           always_valid?: always_valid?
         }
       }}
      when is_list(compiled_patterns) and is_list(patterns) and is_boolean(always_valid?) ->
        if compiled_patterns != [] and
             same_pattern_sequence?(compiled_patterns, patterns) and
             has_additional_candidate?(data, known_props) do
          %{source: nil, matches: %{}}
        end

      _ ->
        nil
    end
  end

  defp pattern_match_cache(_rules, _data), do: nil

  defp sibling_pattern_rules(rules) do
    Enum.reduce_while(rules, {nil, nil}, fn
      %Rule{name: :patternProperties} = rule, {nil, additional_rule} ->
        {:cont, {rule, additional_rule}}

      %Rule{name: :patternProperties}, _ ->
        # Duplicated
        {:halt, nil}

      %Rule{name: :additionalProperties} = rule, {pattern_rule, nil} ->
        {:cont, {pattern_rule, rule}}

      %Rule{name: :additionalProperties}, _ ->
        # Duplicated
        {:halt, nil}

      _rule, acc ->
        {:cont, acc}
    end)
    |> case do
      {%Rule{} = pattern_rule, %Rule{} = additional_rule} ->
        {pattern_rule, additional_rule}
      _ ->
        nil
    end
  end

  defp same_pattern_sequence?([], []), do: true

  defp same_pattern_sequence?([{regex, _schema} | compiled_rest], [pattern | patterns])
       when regex === pattern do
    same_pattern_sequence?(compiled_rest, patterns)
  end

  defp same_pattern_sequence?(_, _), do: false

  defp has_additional_candidate?(data, known_props) do
    if map_size(data) > MapSet.size(known_props) do
      true
    else
      Enum.any?(data, fn {key, _value} -> not MapSet.member?(known_props, key) end)
    end
  end

  defp run_rules([], _data, _path, _context, evaluated, _ctx, []) do
    {:ok, evaluated}
  end

  defp run_rules([], _data, _path, _context, _evaluated, _ctx, errors) do
    {:error, errors}
  end

  defp run_rules(
         [%Rule{name: name} = rule | rest],
         data,
         path,
         context,
         evaluated,
         ctx,
         errors
       )
       when name in [:patternProperties, :additionalProperties] do
    case pattern_match_cache([rule | rest], data) do
      nil ->
        run_rules_without_pattern_match_cache(
          [rule | rest],
          data,
          path,
          context,
          evaluated,
          ctx,
          errors
        )

      cache ->
        run_rules_with_pattern_cache([rule | rest], data, path, context, evaluated, ctx, errors, cache)
    end
  end

  defp run_rules([rule | rest], data, path, context, evaluated, ctx, errors) do
    case Rules.apply(rule, data, ctx) do
      :ok ->
        run_rules(rest, data, path, context, evaluated, ctx, errors)

      {:ok, new_eval_keys} ->
        cond do
          MapSet.size(new_eval_keys) == 0 ->
            run_rules(rest, data, path, context, evaluated, ctx, errors)

          MapSet.size(evaluated) == 0 ->
            new_ctx = {path, new_eval_keys, context}
            run_rules(rest, data, path, context, new_eval_keys, new_ctx, errors)

          true ->
            new_evaluated = MapSet.union(evaluated, new_eval_keys)
            new_ctx = {path, new_evaluated, context}
            run_rules(rest, data, path, context, new_evaluated, new_ctx, errors)
        end

      {:error, new_errs} when is_list(new_errs) ->
        run_rules(rest, data, path, context, evaluated, ctx, [new_errs | errors])

      {:error, err_context} when is_map(err_context) ->
        e = %Error{path: path, rule: rule.name, context: err_context, value: data}
        run_rules(rest, data, path, context, evaluated, ctx, [e | errors])
    end
  end

  defp run_rules_without_pattern_match_cache([], _data, _path, _context, evaluated, _ctx, []) do
    {:ok, evaluated}
  end

  defp run_rules_without_pattern_match_cache(
         [],
         _data,
         _path,
         _context,
         _evaluated,
         _ctx,
         errors
       ) do
    {:error, errors}
  end

  defp run_rules_without_pattern_match_cache([rule | rest], data, path, context, evaluated, ctx, errors) do
    case Rules.apply(rule, data, ctx) do
      :ok ->
        run_rules_without_pattern_match_cache(rest, data, path, context, evaluated, ctx, errors)

      {:ok, new_eval_keys} ->
        cond do
          MapSet.size(new_eval_keys) == 0 ->
            run_rules_without_pattern_match_cache(rest, data, path, context, evaluated, ctx, errors)

          MapSet.size(evaluated) == 0 ->
            new_ctx = {path, new_eval_keys, context}

            run_rules_without_pattern_match_cache(
              rest,
              data,
              path,
              context,
              new_eval_keys,
              new_ctx,
              errors
            )

          true ->
            new_evaluated = MapSet.union(evaluated, new_eval_keys)
            new_ctx = {path, new_evaluated, context}

            run_rules_without_pattern_match_cache(
              rest,
              data,
              path,
              context,
              new_evaluated,
              new_ctx,
              errors
            )
        end

      {:error, new_errs} when is_list(new_errs) ->
        run_rules_without_pattern_match_cache(
          rest,
          data,
          path,
          context,
          evaluated,
          ctx,
          [new_errs | errors]
        )

      {:error, err_context} when is_map(err_context) ->
        error = %Error{path: path, rule: rule.name, context: err_context, value: data}

        run_rules_without_pattern_match_cache(
          rest,
          data,
          path,
          context,
          evaluated,
          ctx,
          [error | errors]
        )
    end
  end

  defp update_context_if_needed(%{source_id: nil}, %ValidationContext{} = root_context) do
    root_context
  end

  defp update_context_if_needed(
         %{source_id: id},
         %ValidationContext{source_id: id} = root_context
       ) do
    root_context
  end

  defp update_context_if_needed(
         %{source_id: source_id} = current_schema,
         %ValidationContext{} = root_context
       ) do
    %{
      root_context
      | source_id: source_id,
        raw: current_schema.raw,
        scope_stack: [source_id | root_context.scope_stack]
    }
  end
end

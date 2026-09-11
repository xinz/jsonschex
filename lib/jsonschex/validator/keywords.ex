defmodule JSONSchex.Validator.Keywords do
  @moduledoc """
  Runtime validation functions for complex JSON Schema keywords.

  Called by the rule dispatcher generated from compiled schemas. Each function returns
  `:ok`, `{:ok, evaluated_keys}`, or `{:error, errors}`.
  """

  alias JSONSchex.Validator
  alias JSONSchex.Types.{Error, ErrorContext}

  @empty_mapset MapSet.new()

  @doc """
  Validates an object's properties against a map of compiled schemas.
  Returns evaluated property keys on success.
  """
  def validate_properties_map(data, compiled_props, path, root) when is_map(data) do
    reduce_props(compiled_props, data, path, root, [], [])
  end

  def validate_properties_map(_, _, _, _), do: :ok

  defp reduce_props([], _data, _path, _root, [], []), do: :ok
  defp reduce_props([], _data, _path, _root, [], eval_keys), do: {:ok, MapSet.new(eval_keys)}
  defp reduce_props([], _data, _path, _root, errs, _eval_keys), do: {:error, List.flatten(errs)}

  defp reduce_props([{key, sub_schema} | rest], data, path, root, errs, eval_keys) do
    case Map.fetch(data, key) do
      {:ok, val} ->
        case Validator.validate_entry(sub_schema, val, [key | path], root) do
          {:ok, _sub_evaluated} ->
            reduce_props(rest, data, path, root, errs, [key | eval_keys])

          {:error, new_errs} ->
            reduce_props(rest, data, path, root, [new_errs | errs], eval_keys)
        end

      :error ->
        reduce_props(rest, data, path, root, errs, eval_keys)
    end
  end

  @doc """
  Validates unevaluated properties against a schema.
  """
  def validate_unevaluated_props(data, sub_schema, path, evaluated_keys, root)
      when is_map(data) do
    reduce_unevaluated_props(Map.to_list(data), sub_schema, path, evaluated_keys, root, [], [])
  end

  def validate_unevaluated_props(_, _, _, _, _), do: :ok

  defp reduce_unevaluated_props([], _sub_schema, _path, _evaluated_keys, _root, [], []),
    do: {:ok, @empty_mapset}

  defp reduce_unevaluated_props([], _sub_schema, _path, _evaluated_keys, _root, [], uneval),
    do: {:ok, MapSet.new(uneval)}

  defp reduce_unevaluated_props([], _sub_schema, _path, _evaluated_keys, _root, errs, _uneval),
    do: {:error, List.flatten(errs)}

  defp reduce_unevaluated_props(
         [{key, val} | rest],
         sub_schema,
         path,
         evaluated_keys,
         root,
         errs,
         uneval
       ) do
    if MapSet.member?(evaluated_keys, key) do
      reduce_unevaluated_props(rest, sub_schema, path, evaluated_keys, root, errs, uneval)
    else
      case Validator.validate_entry(sub_schema, val, [key | path], root) do
        {:ok, _} ->
          reduce_unevaluated_props(rest, sub_schema, path, evaluated_keys, root, errs, [
            key | uneval
          ])

        {:error, new_errs} ->
          reduce_unevaluated_props(
            rest,
            sub_schema,
            path,
            evaluated_keys,
            root,
            [new_errs | errs],
            [key | uneval]
          )
      end
    end
  end

  @doc """
  Validates array items against prefix schemas (`prefixItems`).
  """
  def validate_prefix_items(data, schemas, path, root) when is_list(data) do
    case reduce_prefix_items(schemas, data, path, root, 0, {[], []}) do
      {[], []} -> :ok
      {[], evaluated} -> {:ok, MapSet.new(evaluated)}
      {errs, _} -> {:error, List.flatten(errs)}
    end
  end

  def validate_prefix_items(_, _, _, _), do: :ok

  defp reduce_prefix_items([], _data, _path, _root, _index, acc), do: acc
  defp reduce_prefix_items(_schemas, [], _path, _root, _index, acc), do: acc

  defp reduce_prefix_items(
         [schema | rest_schemas],
         [item | rest_data],
         path,
         root,
         index,
         {errs, evaluated}
       ) do
    case Validator.validate_entry(schema, item, [index | path], root) do
      {:ok, _} ->
        reduce_prefix_items(
          rest_schemas,
          rest_data,
          path,
          root,
          index + 1,
          {errs, [index | evaluated]}
        )

      {:error, new_errs} ->
        reduce_prefix_items(
          rest_schemas,
          rest_data,
          path,
          root,
          index + 1,
          {[new_errs | errs], evaluated}
        )
    end
  end

  @doc """
  Validates array items starting from a given index (`items`).
  """
  def validate_items_array(data, schema, start_index, path, root) when is_list(data) do
    case reduce_items_array(data, schema, start_index, path, root, 0, {[], []}) do
      {[], []} -> :ok
      {[], evaluated} -> {:ok, MapSet.new(evaluated)}
      {errs, _} -> {:error, List.flatten(errs)}
    end
  end

  def validate_items_array(_, _, _, _, _), do: :ok

  defp reduce_items_array([], _schema, _start_index, _path, _root, _index, acc), do: acc

  defp reduce_items_array([_ | rest], schema, start_index, path, root, index, acc)
       when index < start_index do
    reduce_items_array(rest, schema, start_index, path, root, index + 1, acc)
  end

  defp reduce_items_array([val | rest], schema, start_index, path, root, index, {errs, evaluated}) do
    case Validator.validate_entry(schema, val, [index | path], root) do
      {:ok, _} ->
        reduce_items_array(
          rest,
          schema,
          start_index,
          path,
          root,
          index + 1,
          {errs, [index | evaluated]}
        )

      {:error, new_errs} ->
        reduce_items_array(
          rest,
          schema,
          start_index,
          path,
          root,
          index + 1,
          {[new_errs | errs], evaluated}
        )
    end
  end

  @doc """
  Validates unevaluated array items against a schema.
  """
  def validate_unevaluated_items(data, schema, path, evaluated_indices, root)
      when is_list(data) do
    case reduce_unevaluated_items(data, schema, path, evaluated_indices, root, 0, {[], []}) do
      {[], []} -> :ok
      {[], unevaluated} -> {:ok, MapSet.new(unevaluated)}
      {errors, _} -> {:error, List.flatten(errors)}
    end
  end

  def validate_unevaluated_items(_, _, _, _, _), do: :ok

  defp reduce_unevaluated_items([], _schema, _path, _evaluated, _root, _index, acc), do: acc

  defp reduce_unevaluated_items(
         [val | rest],
         schema,
         path,
         evaluated_indices,
         root,
         index,
         {acc_errs, acc_uneval}
       ) do
    if MapSet.member?(evaluated_indices, index) do
      reduce_unevaluated_items(
        rest,
        schema,
        path,
        evaluated_indices,
        root,
        index + 1,
        {acc_errs, acc_uneval}
      )
    else
      case Validator.validate_entry(schema, val, [index | path], root) do
        {:ok, _} ->
          reduce_unevaluated_items(
            rest,
            schema,
            path,
            evaluated_indices,
            root,
            index + 1,
            {acc_errs, [index | acc_uneval]}
          )

        {:error, new_errs} ->
          reduce_unevaluated_items(
            rest,
            schema,
            path,
            evaluated_indices,
            root,
            index + 1,
            {[new_errs | acc_errs], [index | acc_uneval]}
          )
      end
    end
  end

  @doc """
  Validates data against all schemas in an `allOf` array.
  """
  def validate_allOf(data, schemas, path, root, _evaluated) do
    reduce_allOf(schemas, data, path, root, [], [])
  end

  defp reduce_allOf([], _data, _path, _root, acc_keys, []) do
    {:ok, MapSet.new(List.flatten(acc_keys))}
  end

  defp reduce_allOf([], _data, _path, _root, _acc_keys, error_lists) do
    {:error, List.flatten(Enum.reverse(error_lists))}
  end

  defp reduce_allOf([schema | rest], data, path, root, acc_keys, error_lists) do
    case Validator.validate_entry(schema, data, path, root, @empty_mapset) do
      {:ok, new_keys} ->
        if MapSet.size(new_keys) == 0 do
          reduce_allOf(rest, data, path, root, acc_keys, error_lists)
        else
          reduce_allOf(rest, data, path, root, [MapSet.to_list(new_keys) | acc_keys], error_lists)
        end

      {:error, errs} ->
        reduce_allOf(rest, data, path, root, acc_keys, [errs | error_lists])
    end
  end

  @doc """
  Validates data against schemas in an `anyOf` array.
  """
  def validate_anyOf(data, schemas, path, root, evaluated) do
    if any_of_direct_merge_candidate?(schemas, evaluated) do
      reduce_anyOf_with_shared_evaluated_keys(schemas, data, path, root, evaluated, 0, 0, [], [])
    else
      reduce_anyOf(schemas, data, path, root, evaluated, 0, [], [])
    end
  end

  defp reduce_anyOf([], _data, _path, _root, _evaluated, count, merged_keys, _error_lists)
       when count > 0 do
    {:ok, MapSet.new(List.flatten(merged_keys))}
  end

  defp reduce_anyOf([], _data, _path, _root, _evaluated, 0, _merged_keys, error_lists) do
    {:error, List.flatten(Enum.reverse(error_lists))}
  end

  defp reduce_anyOf([schema | rest], data, path, root, evaluated, count, acc_keys, acc_errs) do
    case Validator.validate_entry(schema, data, path, root, evaluated) do
      {:ok, keys} ->
        if MapSet.size(keys) == 0 do
          reduce_anyOf(rest, data, path, root, evaluated, count + 1, acc_keys, acc_errs)
        else
          reduce_anyOf(
            rest,
            data,
            path,
            root,
            evaluated,
            count + 1,
            [MapSet.to_list(keys) | acc_keys],
            acc_errs
          )
        end

      {:error, errs} ->
        new_errs = if count == 0, do: [errs | acc_errs], else: acc_errs
        reduce_anyOf(rest, data, path, root, evaluated, count, acc_keys, new_errs)
    end
  end

  # The specialized reducer is reachable only for a sufficiently large incoming
  # evaluated-key set and at least four branches. It preserves the input supplied
  # to every child and selects direct merging only after all branches run.
  defp any_of_direct_merge_candidate?([_, _, _, _ | _], evaluated),
    do: MapSet.size(evaluated) >= 8

  defp any_of_direct_merge_candidate?(_schemas, _evaluated), do: false

  defp reduce_anyOf_with_shared_evaluated_keys(
         [],
         _data,
         _path,
         _root,
         evaluated,
         count,
         total_evaluated_key_count,
         evaluated_key_sets,
         _error_lists
       )
       when count > 0 do
    {:ok,
     merge_any_of_evaluated_key_sets(
       evaluated_key_sets,
       evaluated,
       count,
       total_evaluated_key_count
     )}
  end

  defp reduce_anyOf_with_shared_evaluated_keys(
         [],
         _data,
         _path,
         _root,
         _evaluated,
         0,
         _total_evaluated_key_count,
         _evaluated_key_sets,
         error_lists
       ) do
    {:error, List.flatten(Enum.reverse(error_lists))}
  end

  defp reduce_anyOf_with_shared_evaluated_keys(
         [schema | rest],
         data,
         path,
         root,
         evaluated,
         count,
         total_evaluated_key_count,
         evaluated_key_sets,
         acc_errs
       ) do
    case Validator.validate_entry(schema, data, path, root, evaluated) do
      {:ok, keys} ->
        key_count = MapSet.size(keys)

        if key_count == 0 do
          reduce_anyOf_with_shared_evaluated_keys(
            rest,
            data,
            path,
            root,
            evaluated,
            count + 1,
            total_evaluated_key_count,
            evaluated_key_sets,
            acc_errs
          )
        else
          new_count = count + 1
          new_total_evaluated_key_count = total_evaluated_key_count + key_count
          new_evaluated_key_sets = [keys | evaluated_key_sets]

          if any_of_incoming_evaluated_keys_dominate_successful_prefix?(
               evaluated,
               new_count,
               new_total_evaluated_key_count
             ) do
            reduce_anyOf_with_shared_evaluated_keys(
              rest,
              data,
              path,
              root,
              evaluated,
              new_count,
              new_total_evaluated_key_count,
              new_evaluated_key_sets,
              acc_errs
            )
          else
            reduce_anyOf(
              rest,
              data,
              path,
              root,
              evaluated,
              new_count,
              evaluated_key_sets_to_lists(new_evaluated_key_sets),
              acc_errs
            )
          end
        end

      {:error, errs} ->
        new_errs = if count == 0, do: [errs | acc_errs], else: acc_errs

        reduce_anyOf_with_shared_evaluated_keys(
          rest,
          data,
          path,
          root,
          evaluated,
          count,
          total_evaluated_key_count,
          evaluated_key_sets,
          new_errs
        )
    end
  end

  @doc """
  Validates data against schemas in a `oneOf` array.
  Exactly one schema must pass.
  """
  def validate_oneOf(data, schemas, path, root, evaluated) do
    reduce_oneOf(schemas, data, path, root, evaluated, 0, nil, [])
  end

  defp reduce_oneOf([], _data, _path, _root, _evaluated, 1, first_keys, _acc_errs) do
    {:ok, first_keys}
  end

  defp reduce_oneOf([], _data, _path, _root, _evaluated, 0, _first_keys, acc_errs) do
    {:error, List.flatten(Enum.reverse(acc_errs))}
  end

  defp reduce_oneOf([schema | rest], data, path, root, evaluated, count, first_keys, acc_errs) do
    case Validator.validate_entry(schema, data, path, root, evaluated) do
      {:ok, keys} ->
        if count == 0 do
          reduce_oneOf(rest, data, path, root, evaluated, 1, keys, acc_errs)
        else
          error = %Error{
            path: path,
            rule: :oneOf,
            context: %ErrorContext{
              contrast: 1,
              input: data
            }
          }

          {:error, [error]}
        end

      {:error, errs} ->
        new_errs = if count == 0, do: [errs | acc_errs], else: acc_errs
        reduce_oneOf(rest, data, path, root, evaluated, count, first_keys, new_errs)
    end
  end

  @doc """
  Validates data against a `not` schema. The schema must NOT match.
  """
  def validate_not(data, schema, path, root, evaluated) do
    case Validator.validate_entry(schema, data, path, root, evaluated) do
      {:error, _} ->
        :ok

      {:ok, _} ->
        error = %Error{
          path: path,
          rule: :not,
          context: %ErrorContext{input: data}
        }

        {:error, [error]}
    end
  end

  @doc """
  Validates array items against a `contains` schema with min/max constraints.
  """
  def validate_contains(data, schema, min, max, path, root) when is_list(data) do
    {match_count, matching_indices} =
      reduce_contains(data, schema, min, max, path, root, 0, 0, [])

    cond do
      match_count < min ->
        {:error, %ErrorContext{contrast: min, input: match_count, error_detail: "min"}}

      max != nil and match_count > max ->
        {:error, %ErrorContext{contrast: max, input: match_count, error_detail: "max"}}

      true ->
        if matching_indices == [], do: :ok, else: {:ok, MapSet.new(matching_indices)}
    end
  end

  def validate_contains(_, _, _, _, _, _), do: :ok

  defp reduce_contains(_data, _schema, _min, max, _path, _root, _index, count, indices)
       when is_integer(max) and count > max do
    {count, indices}
  end

  defp reduce_contains([], _schema, _min, _max, _path, _root, _index, count, indices) do
    {count, indices}
  end

  defp reduce_contains([item | rest], schema, min, max, path, root, index, count, indices) do
    case Validator.validate_entry(schema, item, [index | path], root) do
      {:error, _} ->
        reduce_contains(rest, schema, min, max, path, root, index + 1, count, indices)

      {:ok, _} ->
        reduce_contains(rest, schema, min, max, path, root, index + 1, count + 1, [
          index | indices
        ])
    end
  end

  @doc """
  Validates object properties against pattern-based schemas (`patternProperties`).
  """
  def validate_pattern_properties(data, compiled_patterns, path, root) when is_map(data) do
    data_list = Map.to_list(data)
    reduce_patterns(compiled_patterns, data_list, path, root, [], [])
  end

  def validate_pattern_properties(_, _, _, _), do: :ok

  @doc false
  def validate_pattern_properties(
        data,
        compiled_patterns,
        path,
        root,
        %{source: source} = cache
      )
      when is_map(data) and source in [nil, :pattern_properties] do
    cache = if source == nil, do: %{cache | source: :pattern_properties}, else: cache

    reduce_patterns_with_match_cache(
      compiled_patterns,
      Map.to_list(data),
      path,
      root,
      [],
      [],
      cache
    )
  end

  def validate_pattern_properties(
        data,
        compiled_patterns,
        path,
        root,
        %{source: :additional_properties} = cache
      )
      when is_map(data) do
    reduce_patterns_after_additional(
      compiled_patterns,
      Map.to_list(data),
      path,
      root,
      0,
      [],
      [],
      cache
    )
  end

  def validate_pattern_properties(data, compiled_patterns, path, root, cache) do
    {validate_pattern_properties(data, compiled_patterns, path, root), cache}
  end

  defp reduce_patterns_with_match_cache([], _data_list, _path, _root, [], [], cache),
    do: {:ok, cache}

  defp reduce_patterns_with_match_cache([], _data_list, _path, _root, [], eval_keys, cache),
    do: {{:ok, MapSet.new(eval_keys)}, cache}

  defp reduce_patterns_with_match_cache([], _data_list, _path, _root, errs, _eval_keys, cache),
    do: {{:error, List.flatten(errs)}, cache}

  defp reduce_patterns_with_match_cache(
         [{regex, schema} | rest_patterns],
         data_list,
         path,
         root,
         errs,
         eval_keys,
         cache
       ) do
    {errs, eval_keys, cache} =
      reduce_pattern_data_with_match_cache(data_list, regex, schema, path, root, errs, eval_keys, cache)

    reduce_patterns_with_match_cache(rest_patterns, data_list, path, root, errs, eval_keys, cache)
  end

  defp reduce_pattern_data_with_match_cache([], _regex, _schema, _path, _root, errs, eval_keys, cache),
    do: {errs, eval_keys, cache}

  defp reduce_pattern_data_with_match_cache(
         [{key, val} | rest],
         regex,
         schema,
         path,
         root,
         errs,
         eval_keys,
         cache
       ) do
    if Regex.match?(regex, key) do
      cache = mark_pattern_match(cache, key)

      case Validator.validate_entry(schema, val, [key | path], root) do
        {:error, new_errs} ->
          reduce_pattern_data_with_match_cache(
            rest,
            regex,
            schema,
            path,
            root,
            [new_errs | errs],
            eval_keys,
            cache
          )

        {:ok, _} ->
          reduce_pattern_data_with_match_cache(
            rest,
            regex,
            schema,
            path,
            root,
            errs,
            [key | eval_keys],
            cache
          )
      end
    else
      reduce_pattern_data_with_match_cache(
        rest,
        regex,
        schema,
        path,
        root,
        errs,
        eval_keys,
        cache
      )
    end
  end

  # additionalProperties ran first and already checked each non-property key up
  # to its first match. Preserve pattern-major validation while skipping only
  # those regex calls whose result is already known.
  defp reduce_patterns_after_additional([], _data_list, _path, _root, _index, [], [], cache),
    do: {:ok, cache}

  defp reduce_patterns_after_additional([], _data_list, _path, _root, _index, [], eval_keys, cache),
    do: {{:ok, MapSet.new(eval_keys)}, cache}

  defp reduce_patterns_after_additional([], _data_list, _path, _root, _index, errs, _eval_keys, cache),
    do: {{:error, List.flatten(errs)}, cache}

  defp reduce_patterns_after_additional(
         [{regex, schema} | rest_patterns],
         data_list,
         path,
         root,
         index,
         errs,
         eval_keys,
         cache
       ) do
    {errs, eval_keys} =
      reduce_pattern_data_after_additional(
        data_list,
        regex,
        schema,
        path,
        root,
        index,
        errs,
        eval_keys,
        cache
      )

    reduce_patterns_after_additional(
      rest_patterns,
      data_list,
      path,
      root,
      index + 1,
      errs,
      eval_keys,
      cache
    )
  end

  defp reduce_pattern_data_after_additional(
         [],
         _regex,
         _schema,
         _path,
         _root,
         _index,
         errs,
         eval_keys,
         _cache
       ),
       do: {errs, eval_keys}

  defp reduce_pattern_data_after_additional(
         [{key, val} | rest],
         regex,
         schema,
         path,
         root,
         index,
         errs,
         eval_keys,
         cache
       ) do
    if pattern_matches_after_additional?(cache, key, index, regex) do
      case Validator.validate_entry(schema, val, [key | path], root) do
        {:error, new_errs} ->
          reduce_pattern_data_after_additional(
            rest,
            regex,
            schema,
            path,
            root,
            index,
            [new_errs | errs],
            eval_keys,
            cache
          )

        {:ok, _} ->
          reduce_pattern_data_after_additional(
            rest,
            regex,
            schema,
            path,
            root,
            index,
            errs,
            [key | eval_keys],
            cache
          )
      end
    else
      reduce_pattern_data_after_additional(
        rest,
        regex,
        schema,
        path,
        root,
        index,
        errs,
        eval_keys,
        cache
      )
    end
  end

  defp pattern_matches_after_additional?(%{matches: matches}, key, index, regex) do
    case Map.fetch(matches, key) do
      {:ok, :no_match} ->
        false

      {:ok, {:first_match, ^index}} ->
        true

      {:ok, {:first_match, first_index}} when index < first_index ->
        false

      _ ->
        Regex.match?(regex, key)
    end
  end

  defp mark_pattern_match(%{matches: matches} = cache, key) do
    case matches do
      %{^key => _match} -> cache
      _ -> %{cache | matches: Map.put(matches, key, :matched)}
    end
  end

  defp reduce_patterns([], _data_list, _path, _root, [], []), do: :ok

  defp reduce_patterns([], _data_list, _path, _root, [], eval_keys),
    do: {:ok, MapSet.new(eval_keys)}

  defp reduce_patterns([], _data_list, _path, _root, errs, _eval_keys),
    do: {:error, List.flatten(errs)}

  defp reduce_patterns([{regex, schema} | rest_patterns], data_list, path, root, errs, eval_keys) do
    {errs2, eval_keys2} =
      reduce_pattern_data(data_list, regex, schema, path, root, errs, eval_keys)

    reduce_patterns(rest_patterns, data_list, path, root, errs2, eval_keys2)
  end

  defp reduce_pattern_data([], _regex, _schema, _path, _root, errs, eval_keys),
    do: {errs, eval_keys}

  defp reduce_pattern_data([{key, val} | rest], regex, schema, path, root, errs, eval_keys) do
    if Regex.match?(regex, key) do
      case Validator.validate_entry(schema, val, [key | path], root) do
        {:error, new_errs} ->
          reduce_pattern_data(rest, regex, schema, path, root, [new_errs | errs], eval_keys)

        {:ok, _} ->
          reduce_pattern_data(rest, regex, schema, path, root, errs, [key | eval_keys])
      end
    else
      reduce_pattern_data(rest, regex, schema, path, root, errs, eval_keys)
    end
  end

  @doc """
  Validates additional properties not covered by `properties` or `patternProperties`.
  """
  def validate_additional_properties(data, schema, known_props_set, patterns, path, root)
      when is_map(data) do
    reduce_additional(Map.to_list(data), schema, known_props_set, patterns, path, root, [], [])
  end

  def validate_additional_properties(_, _, _, _, _, _), do: :ok

  @doc false
  def validate_additional_properties_with_match_cache(
        data,
        schema,
        known_props_set,
        patterns,
        path,
        root,
        %{source: source} = cache
      )
      when is_map(data) and source in [nil, :additional_properties] do
    cache = if source == nil, do: %{cache | source: :additional_properties}, else: cache

    reduce_additional_with_match_cache(
      Map.to_list(data),
      schema,
      known_props_set,
      patterns,
      path,
      root,
      [],
      [],
      cache
    )
  end

  def validate_additional_properties_with_match_cache(
        data,
        schema,
        known_props_set,
        _patterns,
        path,
        root,
        %{source: :pattern_properties} = cache
      )
      when is_map(data) do
    reduce_additional_after_pattern(
      Map.to_list(data),
      schema,
      known_props_set,
      path,
      root,
      [],
      [],
      cache
    )
  end

  def validate_additional_properties_with_match_cache(
        data,
        schema,
        known_props_set,
        patterns,
        path,
        root,
        cache
      ) do
    {validate_additional_properties(data, schema, known_props_set, patterns, path, root), cache}
  end

  defp reduce_additional_with_match_cache(
         [],
         _schema,
         _known,
         _patterns,
         _path,
         _root,
         [],
         [],
         cache
       ),
       do: {:ok, cache}

  defp reduce_additional_with_match_cache(
         [],
         _schema,
         _known,
         _patterns,
         _path,
         _root,
         [],
         eval_keys,
         cache
       ),
       do: {{:ok, MapSet.new(eval_keys)}, cache}

  defp reduce_additional_with_match_cache(
         [],
         _schema,
         _known,
         _patterns,
         _path,
         _root,
         errs,
         _eval_keys,
         cache
       ),
       do: {{:error, List.flatten(errs)}, cache}

  defp reduce_additional_with_match_cache(
         [{key, val} | rest],
         schema,
         known,
         patterns,
         path,
         root,
         errs,
         eval_keys,
         cache
       ) do
    if MapSet.member?(known, key) do
      reduce_additional_with_match_cache(
        rest,
        schema,
        known,
        patterns,
        path,
        root,
        errs,
        eval_keys,
        cache
      )
    else
      {classification, cache} = classify_additional_pattern(cache, key, patterns)

      case classification do
        :no_match ->
          case Validator.validate_entry(schema, val, [key | path], root) do
            {:error, new_errs} ->
              reduce_additional_with_match_cache(
                rest,
                schema,
                known,
                patterns,
                path,
                root,
                [new_errs | errs],
                eval_keys,
                cache
              )

            {:ok, _} ->
              reduce_additional_with_match_cache(
                rest,
                schema,
                known,
                patterns,
                path,
                root,
                errs,
                [key | eval_keys],
                cache
              )
          end

        {:first_match, _index} ->
          reduce_additional_with_match_cache(
            rest,
            schema,
            known,
            patterns,
            path,
            root,
            errs,
            eval_keys,
            cache
          )
      end
    end
  end

  defp reduce_additional_after_pattern([], _schema, _known, _path, _root, [], [], cache),
    do: {:ok, cache}

  defp reduce_additional_after_pattern([], _schema, _known, _path, _root, [], eval_keys, cache),
    do: {{:ok, MapSet.new(eval_keys)}, cache}

  defp reduce_additional_after_pattern([], _schema, _known, _path, _root, errs, _eval_keys, cache),
    do: {{:error, List.flatten(errs)}, cache}

  defp reduce_additional_after_pattern(
         [{key, val} | rest],
         schema,
         known,
         path,
         root,
         errs,
         eval_keys,
         %{matches: matches} = cache
       ) do
    cond do
      MapSet.member?(known, key) ->
        reduce_additional_after_pattern(rest, schema, known, path, root, errs, eval_keys, cache)

      Map.has_key?(matches, key) ->
        reduce_additional_after_pattern(rest, schema, known, path, root, errs, eval_keys, cache)

      true ->
        case Validator.validate_entry(schema, val, [key | path], root) do
          {:error, new_errs} ->
            reduce_additional_after_pattern(
              rest,
              schema,
              known,
              path,
              root,
              [new_errs | errs],
              eval_keys,
              cache
            )

          {:ok, _} ->
            reduce_additional_after_pattern(
              rest,
              schema,
              known,
              path,
              root,
              errs,
              [key | eval_keys],
              cache
            )
        end
    end
  end

  defp classify_additional_pattern(%{matches: matches} = cache, key, patterns) do
    case Map.fetch(matches, key) do
      {:ok, classification} ->
        {classification, cache}

      :error ->
        classification = first_matching_pattern(patterns, key, 0)
        {classification, %{cache | matches: Map.put(matches, key, classification)}}
    end
  end

  defp first_matching_pattern([], _key, _index), do: :no_match

  defp first_matching_pattern([regex | rest], key, index) do
    if Regex.match?(regex, key) do
      {:first_match, index}
    else
      first_matching_pattern(rest, key, index + 1)
    end
  end

  defp reduce_additional([], _schema, _known, _patterns, _path, _root, [], []), do: :ok

  defp reduce_additional([], _schema, _known, _patterns, _path, _root, [], eval_keys),
    do: {:ok, MapSet.new(eval_keys)}

  defp reduce_additional([], _schema, _known, _patterns, _path, _root, errs, _eval_keys),
    do: {:error, List.flatten(errs)}

  defp reduce_additional(
         [{key, val} | rest],
         schema,
         known,
         patterns,
         path,
         root,
         errs,
         eval_keys
       ) do
    cond do
      MapSet.member?(known, key) ->
        reduce_additional(rest, schema, known, patterns, path, root, errs, eval_keys)

      patterns != [] and Enum.any?(patterns, &Regex.match?(&1, key)) ->
        reduce_additional(rest, schema, known, patterns, path, root, errs, eval_keys)

      true ->
        case Validator.validate_entry(schema, val, [key | path], root) do
          {:error, new_errs} ->
            reduce_additional(
              rest,
              schema,
              known,
              patterns,
              path,
              root,
              [new_errs | errs],
              eval_keys
            )

          {:ok, _} ->
            reduce_additional(rest, schema, known, patterns, path, root, errs, [key | eval_keys])
        end
    end
  end

  @doc """
  Collects additional property keys as evaluated without validation.
  Used when the `additionalProperties` sub-schema always passes (e.g., `true`).
  """
  def collect_additional_keys(data, known_props_set, patterns) when is_map(data) do
    reduce_collect_additional(Map.to_list(data), known_props_set, patterns, [])
  end

  def collect_additional_keys(_, _, _), do: :ok

  @doc false
  def collect_additional_keys_with_match_cache(
        data,
        known_props_set,
        patterns,
        %{source: source} = cache
      )
      when is_map(data) and source in [nil, :additional_properties] do
    cache = if source == nil, do: %{cache | source: :additional_properties}, else: cache

    reduce_collect_additional_with_match_cache(
      Map.to_list(data),
      known_props_set,
      patterns,
      [],
      cache
    )
  end

  def collect_additional_keys_with_match_cache(
        data,
        known_props_set,
        _patterns,
        %{source: :pattern_properties} = cache
      )
      when is_map(data) do
    reduce_collect_additional_after_pattern(Map.to_list(data), known_props_set, [], cache)
  end

  def collect_additional_keys_with_match_cache(data, known_props_set, patterns, cache) do
    {collect_additional_keys(data, known_props_set, patterns), cache}
  end

  defp reduce_collect_additional_with_match_cache([], _known, _patterns, [], cache),
    do: {:ok, cache}

  defp reduce_collect_additional_with_match_cache([], _known, _patterns, eval_keys, cache),
    do: {{:ok, MapSet.new(eval_keys)}, cache}

  defp reduce_collect_additional_with_match_cache(
         [{key, _val} | rest],
         known,
         patterns,
         eval_keys,
         cache
       ) do
    if MapSet.member?(known, key) do
      reduce_collect_additional_with_match_cache(rest, known, patterns, eval_keys, cache)
    else
      {classification, cache} = classify_additional_pattern(cache, key, patterns)

      case classification do
        :no_match ->
          reduce_collect_additional_with_match_cache(rest, known, patterns, [key | eval_keys], cache)

        {:first_match, _index} ->
          reduce_collect_additional_with_match_cache(rest, known, patterns, eval_keys, cache)
      end
    end
  end

  defp reduce_collect_additional_after_pattern([], _known, [], cache), do: {:ok, cache}

  defp reduce_collect_additional_after_pattern([], _known, eval_keys, cache),
    do: {{:ok, MapSet.new(eval_keys)}, cache}

  defp reduce_collect_additional_after_pattern(
         [{key, _val} | rest],
         known,
         eval_keys,
         %{matches: matches} = cache
       ) do
    cond do
      MapSet.member?(known, key) ->
        reduce_collect_additional_after_pattern(rest, known, eval_keys, cache)

      Map.has_key?(matches, key) ->
        reduce_collect_additional_after_pattern(rest, known, eval_keys, cache)

      true ->
        reduce_collect_additional_after_pattern(rest, known, [key | eval_keys], cache)
    end
  end

  defp reduce_collect_additional([], _known, _patterns, []), do: :ok

  defp reduce_collect_additional([], _known, _patterns, eval_keys),
    do: {:ok, MapSet.new(eval_keys)}

  defp reduce_collect_additional([{key, _val} | rest], known, patterns, eval_keys) do
    cond do
      MapSet.member?(known, key) ->
        reduce_collect_additional(rest, known, patterns, eval_keys)

      patterns != [] and Enum.any?(patterns, &Regex.match?(&1, key)) ->
        reduce_collect_additional(rest, known, patterns, eval_keys)

      true ->
        reduce_collect_additional(rest, known, patterns, [key | eval_keys])
    end
  end

  @doc """
  Validates data against an `if`/`then`/`else` conditional schema.
  """
  def validate_if(data, compiled_if, compiled_then, compiled_else, path, root, evaluated) do
    case Validator.validate_entry(compiled_if, data, path, root, evaluated) do
      {:ok, if_keys} ->
        if compiled_then do
          merged = MapSet.union(evaluated, if_keys)

          case Validator.validate_entry(compiled_then, data, path, root, merged) do
            {:ok, then_keys} ->
              {:ok, MapSet.union(if_keys, then_keys)}

            {:error, errs} ->
              {:error, errs}
          end
        else
          {:ok, if_keys}
        end

      {:error, _if_errors} ->
        if compiled_else do
          Validator.validate_entry(compiled_else, data, path, root, evaluated)
        else
          :ok
        end
    end
  end

  @doc """
  Validates property names against a schema (`propertyNames`).
  """
  def validate_property_names(data, compiled_sub, path, root) when is_map(data) do
    reduce_property_names(Map.to_list(data), compiled_sub, path, root, [])
  end

  def validate_property_names(_, _, _, _), do: :ok

  defp reduce_property_names([], _compiled_sub, _path, _root, []), do: :ok

  defp reduce_property_names([], _compiled_sub, _path, _root, errs),
    do: {:error, List.flatten(errs)}

  defp reduce_property_names([{key, _} | rest], compiled_sub, path, root, errs) do
    case Validator.validate_entry(compiled_sub, key, [key | path], root) do
      {:ok, _} ->
        reduce_property_names(rest, compiled_sub, path, root, errs)

      {:error, new_errs} ->
        reduce_property_names(rest, compiled_sub, path, root, [new_errs | errs])
    end
  end

  @doc """
  Validates dependent required properties (`dependentRequired`).
  """
  def validate_dependent_required(data, deps, path, _root) when is_map(data) do
    reduce_dependent_required(Map.to_list(deps), data, path, [])
  end

  def validate_dependent_required(_, _, _, _), do: :ok

  defp reduce_dependent_required([], _data, _path, []), do: :ok
  defp reduce_dependent_required([], _data, _path, errs), do: {:error, errs}

  defp reduce_dependent_required([{prop, required_keys} | rest], data, path, errs) do
    if Map.has_key?(data, prop) do
      case collect_missing_keys(required_keys, data, []) do
        [] ->
          reduce_dependent_required(rest, data, path, errs)

        missing ->
          err =
            build_error(
              path,
              :dependentRequired,
              %ErrorContext{input: prop, contrast: missing},
              data
            )

          reduce_dependent_required(rest, data, path, [err | errs])
      end
    else
      reduce_dependent_required(rest, data, path, errs)
    end
  end

  defp collect_missing_keys([], _data, acc), do: acc

  defp collect_missing_keys([req | rest], data, acc) do
    if Map.has_key?(data, req) do
      collect_missing_keys(rest, data, acc)
    else
      collect_missing_keys(rest, data, [req | acc])
    end
  end

  @doc """
  Validates an object against dependent schemas (`dependentSchemas`).
  Also used by the legacy `dependencies` keyword for schema-valued entries.
  """
  def validate_dependent_schemas(data, compiled_deps, path, root) when is_map(data) do
    reduce_dependent_schemas(Map.to_list(compiled_deps), data, path, root, [], [])
  end

  def validate_dependent_schemas(_, _, _, _), do: :ok

  defp reduce_dependent_schemas([], _data, _path, _root, [], eval_keys) do
    {:ok, MapSet.new(List.flatten(eval_keys))}
  end

  defp reduce_dependent_schemas([], _data, _path, _root, errs, _eval_keys) do
    {:error, List.flatten(errs)}
  end

  defp reduce_dependent_schemas([{prop, schema} | rest], data, path, root, errs, eval_keys) do
    if Map.has_key?(data, prop) do
      case Validator.validate_entry(schema, data, path, root) do
        {:ok, new_keys} ->
          if MapSet.size(new_keys) == 0 do
            reduce_dependent_schemas(rest, data, path, root, errs, eval_keys)
          else
            reduce_dependent_schemas(rest, data, path, root, errs, [
              MapSet.to_list(new_keys) | eval_keys
            ])
          end

        {:error, new_errs} ->
          reduce_dependent_schemas(rest, data, path, root, [new_errs | errs], eval_keys)
      end
    else
      reduce_dependent_schemas(rest, data, path, root, errs, eval_keys)
    end
  end

  # Retain the existing flatten-and-rebuild semantics when direct union would
  # otherwise change historical recursive handling of list-valued Elixir keys.
  defp merge_evaluated_key_sets([]), do: @empty_mapset

  defp merge_evaluated_key_sets(evaluated_key_sets) do
    evaluated_key_sets
    |> Enum.map(&MapSet.to_list/1)
    |> List.flatten()
    |> MapSet.new()
  end

  # Every successful anyOf child receives the same incoming evaluated keys.
  # Direct pairwise union helps only when that known shared portion dominates.
  # The fallback deliberately retains the historical recursive-flatten behavior.
  defp merge_any_of_evaluated_key_sets(
         evaluated_key_sets,
         evaluated,
         count,
         total_evaluated_key_count
       ) do
    if any_of_shared_evaluated_keys_dominate?(evaluated, count, total_evaluated_key_count) do
      merged_evaluated_keys = balanced_union_evaluated_key_sets(evaluated_key_sets)

      if list_free_evaluated_key_set?(merged_evaluated_keys) do
        merged_evaluated_keys
      else
        merge_evaluated_key_sets(evaluated_key_sets)
      end
    else
      merge_evaluated_key_sets(evaluated_key_sets)
    end
  end

  # The benchmark-derived gate requires known shared evaluated keys to make up
  # at least two thirds of successful child evaluated-key memberships before
  # unioning them.
  defp any_of_shared_evaluated_keys_dominate?(evaluated, count, total_evaluated_key_count) do
    count >= 4 and
      any_of_incoming_evaluated_keys_dominate_successful_prefix?(
        evaluated,
        count,
        total_evaluated_key_count
      )
  end

  # Once the processed successful-branch prefix is not dominated by incoming
  # evaluated keys, resume the original reducer rather than retaining raw
  # MapSets in hopes that a later branch restores the average. That conservative
  # choice keeps the fallback near its original allocation profile.
  defp any_of_incoming_evaluated_keys_dominate_successful_prefix?(
         evaluated,
         count,
         total_evaluated_key_count
       ) do
    shared_evaluated_key_count = MapSet.size(evaluated) * count
    3 * shared_evaluated_key_count >= 2 * total_evaluated_key_count
  end

  defp evaluated_key_sets_to_lists(evaluated_key_sets),
    do: Enum.map(evaluated_key_sets, &MapSet.to_list/1)

  defp list_free_evaluated_key_set?(evaluated_keys) do
    Enum.all?(evaluated_keys, &(not is_list(&1)))
  end

  defp balanced_union_evaluated_key_sets([]), do: @empty_mapset
  defp balanced_union_evaluated_key_sets([evaluated_keys]), do: evaluated_keys

  defp balanced_union_evaluated_key_sets(evaluated_key_sets) do
    evaluated_key_sets
    |> union_evaluated_key_pairs([])
    |> balanced_union_evaluated_key_sets()
  end

  defp union_evaluated_key_pairs([], acc), do: Enum.reverse(acc)

  defp union_evaluated_key_pairs([evaluated_keys], acc),
    do: Enum.reverse([evaluated_keys | acc])

  defp union_evaluated_key_pairs([left, right | rest], acc) do
    union_evaluated_key_pairs(rest, [MapSet.union(left, right) | acc])
  end

  @doc """
  Validates content against a schema after decoding (`contentSchema`).
  Only active when `content_assertion: true`.
  """
  def validate_content_schema(
        data,
        compiled_sub,
        content_media_type,
        content_encoding,
        path,
        root,
        _evaluated
      )
      when is_binary(data) do
    normalized_encoding = normalize_content_encoding(content_encoding)
    normalized_media_type = normalize_content_media_type(content_media_type)

    with {:ok, decoded} <- decode_content(data, normalized_encoding),
         {:ok, content_value} <- parse_content(decoded, normalized_media_type) do
      case Validator.validate_entry(compiled_sub, content_value, path, root, @empty_mapset) do
        {:error, errs} -> {:error, errs}
        {:ok, _} -> :ok
      end
    else
      {:error, {rule, context}} ->
        {:error, [build_error(path, rule, context, data)]}
    end
  end

  def validate_content_schema(_, _, _, _, _, _, _), do: :ok

  defp build_error(path, rule, context, data) do
    %Error{path: path, rule: rule, context: context, value: data}
  end

  defp normalize_content_encoding(nil), do: nil

  defp normalize_content_encoding(encoding) when is_binary(encoding) do
    encoding |> String.trim() |> String.downcase()
  end

  defp normalize_content_encoding(_), do: nil

  defp normalize_content_media_type(nil), do: nil

  defp normalize_content_media_type(media_type) when is_binary(media_type) do
    media_type
    |> String.split(";")
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_content_media_type(_), do: nil

  defp decode_content(data, nil), do: {:ok, data}

  defp decode_content(data, "base64") do
    data = String.trim(data)

    case Base.decode64(data) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {:error, {:contentEncoding, %ErrorContext{contrast: "base64", input: data}}}
    end
  end

  defp decode_content(data, "base64url") do
    data = String.trim(data)

    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        case Base.url_decode64(data, padding: true) do
          {:ok, decoded} ->
            {:ok, decoded}

          :error ->
            {:error, {:contentEncoding, %ErrorContext{contrast: "base64url", input: data}}}
        end
    end
  end

  defp decode_content(_data, encoding),
    do: {:error, {:contentEncoding, %ErrorContext{contrast: "unsupported", input: encoding}}}

  defp parse_content(data, nil), do: {:ok, data}

  defp parse_content(data, media_type) do
    if json_media_type?(media_type) do
      case JSONSchex.JSON.decode(data) do
        {:ok, json} ->
          {:ok, json}

        {:error, error} ->
          {:error,
           {:contentMediaType,
            %ErrorContext{contrast: "invalid", input: media_type, error_detail: error}}}
      end
    else
      {:error, {:contentMediaType, %ErrorContext{contrast: "unsupported", input: media_type}}}
    end
  end

  defp json_media_type?("application/json"), do: true

  defp json_media_type?(media_type) when is_binary(media_type) do
    String.ends_with?(media_type, "+json")
  end

end

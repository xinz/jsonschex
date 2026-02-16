defmodule JSONSchex.Validator.Keywords do
  @moduledoc """
  Runtime validation functions for complex JSON Schema keywords.

  Called by rule closures generated during compilation. Each function returns
  `:ok`, `{:ok, evaluated_keys}`, or `{:error, errors}`.
  """

  alias JSONSchex.Validator
  alias JSONSchex.Types.Error

  @empty_mapset MapSet.new()

  @doc """
  Validates an object's properties against a map of compiled schemas.
  Returns evaluated property keys on success.
  """
  def validate_properties_map(data, compiled_props, path, root) when is_map(data) do
    reduce_props(compiled_props, data, path, root, [], [])
  end

  def validate_properties_map(_, _, _, _), do: :ok

  defp reduce_props([], _data, _path, _root, [], []), do: {:ok, @empty_mapset}
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
  def validate_unevaluated_props(data, sub_schema, path, evaluated_keys, root) when is_map(data) do
    {errors, uneval_keys} =
      Enum.reduce(data, {[], []}, fn {key, val}, {acc_errs, acc_uneval} ->
        if MapSet.member?(evaluated_keys, key) do
          {acc_errs, acc_uneval}
        else
          case Validator.validate_entry(sub_schema, val, [key | path], root) do
            {:error, new_errs} -> {[new_errs | acc_errs], [key | acc_uneval]}
            _ok_case -> {acc_errs, [key | acc_uneval]}
          end
        end
      end)

    if errors == [], do: {:ok, MapSet.new(uneval_keys)}, else: {:error, List.flatten(errors)}
  end

  def validate_unevaluated_props(_, _, _, _, _), do: :ok

  @doc """
  Validates array items against prefix schemas (`prefixItems`).
  """
  def validate_prefix_items(data, schemas, path, root) when is_list(data) do
    {errs, evaluated} = reduce_prefix_items(schemas, data, path, root, 0, {[], @empty_mapset})

    if errs == [], do: {:ok, evaluated}, else: {:error, List.flatten(errs)}
  end
  def validate_prefix_items(_, _, _, _), do: :ok

  defp reduce_prefix_items([], _data, _path, _root, _index, acc), do: acc
  defp reduce_prefix_items(_schemas, [], _path, _root, _index, acc), do: acc
  defp reduce_prefix_items([schema | rest_schemas], [item | rest_data], path, root, index, {errs, evaluated}) do
    case Validator.validate_entry(schema, item, [index | path], root) do
      {:ok, _} ->
        reduce_prefix_items(rest_schemas, rest_data, path, root, index + 1, {errs, MapSet.put(evaluated, index)})

      {:error, new_errs} ->
        reduce_prefix_items(rest_schemas, rest_data, path, root, index + 1, {[new_errs | errs], evaluated})
    end
  end

  @doc """
  Validates array items starting from a given index (`items`).
  """
  def validate_items_array(data, schema, start_index, path, root) when is_list(data) do
    {errs, evaluated} = reduce_items_array(data, schema, start_index, path, root, 0, {[], @empty_mapset})

    if errs == [], do: {:ok, evaluated}, else: {:error, List.flatten(errs)}
  end
  def validate_items_array(_, _, _, _, _), do: :ok

  defp reduce_items_array([], _schema, _start_index, _path, _root, _index, acc), do: acc
  defp reduce_items_array([_ | rest], schema, start_index, path, root, index, acc) when index < start_index do
    reduce_items_array(rest, schema, start_index, path, root, index + 1, acc)
  end
  defp reduce_items_array([val | rest], schema, start_index, path, root, index, {errs, evaluated}) do
    case Validator.validate_entry(schema, val, [index | path], root) do
      {:ok, _} ->
        reduce_items_array(rest, schema, start_index, path, root, index + 1, {errs, MapSet.put(evaluated, index)})

      {:error, new_errs} ->
        reduce_items_array(rest, schema, start_index, path, root, index + 1, {[new_errs | errs], evaluated})
    end
  end

  @doc """
  Validates unevaluated array items against a schema.
  """
  def validate_unevaluated_items(data, schema, path, evaluated_indices, root) when is_list(data) do
    {errors, unevaluated} =
      reduce_unevaluated_items(data, schema, path, evaluated_indices, root, 0, {[], @empty_mapset})

    if errors == [], do: {:ok, unevaluated}, else: {:error, List.flatten(errors)}
  end
  def validate_unevaluated_items(_, _, _, _, _), do: :ok

  defp reduce_unevaluated_items([], _schema, _path, _evaluated, _root, _index, acc), do: acc
  defp reduce_unevaluated_items([val | rest], schema, path, evaluated_indices, root, index, {acc_errs, acc_uneval}) do
    if MapSet.member?(evaluated_indices, index) do
      reduce_unevaluated_items(rest, schema, path, evaluated_indices, root, index + 1, {acc_errs, acc_uneval})
    else
      case Validator.validate_entry(schema, val, [index | path], root) do
        {:ok, _} ->
          reduce_unevaluated_items(rest, schema, path, evaluated_indices, root, index + 1, {acc_errs, MapSet.put(acc_uneval, index)})

        {:error, new_errs} ->
          reduce_unevaluated_items(rest, schema, path, evaluated_indices, root, index + 1, {[new_errs | acc_errs], MapSet.put(acc_uneval, index)})
      end
    end
  end

  @doc """
  Validates data against all schemas in an `allOf` array.
  """
  def validate_allOf(data, schemas, path, root, _evaluated) do
    reduce_allOf(schemas, data, path, root, @empty_mapset, [])
  end

  defp reduce_allOf([], _data, _path, _root, acc_keys, []) do
    {:ok, acc_keys}
  end

  defp reduce_allOf([], _data, _path, _root, _acc_keys, error_lists) do
    {:error, List.flatten(Enum.reverse(error_lists))}
  end

  defp reduce_allOf([schema | rest], data, path, root, acc_keys, error_lists) do
    case Validator.validate_entry(schema, data, path, root, @empty_mapset) do
      {:ok, new_keys} ->
        merged =
          cond do
            map_size(new_keys.map) == 0 -> acc_keys
            map_size(acc_keys.map) == 0 -> new_keys
            true -> MapSet.union(acc_keys, new_keys)
          end

        reduce_allOf(rest, data, path, root, merged, error_lists)

      {:error, errs} ->
        reduce_allOf(rest, data, path, root, acc_keys, [errs | error_lists])
    end
  end

  @doc """
  Validates data against schemas in an `anyOf` array.
  """
  def validate_anyOf(data, schemas, path, root, evaluated) do
    reduce_anyOf(schemas, data, path, root, evaluated, 0, @empty_mapset, [])
  end

  defp reduce_anyOf([], _data, _path, _root, _evaluated, count, merged_keys, _error_lists) when count > 0 do
    {:ok, merged_keys}
  end

  defp reduce_anyOf([], _data, _path, _root, _evaluated, 0, _merged_keys, error_lists) do
    {:error, List.flatten(Enum.reverse(error_lists))}
  end

  defp reduce_anyOf([schema | rest], data, path, root, evaluated, count, acc_keys, acc_errs) do
    case Validator.validate_entry(schema, data, path, root, evaluated) do
      {:ok, keys} ->
        merged =
          cond do
            map_size(keys.map) == 0 -> acc_keys
            map_size(acc_keys.map) == 0 -> keys
            true -> MapSet.union(acc_keys, keys)
          end

        reduce_anyOf(rest, data, path, root, evaluated, count + 1, merged, acc_errs)

      {:error, errs} ->
        new_errs = if count == 0, do: [errs | acc_errs], else: acc_errs
        reduce_anyOf(rest, data, path, root, evaluated, count, acc_keys, new_errs)
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
            message: "Value matched more than one schema"
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
          message: "Value should not match schema"
        }
        {:error, [error]}
    end
  end

  @doc """
  Validates array items against a `contains` schema with min/max constraints.
  """
  def validate_contains(data, schema, min, max, path, root) when is_list(data) do
    {match_count, matching_indices, _index} =
      Enum.reduce(data, {0, @empty_mapset, 0}, fn item, {count, acc_indices, index} ->
        next =
          case Validator.validate_entry(schema, item, [index | path], root) do
            {:error, _} ->
              {count, acc_indices}
            {:ok, _} ->
              {count + 1, MapSet.put(acc_indices, index)}
          end

        {elem(next, 0), elem(next, 1), index + 1}
      end)

    cond do
      match_count < min ->
        {:error, %{min: min, count: match_count}}

      max != nil and match_count > max ->
        {:error, %{max: max, count: match_count}}

      true ->
        {:ok, matching_indices}
    end
  end
  def validate_contains(_, _, _, _, _, _), do: :ok

  @doc """
  Validates object properties against pattern-based schemas (`patternProperties`).
  """
  def validate_pattern_properties(data, compiled_patterns, path, root) when is_map(data) do
    data_list = Map.to_list(data)
    reduce_patterns(compiled_patterns, data_list, path, root, [], [])
  end
  def validate_pattern_properties(_, _, _, _), do: :ok

  defp reduce_patterns([], _data_list, _path, _root, [], []), do: {:ok, @empty_mapset}
  defp reduce_patterns([], _data_list, _path, _root, [], eval_keys), do: {:ok, MapSet.new(eval_keys)}
  defp reduce_patterns([], _data_list, _path, _root, errs, _eval_keys), do: {:error, List.flatten(errs)}

  defp reduce_patterns([{regex, schema} | rest_patterns], data_list, path, root, errs, eval_keys) do
    {errs2, eval_keys2} = reduce_pattern_data(data_list, regex, schema, path, root, errs, eval_keys)
    reduce_patterns(rest_patterns, data_list, path, root, errs2, eval_keys2)
  end

  defp reduce_pattern_data([], _regex, _schema, _path, _root, errs, eval_keys), do: {errs, eval_keys}

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
  def validate_additional_properties(data, schema, known_props_set, patterns, path, root) when is_map(data) do
    reduce_additional(Map.to_list(data), schema, known_props_set, patterns, path, root, [], [])
  end
  def validate_additional_properties(_, _, _, _, _, _), do: :ok

  defp reduce_additional([], _schema, _known, _patterns, _path, _root, [], []), do: {:ok, @empty_mapset}
  defp reduce_additional([], _schema, _known, _patterns, _path, _root, [], eval_keys), do: {:ok, MapSet.new(eval_keys)}
  defp reduce_additional([], _schema, _known, _patterns, _path, _root, errs, _eval_keys), do: {:error, List.flatten(errs)}

  defp reduce_additional([{key, val} | rest], schema, known, patterns, path, root, errs, eval_keys) do
    cond do
      MapSet.member?(known, key) ->
        reduce_additional(rest, schema, known, patterns, path, root, errs, eval_keys)

      patterns != [] and Enum.any?(patterns, &Regex.match?(&1, key)) ->
        reduce_additional(rest, schema, known, patterns, path, root, errs, eval_keys)

      true ->
        case Validator.validate_entry(schema, val, [key | path], root) do
          {:error, new_errs} ->
            reduce_additional(rest, schema, known, patterns, path, root, [new_errs | errs], eval_keys)

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

  defp reduce_collect_additional([], _known, _patterns, []), do: {:ok, @empty_mapset}
  defp reduce_collect_additional([], _known, _patterns, eval_keys), do: {:ok, MapSet.new(eval_keys)}

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
    errors =
      Enum.reduce(data, [], fn {key, _}, acc ->
        case Validator.validate_entry(compiled_sub, key, [key | path], root) do
          {:ok, _} ->
            acc

          {:error, new_errs} ->
            [new_errs | acc]
        end
      end)

    case errors do
      [] -> :ok
      errs -> {:error, List.flatten(errs)}
    end
  end
  def validate_property_names(_, _, _, _), do: :ok

  @doc """
  Validates dependent required properties (`dependentRequired`).
  """
  def validate_dependent_required(data, deps, path, _root) when is_map(data) do
    errors =
      Enum.reduce(deps, [], fn {prop, required_keys}, acc ->
        if Map.has_key?(data, prop) do
          missing = Enum.filter(required_keys, fn req -> not Map.has_key?(data, req) end)

          if missing == [] do
            acc
          else
            [build_error(path, :dependentRequired, %{property: prop, missing: missing}) | acc]
          end
        else
          acc
        end
      end)

    case errors do
      [] -> :ok
      errs -> {:error, errs}
    end
  end
  def validate_dependent_required(_, _, _, _), do: :ok

  @doc """
  Validates an object against dependent schemas (`dependentSchemas`).
  Also used by the legacy `dependencies` keyword for schema-valued entries.
  """
  def validate_dependent_schemas(data, compiled_deps, path, root) when is_map(data) do
    reduce_dependent_schemas(Map.to_list(compiled_deps), data, path, root, [], @empty_mapset)
  end
  def validate_dependent_schemas(_, _, _, _), do: :ok

  defp reduce_dependent_schemas([], _data, _path, _root, [], []) do
    {:ok, @empty_mapset}
  end
  defp reduce_dependent_schemas([], _data, _path, _root, [], eval_keys) do
    {:ok, eval_keys}
  end
  defp reduce_dependent_schemas([], _data, _path, _root, errs, _eval_keys) do
    {:error, errs}
  end
  defp reduce_dependent_schemas([{prop, schema} | rest], data, path, root, errs, eval_keys) do
    if Map.has_key?(data, prop) do
      case Validator.validate_entry(schema, data, path, root) do
        {:ok, new_keys} ->
          new_eval = if MapSet.size(new_keys) == 0, do: eval_keys, else: MapSet.union(eval_keys, new_keys)
          reduce_dependent_schemas(rest, data, path, root, errs, new_eval)
        {:error, new_errs} ->
          reduce_dependent_schemas(rest, data, path, root, new_errs ++ errs, eval_keys)
      end
    else
      reduce_dependent_schemas(rest, data, path, root, errs, eval_keys)
    end
  end

  @doc """
  Validates content against a schema after decoding (`contentSchema`).
  Only active when `content_assertion: true`.
  """
  def validate_content_schema(data, compiled_sub, content_media_type, content_encoding, path, root, _evaluated)
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
        {:error, [build_error(path, rule, context)]}

      {:error, context} ->
        {:error, [build_error(path, :contentSchema, context)]}
    end
  end
  def validate_content_schema(_, _, _, _, _, _, _), do: :ok

  defp build_error(path, rule, context) do
    %Error{path: path, rule: rule, context: context}
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
        {:error, {:contentEncoding, %{encoding: "base64"}}}
    end
  end
  defp decode_content(data, "base64url") do
    data = String.trim(data)

    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} ->
        {:ok, decoded}
      :error ->
        case Base.url_decode64(data, padding: true) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, {:contentEncoding, %{encoding: "base64url"}}}
        end
    end
  end
  defp decode_content(_data, encoding),
    do: {:error, {:contentEncoding, "Unsupported contentEncoding: #{encoding}"}}

  defp parse_content(data, nil), do: {:ok, data}
  defp parse_content(data, media_type) do
    if json_media_type?(media_type) do
      case JSONSchex.JSON.decode(data) do
        {:ok, json} -> {:ok, json}
        {:error, _} -> {:error, {:contentMediaType, %{media_type: media_type, error: :invalid_json}}}
      end
    else
      {:error, {:contentMediaType, %{media_type: media_type, error: :unsupported}}}
    end
  end

  defp json_media_type?("application/json"), do: true
  defp json_media_type?(media_type) when is_binary(media_type) do
    String.ends_with?(media_type, "+json")
  end
  defp json_media_type?(_), do: false
end

defmodule JSONSchex.Validator.Keywords.AnnotationFree do
  @moduledoc false
  # Annotation-free keyword validation paths (used when `evaluated == nil`).
  #
  # Skips `eval_keys` list construction and `MapSet.new/1` / `MapSet.union/2`
  # whenever no `unevaluatedProperties` or `unevaluatedItems` keyword applies
  # at the current instance location, while preserving full error collection.

  alias JSONSchex.Types.ErrorContext
  alias JSONSchex.Validator
  alias JSONSchex.Validator.Pattern

  def validate_properties_map(data, compiled_props, path, root) when is_map(data) do
    reduce_props(compiled_props, data, path, root, [])
  end

  def validate_properties_map(_, _, _, _), do: :ok

  defp reduce_props([], _data, _path, _root, []), do: :ok
  defp reduce_props([], _data, _path, _root, errs), do: {:error, List.flatten(errs)}

  defp reduce_props([{key, sub_schema} | rest], data, path, root, errs) do
    case data do
      %{^key => val} ->
        case Validator.validate_entry(sub_schema, val, [key | path], root, nil) do
          {:ok, _} -> reduce_props(rest, data, path, root, errs)
          {:error, new_errs} -> reduce_props(rest, data, path, root, [new_errs | errs])
        end

      _ ->
        reduce_props(rest, data, path, root, errs)
    end
  end

  def validate_items_array(data, schema, start_index, path, root) when is_list(data) do
    reduce_items(data, schema, start_index, path, root, 0, [])
  end

  def validate_items_array(_, _, _, _, _), do: :ok

  defp reduce_items([], _schema, _start_index, _path, _root, _index, []), do: :ok

  defp reduce_items([], _schema, _start_index, _path, _root, _index, errs),
    do: {:error, List.flatten(errs)}

  defp reduce_items([_ | rest], schema, start_index, path, root, index, errs)
       when index < start_index do
    reduce_items(rest, schema, start_index, path, root, index + 1, errs)
  end

  defp reduce_items([val | rest], schema, start_index, path, root, index, errs) do
    case Validator.validate_entry(schema, val, [index | path], root, nil) do
      {:ok, _} ->
        reduce_items(rest, schema, start_index, path, root, index + 1, errs)

      {:error, new_errs} ->
        reduce_items(rest, schema, start_index, path, root, index + 1, [new_errs | errs])
    end
  end

  def validate_prefix_items(data, schemas, path, root) when is_list(data) do
    reduce_prefix_items(schemas, data, path, root, 0, [])
  end

  def validate_prefix_items(_, _, _, _), do: :ok

  defp reduce_prefix_items([], _data, _path, _root, _index, []), do: :ok
  defp reduce_prefix_items(_schemas, [], _path, _root, _index, []), do: :ok
  defp reduce_prefix_items([], _data, _path, _root, _index, errs), do: {:error, List.flatten(errs)}

  defp reduce_prefix_items(_schemas, [], _path, _root, _index, errs),
    do: {:error, List.flatten(errs)}

  defp reduce_prefix_items([schema | rest_schemas], [item | rest_data], path, root, index, errs) do
    case Validator.validate_entry(schema, item, [index | path], root, nil) do
      {:ok, _} ->
        reduce_prefix_items(rest_schemas, rest_data, path, root, index + 1, errs)

      {:error, new_errs} ->
        reduce_prefix_items(rest_schemas, rest_data, path, root, index + 1, [new_errs | errs])
    end
  end

  def validate_all_of(data, schemas, path, root) do
    reduce_all_of(schemas, data, path, root, [])
  end

  defp reduce_all_of([], _data, _path, _root, []), do: :ok

  defp reduce_all_of([], _data, _path, _root, error_lists),
    do: {:error, List.flatten(Enum.reverse(error_lists))}

  defp reduce_all_of([schema | rest], data, path, root, error_lists) do
    case Validator.validate_entry(schema, data, path, root, nil) do
      {:ok, _} -> reduce_all_of(rest, data, path, root, error_lists)
      {:error, errs} -> reduce_all_of(rest, data, path, root, [errs | error_lists])
    end
  end

  def validate_any_of(data, schemas, path, root) do
    reduce_any_of(schemas, data, path, root, false, [])
  end

  defp reduce_any_of([], _data, _path, _root, true, _error_lists), do: :ok

  defp reduce_any_of([], _data, _path, _root, false, error_lists) do
    {:error, List.flatten(Enum.reverse(error_lists))}
  end

  defp reduce_any_of([schema | rest], data, path, root, matched?, error_lists) do
    case Validator.validate_entry(schema, data, path, root, nil) do
      {:ok, _} ->
        reduce_any_of(rest, data, path, root, true, error_lists)

      {:error, errs} ->
        next_errs = if matched?, do: error_lists, else: [errs | error_lists]
        reduce_any_of(rest, data, path, root, matched?, next_errs)
    end
  end

  def validate_if(data, compiled_if, compiled_then, compiled_else, path, root) do
    case Validator.validate_entry(compiled_if, data, path, root, nil) do
      {:ok, _} ->
        if compiled_then do
          case Validator.validate_entry(compiled_then, data, path, root, nil) do
            {:ok, _} -> :ok
            {:error, errs} -> {:error, errs}
          end
        else
          :ok
        end

      {:error, _if_errors} ->
        if compiled_else do
          case Validator.validate_entry(compiled_else, data, path, root, nil) do
            {:ok, _} -> :ok
            {:error, errs} -> {:error, errs}
          end
        else
          :ok
        end
    end
  end

  def validate_dependent_schemas(data, compiled_deps, path, root) when is_map(data) do
    reduce_dependent_schemas(Map.to_list(compiled_deps), data, path, root, [])
  end

  def validate_dependent_schemas(_, _, _, _), do: :ok

  defp reduce_dependent_schemas([], _data, _path, _root, []), do: :ok

  defp reduce_dependent_schemas([], _data, _path, _root, errs),
    do: {:error, List.flatten(errs)}

  defp reduce_dependent_schemas([{prop, schema} | rest], data, path, root, errs) do
    if Map.has_key?(data, prop) do
      case Validator.validate_entry(schema, data, path, root, nil) do
        {:ok, _} -> reduce_dependent_schemas(rest, data, path, root, errs)
        {:error, new_errs} -> reduce_dependent_schemas(rest, data, path, root, [new_errs | errs])
      end
    else
      reduce_dependent_schemas(rest, data, path, root, errs)
    end
  end

  def validate_contains(data, schema, min, max, path, root) when is_list(data) do
    match_count = reduce_contains(data, schema, min, max, path, root, 0, 0)

    cond do
      match_count < min ->
        {:error, %ErrorContext{contrast: min, input: match_count, error_detail: "min"}}

      max != nil and match_count > max ->
        {:error, %ErrorContext{contrast: max, input: match_count, error_detail: "max"}}

      true ->
        :ok
    end
  end

  def validate_contains(_, _, _, _, _, _), do: :ok

  defp reduce_contains(_data, _schema, _min, max, _path, _root, _index, count)
       when is_integer(max) and count > max do
    count
  end

  defp reduce_contains([], _schema, _min, _max, _path, _root, _index, count), do: count

  defp reduce_contains([item | rest], schema, min, max, path, root, index, count) do
    next_count =
      case Validator.validate_entry(schema, item, [index | path], root, nil) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end

    reduce_contains(rest, schema, min, max, path, root, index + 1, next_count)
  end

  def validate_additional_properties(data, schema, known_props_set, patterns, path, root)
      when is_map(data) do
    reduce_additional(Map.to_list(data), schema, known_props_set, patterns, path, root, [])
  end

  def validate_additional_properties(_, _, _, _, _, _), do: :ok

  defp reduce_additional([], _schema, _known, _patterns, _path, _root, []), do: :ok

  defp reduce_additional([], _schema, _known, _patterns, _path, _root, errs),
    do: {:error, List.flatten(errs)}

  defp reduce_additional([{key, val} | rest], schema, known, patterns, path, root, errs) do
    cond do
      MapSet.member?(known, key) ->
        reduce_additional(rest, schema, known, patterns, path, root, errs)

      patterns != [] and Enum.any?(patterns, &Pattern.match?(&1, key, [key | path])) ->
        reduce_additional(rest, schema, known, patterns, path, root, errs)

      true ->
        case Validator.validate_entry(schema, val, [key | path], root, nil) do
          {:ok, _} ->
            reduce_additional(rest, schema, known, patterns, path, root, errs)

          {:error, new_errs} ->
            reduce_additional(rest, schema, known, patterns, path, root, [new_errs | errs])
        end
    end
  end

  def validate_pattern_properties(data, compiled_patterns, path, root) when is_map(data) do
    reduce_patterns(compiled_patterns, Map.to_list(data), path, root, [])
  end

  def validate_pattern_properties(_, _, _, _), do: :ok

  defp reduce_patterns([], _data_list, _path, _root, []), do: :ok
  defp reduce_patterns([], _data_list, _path, _root, errs), do: {:error, List.flatten(errs)}

  defp reduce_patterns([{regex, schema} | rest_patterns], data_list, path, root, errs) do
    errs = reduce_pattern_data(data_list, regex, schema, path, root, errs)
    reduce_patterns(rest_patterns, data_list, path, root, errs)
  end

  defp reduce_pattern_data([], _regex, _schema, _path, _root, errs), do: errs

  defp reduce_pattern_data([{key, val} | rest], regex, schema, path, root, errs) do
    if Pattern.match?(regex, key, [key | path]) do
      case Validator.validate_entry(schema, val, [key | path], root, nil) do
        {:ok, _} ->
          reduce_pattern_data(rest, regex, schema, path, root, errs)

        {:error, new_errs} ->
          reduce_pattern_data(rest, regex, schema, path, root, [new_errs | errs])
      end
    else
      reduce_pattern_data(rest, regex, schema, path, root, errs)
    end
  end
end

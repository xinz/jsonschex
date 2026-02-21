defmodule JSONSchex.Compiler.Predicates do
  @moduledoc """
  Pure predicates for JSON Schema validation constraints.

  All functions return `:ok` or `{:error, context}`. Non-applicable data types
  pass validation (e.g., pattern checking on non-strings).
  """

  alias JSONSchex.Types.ErrorContext

  @doc """
  Checks if data matches the specified JSON Schema type(s).
  """
  @spec check_type(term(), String.t()) :: :ok | {:error, map()}
  def check_type(data, "string") when is_binary(data), do: :ok
  def check_type(data, "integer") when is_integer(data), do: :ok
  def check_type(data, "integer") when is_float(data) do
    if data == trunc(data), do: :ok, else: {:error, %ErrorContext{contrast: "integer", input: "float"}}
  end
  def check_type(data, "boolean") when is_boolean(data), do: :ok
  def check_type(data, "object") when is_map(data), do: :ok
  def check_type(data, "array") when is_list(data), do: :ok
  def check_type(data, "null") when is_nil(data), do: :ok
  def check_type(data, "number") when is_number(data), do: :ok
  def check_type(data, types) when is_list(types) do
    if Enum.any?(types, fn type -> check_type(data, type) == :ok end) do
      :ok
    else
      {:error, %ErrorContext{contrast: types, input: infer_type(data)}}
    end
  end
  def check_type(data, expected) do
    actual = infer_type(data)
    {:error, %ErrorContext{contrast: expected, input: actual}}
  end

  @doc "Checks `maximum`."
  def check_maximum(data, max) when is_number(data) and data <= max, do: :ok
  def check_maximum(data, max) when is_number(data), do: {:error, %ErrorContext{contrast: max, input: data}}
  def check_maximum(_, _), do: :ok

  @doc "Checks `minimum`."
  @spec check_minimum(number(), number()) :: :ok | {:error, map()}
  def check_minimum(data, min) when is_number(data) and data < min do
    {:error, %ErrorContext{contrast: min, input: data}}
  end
  def check_minimum(_, _), do: :ok

  @doc "Checks `exclusiveMaximum`."
  def check_exclusive_maximum(data, limit) when is_number(data) and data < limit, do: :ok
  def check_exclusive_maximum(data, limit) when is_number(data), do: {:error, %ErrorContext{contrast: limit, input: data}}
  def check_exclusive_maximum(_, _), do: :ok

  @doc "Checks `exclusiveMinimum`."
  def check_exclusive_minimum(data, limit) when is_number(data) and data > limit, do: :ok
  def check_exclusive_minimum(data, limit) when is_number(data), do: {:error, %ErrorContext{contrast: limit, input: data}}
  def check_exclusive_minimum(_, _), do: :ok

  @doc "Checks `multipleOf`."
  def check_multiple_of(data, 0), do: {:error, %ErrorContext{contrast: "invalid_factor", input: data}}
  def check_multiple_of(data, +0.0), do: {:error, %ErrorContext{contrast: "invalid_factor", input: data}}
  def check_multiple_of(data, factor) when is_number(data) do
    if JSONSchex.Compiler.Predicates.MultipleOf.valid?(data, factor) do
      :ok
    else
      {:error, %ErrorContext{contrast: factor, input: data}}
    end
  end
  def check_multiple_of(_, _), do: :ok

  @doc "Checks `const`."
  @spec check_const(term(), term()) :: :ok | {:error, map()}
  def check_const(data, const) do
    if data == const, do: :ok, else: {:error, %ErrorContext{contrast: const, input: data}}
  end

  @doc "Checks `minLength`."
  def check_min_length(data, min) when is_binary(data) do
    len = codepoint_length(data)
    if len >= min, do: :ok, else: {:error, %ErrorContext{contrast: min, input: len}}
  end
  def check_min_length(_, _), do: :ok

  @doc "Checks `maxLength`."
  def check_max_length(data, max) when is_binary(data) do
    len = codepoint_length(data)
    if len <= max, do: :ok, else: {:error, %ErrorContext{contrast: max, input: len}}
  end
  def check_max_length(_, _), do: :ok

  @doc "Checks `minProperties`."
  def check_min_properties(data, min) when is_map(data) do
    size = map_size(data)
    if size >= min, do: :ok, else: {:error, %ErrorContext{contrast: min, input: size}}
  end
  def check_min_properties(_, _), do: :ok

  @doc "Checks `maxProperties`."
  def check_max_properties(data, max) when is_map(data) do
    size = map_size(data)
    if size <= max, do: :ok, else: {:error, %ErrorContext{contrast: max, input: size}}
  end
  def check_max_properties(_, _), do: :ok

  @doc "Checks `minItems`."
  def check_min_items(data, min) when is_list(data) do
    len = length(data)
    if len >= min, do: :ok, else: {:error, %ErrorContext{contrast: min, input: len}}
  end
  def check_min_items(_, _), do: :ok

  @doc "Checks `maxItems`."
  def check_max_items(data, max) when is_list(data) do
    len = length(data)
    if len <= max, do: :ok, else: {:error, %ErrorContext{contrast: max, input: len}}
  end
  def check_max_items(_, _), do: :ok

  @doc """
  Checks `uniqueItems`. Uses `==` semantics (`1` equals `1.0`).
  """
  def check_unique_items([], true), do: :ok
  def check_unique_items([_], true), do: :ok
  def check_unique_items(data, true) when is_list(data) do
    has_duplicates =
      Enum.reduce_while(data, %{}, fn item, buckets ->
        key = unique_item_hash(item)

        case buckets do
          %{^key => bucket} ->
            if Enum.any?(bucket, fn x -> x == item end) do
              {:halt, true}
            else
              {:cont, Map.put(buckets, key, [item | bucket])}
            end

          _ ->
            {:cont, Map.put(buckets, key, [item])}
        end
      end) == true

    if has_duplicates do
      {:error, %ErrorContext{contrast: true, input: data}}
    else
      :ok
    end
  end
  # If uniqueItems is false (or data not list), validation passes
  def check_unique_items(_, _), do: :ok

  defp unique_item_hash(item) when is_integer(item), do: :erlang.phash2(item)
  defp unique_item_hash(item) when is_float(item) do
    if item == trunc(item) do
      :erlang.phash2(trunc(item))
    else
      :erlang.phash2(item)
    end
  end
  defp unique_item_hash(item), do: :erlang.phash2(item)

  defp codepoint_length(binary) do
    binary |> String.to_charlist() |> length()
  end

  defp infer_type(v) when is_binary(v), do: "string"
  defp infer_type(v) when is_integer(v), do: "integer"
  defp infer_type(v) when is_boolean(v), do: "boolean"
  defp infer_type(v) when is_map(v), do: "object"
  defp infer_type(v) when is_list(v), do: "array"
  defp infer_type(v) when is_nil(v), do: "null"
  defp infer_type(v) when is_float(v) do
    if v == trunc(v), do: "integer", else: "number"
  end
  defp infer_type(_), do: "unknown"

  @doc "Checks `enum`."
  @spec check_enum(term(), list()) :: :ok | {:error, map()}
  def check_enum(data, values) do
    if Enum.any?(values, fn v -> v == data end) do
      :ok
    else
      {:error, %ErrorContext{contrast: values, input: data}}
    end
  end

  @doc "Checks `pattern`."
  @spec check_pattern(String.t(), Regex.t()) :: :ok | {:error, map()}
  def check_pattern(data, regex) when is_binary(data) do
    if Regex.match?(regex, data) do
      :ok
    else
      {:error, %ErrorContext{contrast: regex, input: data}}
    end
  end
  def check_pattern(_, _), do: :ok
end

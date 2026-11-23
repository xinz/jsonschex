defmodule JSONSchex.Compiler.Predicates do
  @moduledoc """
  Pure predicates for JSON Schema validation constraints.

  Functions return `:ok` or `{:error, context}`. Non-applicable data types
  pass validation (e.g., pattern checking on non-strings). Regex engine errors
  abort validation rather than returning an invertible schema mismatch.
  """

  alias JSONSchex.Guards
  alias JSONSchex.PredefinedPattern
  alias JSONSchex.Types.ErrorContext
  alias JSONSchex.Validator.Pattern

  # A fixed compromise: it avoids the short non-ASCII regression from the
  # unrolled counter while keeping charlist allocation bounded.
  @charlist_byte_cutoff 256

  @doc """
  Checks if data matches the specified JSON Schema type(s).
  """
  @spec check_type(term(), String.t() | [String.t()]) :: :ok | {:error, ErrorContext.t()}
  # Keep literal heads: lower-allocation guards were not consistently faster.
  for type <- Guards.json_types() do
    def check_type(data, unquote(type))
        when unquote(Guards.type_check_ast(type, Macro.var(:data, nil))),
        do: :ok
  end

  def check_type(data, "integer") when is_float(data),
    do: {:error, %ErrorContext{contrast: "integer", input: "float"}}

  def check_type(data, types) when is_list(types) do
    if valid_type?(data, types) do
      :ok
    else
      {:error, %ErrorContext{contrast: types, input: infer_type(data)}}
    end
  end

  def check_type(data, expected) do
    {:error, %ErrorContext{contrast: expected, input: infer_type(data)}}
  end

  @doc false
  @spec valid_type?(term(), String.t() | [String.t()]) :: boolean()
  for type <- Guards.json_types() do
    def valid_type?(data, unquote(type)),
      do: unquote(Guards.type_check_ast(type, Macro.var(:data, nil)))
  end

  def valid_type?(data, types) when is_list(types), do: Enum.any?(types, &valid_type?(data, &1))
  def valid_type?(_data, _), do: false

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

  @doc "Checks `minLength`, returning an error for malformed UTF-8."
  def check_min_length(data, min) when is_binary(data) do
    case codepoint_length(data) do
      :error -> {:error, %ErrorContext{contrast: min, input: data, error_detail: "invalid_utf8"}}
      len -> if len >= min, do: :ok, else: {:error, %ErrorContext{contrast: min, input: len}}
    end
  end
  def check_min_length(_, _), do: :ok

  @doc false
  @spec valid_min_length?(term(), non_neg_integer()) :: boolean()
  def valid_min_length?(data, min) when is_binary(data) do
    case codepoint_length(data) do
      :error -> false
      len -> len >= min
    end
  end
  def valid_min_length?(_, _), do: true

  @doc "Checks `maxLength`, returning an error for malformed UTF-8."
  def check_max_length(data, max) when is_binary(data) do
    case codepoint_length(data) do
      :error -> {:error, %ErrorContext{contrast: max, input: data, error_detail: "invalid_utf8"}}
      len -> if len <= max, do: :ok, else: {:error, %ErrorContext{contrast: max, input: len}}
    end
  end
  def check_max_length(_, _), do: :ok

  @doc false
  @spec valid_max_length?(term(), non_neg_integer()) :: boolean()
  def valid_max_length?(data, max) when is_binary(data) do
    case codepoint_length(data) do
      :error -> false
      len -> len <= max
    end
  end
  def valid_max_length?(_, _), do: true

  @doc """
  Checks `uniqueItems`. Uses `==` semantics (`1` equals `1.0`).
  """
  def check_unique_items(data, true) when is_list(data) do
    if valid_unique_items?(data) do
      :ok
    else
      {:error, %ErrorContext{contrast: true, input: data}}
    end
  end
  # If uniqueItems is false (or data not list), validation passes
  def check_unique_items(_, _), do: :ok

  @doc false
  @spec valid_unique_items?(term()) :: boolean()
  def valid_unique_items?([]), do: true
  def valid_unique_items?([_]), do: true
  def valid_unique_items?(data) when is_list(data), do: unique_items?(data, %{})
  def valid_unique_items?(_), do: true

  defp unique_items?([], _buckets), do: true
  defp unique_items?([item | rest], buckets) do
    key = unique_item_hash(item)

    case buckets do
      %{^key => bucket} ->
        if Enum.any?(bucket, &(&1 == item)) do
          false
        else
          unique_items?(rest, Map.put(buckets, key, [item | bucket]))
        end
      _ ->
        unique_items?(rest, Map.put(buckets, key, [item]))
    end
  end

  defp unique_item_hash(item) when is_integer(item), do: :erlang.phash2(item)
  defp unique_item_hash(item) when is_float(item) do
    integer = trunc(item)
    if item == integer, do: :erlang.phash2(integer), else: :erlang.phash2(item)
  end
  defp unique_item_hash(item) when is_binary(item), do: :erlang.phash2(item)
  # Equal composites must reach the same bucket; map keys retain exact-key semantics.
  defp unique_item_hash(item) when is_list(item) or is_map(item) or is_tuple(item),
    do: :erlang.phash2(normalize_unique_item(item))
  defp unique_item_hash(item), do: :erlang.phash2(item)

  defp normalize_unique_item(item) when is_integer(item) or is_binary(item) or is_atom(item),
    do: item
  defp normalize_unique_item(item) when is_float(item) do
    integer = trunc(item)
    if item == integer, do: integer, else: item
  end
  defp normalize_unique_item([]), do: []
  defp normalize_unique_item([item | rest] = list) do
    normalized_item = normalize_unique_item(item)
    normalized_rest = normalize_unique_item(rest)

    # Strict comparison must notice integral-float rewrites despite numeric equality.
    if normalized_item === item and normalized_rest === rest,
      do: list, else: [normalized_item | normalized_rest]
  end
  defp normalize_unique_item(item) when is_map(item) do
    :maps.fold(fn key, value, acc ->
      normalized = normalize_unique_item(value)
      if normalized === value, do: acc, else: Map.put(acc, key, normalized)
    end, item, item)
  end
  defp normalize_unique_item(item) when is_tuple(item),
    do: item |> Tuple.to_list() |> Enum.map(&normalize_unique_item/1) |> List.to_tuple()
  defp normalize_unique_item(item), do: item

  # Keep the standard conversion for small and medium strings. The cutoff is
  # measured across UTF-8 widths; ASCII alone would favor the unrolled path sooner.
  defp codepoint_length(binary) when byte_size(binary) <= @charlist_byte_cutoff do
    binary |> String.to_charlist() |> length()
  rescue
    UnicodeConversionError -> :error
  end
  defp codepoint_length(binary), do: count_codepoints(binary, 0)

  # Count Unicode code points, not graphemes, without allocating a charlist.
  # Scan to the end or an encoding error: diagnostics need the exact length of
  # valid input, and permissive bounds must not silently accept malformed UTF-8.
  # A small unroll reduces loop overhead for mixed-width UTF-8; the next clause
  # handles the remaining one to three code points without padding or slicing.
  defp count_codepoints(<<_::utf8, _::utf8, _::utf8, _::utf8, rest::binary>>, count),
    do: count_codepoints(rest, count + 4)
  defp count_codepoints(<<_codepoint::utf8, rest::binary>>, count),
    do: count_codepoints(rest, count + 1)
  defp count_codepoints(<<>>, count), do: count
  defp count_codepoints(_invalid, _count), do: :error

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

  @doc "Checks `pattern`."
  @spec check_pattern(term(), Regex.t(), list()) :: :ok | {:error, map()}
  def check_pattern(data, regex, path) when is_binary(data) do
    if Pattern.match?(regex, data, path) do
      :ok
    else
      {:error, %ErrorContext{contrast: regex, input: data}}
    end
  end
  def check_pattern(_, _, _), do: :ok

  @doc false
  @spec check_predefined_pattern(term(), Regex.t(), PredefinedPattern.matcher()) :: :ok | {:error, ErrorContext.t()}
  def check_predefined_pattern(data, regex, matcher) when is_binary(data) do
    if PredefinedPattern.match?(matcher, data) do
      :ok
    else
      {:error, %ErrorContext{contrast: regex, input: data}}
    end
  end
  def check_predefined_pattern(_, _, _), do: :ok
end

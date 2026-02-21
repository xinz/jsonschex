defmodule JSONSchex.ErrorFormatter do
  @moduledoc """
  Formats `JSONSchex.Types.Error` and `JSONSchex.Types.CompileError` structs
  into human-readable strings.
  """
  alias JSONSchex.Types.Error
  alias JSONSchex.Types.CompileError

  import CompileError, only: [is_non_neg_int_keywords?: 1, is_numeric_keywords?: 1]

  @doc """
  Returns a human-readable message for the given `Error` or `CompileError`.
  """
  def format(%CompileError{error: :invalid_keyword_value, path: path, value: value}) do
    keyword = List.last(path)
    "#{format_invalid_keyword(keyword, value)}"
  end

  def format(%CompileError{error: :unsupported_vocabulary, path: path}) do
    "Unsupported required vocabulary: #{List.last(path)}"
  end

  def format(%CompileError{error: :invalid_regex, path: path, context: %{error_detail: error}}) do
    "Invalid regex at schema #{format_path(path)}: #{error}"
  end

  def format(%CompileError{error: error}) do
    "Schema compile error: #{inspect(error)}"
  end

  def format(%Error{} = error) do
    path = format_path(error.path)
    msg = format_message(error)
    if path == "/", do: msg, else: "At #{path}: #{msg}"
  end

  defp format_message(%Error{rule: :type, context: %{contrast: expected, input: input}})
       when is_list(expected) do
    "Expected one of types [#{Enum.join(expected, ", ")}], got #{input}"
  end

  defp format_message(%Error{rule: :type, context: %{contrast: expected, input: input}}) do
    "Expected type #{expected}, got #{input}"
  end

  defp format_message(%Error{rule: :minimum, context: %{contrast: min, input: input}}) do
    "Value #{input} is less than minimum #{min}"
  end

  defp format_message(%Error{rule: :maximum, context: %{contrast: max, input: input}}) do
    "Value #{input} is greater than maximum #{max}"
  end

  defp format_message(%Error{rule: :exclusiveMinimum, context: %{contrast: min, input: input}}) do
    "Value #{input} is less than or equal to exclusive minimum #{min}"
  end

  defp format_message(%Error{rule: :exclusiveMaximum, context: %{contrast: max, input: input}}) do
    "Value #{input} is greater than or equal to exclusive maximum #{max}"
  end

  defp format_message(%Error{rule: :minLength, context: %{contrast: min, input: len}}) do
    "String length #{len} is less than minimum #{min}"
  end

  defp format_message(%Error{rule: :maxLength, context: %{contrast: max, input: len}}) do
    "String length #{len} is greater than maximum #{max}"
  end

  defp format_message(%Error{rule: :minItems, context: %{contrast: min, input: len}}) do
    "Array has #{len} items, minimum is #{min}"
  end

  defp format_message(%Error{rule: :maxItems, context: %{contrast: max, input: len}}) do
    "Array has #{len} items, maximum is #{max}"
  end

  defp format_message(%Error{rule: :required, context: %{contrast: missing}}) do
    "Missing required properties: #{Enum.join(missing, ", ")}"
  end

  defp format_message(%Error{rule: :dependentRequired, context: %{input: prop, contrast: missing}}) do
    "Dependency failure: '#{prop}' requires #{inspect(missing)}"
  end

  defp format_message(%Error{rule: :contains, context: %{contrast: 1, error_detail: "min", input: 0}}) do
    "Array must contain at least one matching item, but none matched"
  end

  defp format_message(%Error{rule: :contains, context: %{contrast: 1, error_detail: "min"}}) do
    "Array must contain at least one matching item"
  end

  defp format_message(%Error{rule: :contains, context: %{contrast: min, error_detail: "min", input: count}}) do
    "Array must contain at least #{min} matching items, found #{count}"
  end

  defp format_message(%Error{rule: :contains, context: %{contrast: max, error_detail: "max", input: count}}) do
    "Array must contain at most #{max} matching items, found #{count}"
  end

  defp format_message(%Error{rule: :oneOf, context: %{contrast: 1, input: input}}) do
    "Failed 'oneOf' constraint: Value #{inspect(input)} is ambiguous because it matched multiple subschemas"
  end

  defp format_message(%Error{rule: :not, context: %{input: input}}) do
    "Failed 'not' constraint: Value #{inspect(input)} is explicitly forbidden"
  end



  defp format_message(%Error{rule: :contentEncoding, context: %{contrast: "unsupported", input: encoding}}) do
    "Unsupported content encoding: #{encoding}"
  end

  defp format_message(%Error{rule: :contentEncoding, context: %{contrast: encoding}}) do
    "Failed to decode content as #{encoding}"
  end

  defp format_message(%Error{rule: :contentMediaType, context: %{contrast: media_type, input: "invalid"}}) do
    "Invalid JSON contentMediaType: #{media_type}"
  end

  defp format_message(%Error{rule: :contentMediaType, context: %{contrast: media_type, input: "unsupported"}}) do
    "Unsupported contentMediaType: #{media_type}"
  end

  defp format_message(%Error{context: %{contrast: "compile_remote", input: uri, error_detail: error}}) do
    "Failed to compile remote schema '#{uri}': #{inspect(error)}"
  end

  defp format_message(%Error{context: %{contrast: "load_remote", input: uri, error_detail: reason}}) do
    "Failed to load remote schema '#{uri}': #{inspect(reason)}"
  end

  defp format_message(%Error{context: %{contrast: "invalid_loader_response", input: uri}}) do
    "Invalid loader response for '#{uri}'"
  end

  defp format_message(%Error{context: %{contrast: "invalid_schema", input: pointer, error_detail: error}}) do
    "Invalid schema at '#{pointer}': #{inspect(error)}"
  end

  defp format_message(%Error{context: %{contrast: "ref_not_found", input: pointer}}) do
    "Reference not found: #{pointer}"
  end

  defp format_message(%Error{rule: :multipleOf, context: %{contrast: factor, input: data}}) do
    "Value #{data} is not a multiple of #{factor}"
  end

  defp format_message(%Error{rule: :uniqueItems}) do
    "Array items must be unique"
  end

  defp format_message(%Error{rule: :minProperties, context: %{contrast: min, input: size}}) do
    "Object has #{size} properties, minimum is #{min}"
  end

  defp format_message(%Error{rule: :maxProperties, context: %{contrast: max, input: size}}) do
    "Object has #{size} properties, maximum is #{max}"
  end

  defp format_message(%Error{rule: :unevaluatedProperties, context: %{contrast: "not_allowed"}}) do
    "Property is not allowed"
  end

  defp format_message(%Error{rule: :unevaluatedItems, context: %{contrast: "not_allowed"}}) do
    "Item is not allowed"
  end

  defp format_message(%Error{rule: :enum, context: %{input: input, contrast: allowed}}) do
    "Value #{inspect(input)} is not in the allowed list: #{inspect(allowed)}"
  end

  defp format_message(%Error{rule: :const, context: %{input: input, contrast: expected}}) do
    "Value #{inspect(input)} does not match const: #{inspect(expected)}"
  end

  defp format_message(%Error{rule: :pattern, context: %{contrast: pattern, input: input}}) do
    "String #{inspect(input)} does not match pattern: #{inspect(pattern)}"
  end

  defp format_message(%Error{rule: :format, context: %{contrast: format, input: input}}) do
    "Invalid #{format} format: #{inspect(input)}"
  end

  defp format_message(%Error{rule: rule}), do: "Validation failed for rule: #{inspect(rule)}"

  defp format_path(path) when is_binary(path), do: path
  defp format_path([]), do: "/"
  defp format_path([single]) when is_binary(single) or is_integer(single), do: "/" <> to_string(single)
  defp format_path(path) when is_list(path) do
    iodata = [?/ | Enum.intersperse(Enum.reverse(path), ?/)]
    IO.iodata_to_binary(iodata)
  end
  defp format_path(_), do: "/"

  defp format_invalid_keyword("type", value) when is_binary(value) do
    valid = Enum.join(CompileError.valid_types(), ", ")
    "Keyword 'type' must be one of [#{valid}], got: #{inspect(value)}"
  end

  defp format_invalid_keyword("type", value) when is_list(value) do
    invalid = Enum.reject(value, &(is_binary(&1) and &1 in CompileError.valid_types()))
    "Keyword 'type' contains unknown type(s): #{Enum.join(invalid, ", ")}"
  end

  defp format_invalid_keyword("type", value) do
    "Keyword 'type' must be a type string or an array of type strings, got: #{inspect(value)}"
  end

  defp format_invalid_keyword("multipleOf", value) do
    "Keyword 'multipleOf' must be a strictly positive number, got: #{inspect(value)}"
  end

  defp format_invalid_keyword("uniqueItems", value) do
    "Keyword 'uniqueItems' must be a boolean, got: #{inspect(value)}"
  end

  defp format_invalid_keyword(kw, value) when is_numeric_keywords?(kw) do
    "Keyword '#{kw}' must be a number, got: #{inspect(value)}"
  end

  defp format_invalid_keyword(kw, value) when is_non_neg_int_keywords?(kw) do
    "Keyword '#{kw}' must be a non-negative integer, got: #{inspect(value)}"
  end

  defp format_invalid_keyword(kw, value) do
    "Keyword '#{kw}' has an invalid value: #{inspect(value)}"
  end
end

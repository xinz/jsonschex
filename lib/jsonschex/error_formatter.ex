defmodule JSONSchex.ErrorFormatter do
  @moduledoc "Formats `JSONSchex.Types.Error` structs into human-readable strings."
  alias JSONSchex.Types.Error

  @doc "Returns a human-readable message for the given error."
  def format(%Error{} = error) do
    path = format_path(error.path)
    msg = format_message(error)
    if path == "/", do: msg, else: "At #{path}: #{msg}"
  end

  defp format_message(%Error{message: msg}) when is_binary(msg) and byte_size(msg) > 0, do: msg

  defp format_message(%Error{rule: :type, context: %{expected: expected, actual: actual}}) do
    "Expected type #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp format_message(%Error{rule: :minimum, context: %{minimum: min, actual: actual}}) do
    "Value #{actual} is less than minimum #{min}"
  end

  defp format_message(%Error{rule: :maximum, context: %{maximum: max, actual: actual}}) do
    "Value #{actual} is greater than maximum #{max}"
  end

  defp format_message(%Error{rule: :exclusiveMinimum, context: %{minimum: min, actual: actual}}) do
    "Value #{actual} is less than or equal to exclusive minimum #{min}"
  end

  defp format_message(%Error{rule: :exclusiveMaximum, context: %{maximum: max, actual: actual}}) do
    "Value #{actual} is greater than or equal to exclusive maximum #{max}"
  end

  defp format_message(%Error{rule: :minLength, context: %{min: min, length: len}}) do
    "String length #{len} is less than minimum #{min}"
  end

  defp format_message(%Error{rule: :maxLength, context: %{max: max, length: len}}) do
    "String length #{len} is greater than maximum #{max}"
  end

  defp format_message(%Error{rule: :minItems, context: %{min: min, length: len}}) do
    "Array has #{len} items, minimum is #{min}"
  end

  defp format_message(%Error{rule: :maxItems, context: %{max: max, length: len}}) do
    "Array has #{len} items, maximum is #{max}"
  end

  defp format_message(%Error{rule: :required, context: %{missing: missing}}) do
    "Missing required properties: #{Enum.join(missing, ", ")}"
  end

  defp format_message(%Error{rule: :dependentRequired, context: %{property: prop, missing: missing}}) do
    "Dependency failure: '#{prop}' requires #{inspect(missing)}"
  end

  defp format_message(%Error{rule: :contains, context: %{min: 1, count: _count}}) do
    "Array must contain at least one matching item"
  end

  defp format_message(%Error{rule: :contains, context: %{min: min, count: count}}) do
    "Array must contain at least #{min} matching items, found #{count}"
  end

  defp format_message(%Error{rule: :contains, context: %{max: max, count: count}}) do
    "Array must contain at most #{max} matching items, found #{count}"
  end

  defp format_message(%Error{rule: :contentEncoding, context: %{encoding: encoding}}) do
    "Invalid #{encoding} contentEncoding"
  end

  defp format_message(%Error{rule: :contentMediaType, context: %{media_type: _media_type, error: :invalid_json}}) do
    "Invalid JSON contentMediaType"
  end

  defp format_message(%Error{rule: :contentMediaType, context: %{media_type: media_type, error: :unsupported}}) do
    "Unsupported contentMediaType: #{media_type}"
  end

  defp format_message(%Error{context: %{error: :compile_remote, uri: uri, detail: msg}}) do
    "Failed to compile remote schema '#{uri}': #{msg}"
  end

  defp format_message(%Error{context: %{error: :load_remote, uri: uri, detail: reason}}) do
    "Failed to load remote schema '#{uri}': #{reason}"
  end

  defp format_message(%Error{context: %{error: :invalid_loader_response, uri: uri}}) do
    "Invalid loader response for '#{uri}'"
  end

  defp format_message(%Error{context: %{error: :invalid_schema, pointer: pointer, detail: msg}}) do
    "Invalid schema at '#{pointer}': #{msg}"
  end

  defp format_message(%Error{context: %{error: :ref_not_found, pointer: pointer}}) do
    "Reference not found: #{pointer}"
  end

  defp format_message(%Error{rule: :unevaluatedProperties, context: %{error: :not_allowed}}) do
    "Property is not allowed"
  end

  defp format_message(%Error{rule: :unevaluatedItems, context: %{error: :not_allowed}}) do
    "Item is not allowed"
  end

  defp format_message(%Error{rule: :enum, context: %{value: val, allowed: allowed}}) do
    "Value #{inspect(val)} is not in the allowed list: #{inspect(allowed)}"
  end

  defp format_message(%Error{rule: :const, context: %{value: val, expected: exp}}) do
    "Value #{inspect(val)} does not match const: #{inspect(exp)}"
  end

  defp format_message(%Error{rule: :pattern, context: %{pattern: pattern}}) do
    "String does not match pattern: #{inspect(pattern)}"
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
end

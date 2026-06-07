defmodule JSONSchex.Compiler.Fragment do
  @moduledoc false

  alias JSONSchex.Types.{Error, ErrorContext}
  alias JSONSchex.URIUtil

  def entry(document, opts) do
    with {:ok, entry} <- fetch_entry(opts),
         {:ok, pointer, base_uri_from_entry} <- entry_to_pointer(entry),
         {:ok, entry_schema} <- resolve_entry(document, pointer),
         :ok <- validate_entry_schema(entry_schema, pointer) do
      {:ok, entry_schema, base_uri(opts, base_uri_from_entry)}
    end
  end

  defp base_uri(opts, base_uri_from_entry) do
    Keyword.get(opts, :base_uri) || base_uri_from_entry
  end

  def error(contrast, input, detail) do
    %Error{
      rule: :compile_fragment,
      path: [],
      context: %ErrorContext{contrast: contrast, input: input, error_detail: detail}
    }
  end

  defp fetch_entry(opts) do
    case Keyword.get(opts, :entry) do
      entry when is_binary(entry) ->
        {:ok, entry}

      nil ->
        {:error,
         error(
           "missing_entry",
           nil,
           "Expected :entry option"
         )}

      entry ->
        {:error,
         error(
           "invalid_entry",
           entry,
           "Entry must be a JSON Pointer or URI reference string"
         )}
    end
  end

  defp entry_to_pointer(""), do: {:ok, "", nil}
  defp entry_to_pointer("#"), do: {:ok, "#", nil}
  defp entry_to_pointer("#" <> _ = pointer), do: {:ok, pointer, nil}
  defp entry_to_pointer(entry) do
    entry
    |> URIUtil.split_fragment()
    |> entry_to_pointer(entry)
  end

  defp entry_to_pointer({"", _fragment}, "/" <> _ = entry) do
    {:ok, entry, nil}
  end
  defp entry_to_pointer({"", nil}, entry) do
    invalid_entry(entry)
  end
  defp entry_to_pointer({base, nil}, "/" <> _ = entry) do
    {:ok, entry, base}
  end
  defp entry_to_pointer({base, nil}, entry) when is_binary(base) do
    invalid_entry(entry)
  end
  defp entry_to_pointer({base, fragment}, _entry) do
    {:ok, "#" <> fragment, base}
  end

  defp invalid_entry(entry) do
    {:error,
     error(
       "invalid_entry",
       entry,
       "Entry must be a JSON Pointer or URI reference string with a fragment"
     )}
  end

  defp resolve_entry(document, pointer) do
    case ExJSONPointer.resolve(document, pointer) do
      {:ok, entry_schema} ->
        {:ok, entry_schema}

      {:error, reason} ->
        {:error,
         error(
           "entry_not_found",
           pointer,
           reason
         )}
    end
  end

  defp validate_entry_schema(entry_schema, _pointer) when is_map(entry_schema) or is_boolean(entry_schema),
    do: :ok

  defp validate_entry_schema(_entry_schema, pointer) do
    {:error,
     error(
       "invalid_entry_schema",
       pointer,
       "The entrypoint must resolve to a JSON Schema map or boolean"
     )}
  end
end

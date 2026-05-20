defmodule JSONSchex.Compiler.Fragment do
  @moduledoc false

  alias JSONSchex.Types.{Error, ErrorContext}
  alias JSONSchex.URIUtil

  @doc false
  def entry(document, opts) do
    base_uri = base_uri(opts)

    with {:ok, pointer} <- entry_pointer(opts),
         {:ok, entry_schema} <- resolve_entry(document, pointer),
         :ok <- validate_entry_schema(entry_schema, pointer) do
      {:ok, entry_schema, base_uri}
    end
  end

  @doc false
  def base_uri(opts) do
    Keyword.get(opts, :base_uri) || entry_ref_base_uri(opts)
  end

  @doc false
  def error(contrast, input, detail) do
    %Error{
      rule: :compile_fragment,
      path: [],
      context: %ErrorContext{contrast: contrast, input: input, error_detail: detail}
    }
  end

  defp entry_ref_base_uri(opts) do
    case Keyword.get(opts, :entry_ref) do
      entry_ref when is_binary(entry_ref) ->
        case URIUtil.split_fragment(entry_ref) do
          {"", _fragment} -> nil
          {base, _fragment} -> base
        end

      _ ->
        nil
    end
  end

  defp entry_pointer(opts) do
    entry_pointer = Keyword.get(opts, :entry_pointer)
    entry_ref = Keyword.get(opts, :entry_ref)

    cond do
      is_binary(entry_pointer) and is_binary(entry_ref) ->
        {:error,
         error(
           "ambiguous_entrypoint",
           nil,
           "Expected exactly one of :entry_pointer or :entry_ref"
         )}

      is_binary(entry_pointer) ->
        canonical_entry_pointer(entry_pointer)

      is_binary(entry_ref) ->
        entry_ref_to_pointer(entry_ref)

      true ->
        {:error,
         error(
           "missing_entry_pointer",
           nil,
           "Expected exactly one of :entry_pointer or :entry_ref"
         )}
    end
  end

  defp canonical_entry_pointer(""), do: {:ok, ""}
  defp canonical_entry_pointer("#"), do: {:ok, "#"}
  defp canonical_entry_pointer("#" <> _ = pointer), do: {:ok, pointer}
  defp canonical_entry_pointer("/" <> _ = pointer), do: {:ok, pointer}

  defp canonical_entry_pointer(pointer) do
    {:error,
     error(
       "invalid_entry_pointer",
       pointer,
       "Entry pointer must be a JSON Pointer such as #/components/schemas/User or /components/schemas/User"
     )}
  end

  defp entry_ref_to_pointer(ref) do
    {_base, fragment} = URIUtil.split_fragment(ref)

    case fragment do
      nil -> {:ok, "#"}
      "/" <> _ = pointer -> {:ok, "#" <> pointer}
      other -> {:ok, "#" <> other}
    end
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

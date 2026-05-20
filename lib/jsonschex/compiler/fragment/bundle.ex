defmodule JSONSchex.Compiler.Fragment.Bundle do
  @moduledoc false

  alias JSONSchex.Compiler.Fragment
  alias JSONSchex.Types.{Error, ErrorContext}
  alias JSONSchex.URIUtil

  @doc false
  def bundle(document, opts) when (is_map(document) or is_boolean(document)) and is_list(opts) do
    with {:ok, entry_schema, base_uri} <- Fragment.entry(document, opts),
         {:ok, bundle} <- build(document, entry_schema, base_uri, opts) do
      {:ok, bundle}
    end
  end

  def bundle(_document, _opts) do
    {:error,
     Fragment.error(
       "invalid_document",
       nil,
       "JSONSchex.bundle_fragment/2 expects the document to be a map or boolean"
     )}
  end

  defp build(_document, entry_schema, _base_uri, _opts) when is_boolean(entry_schema) do
    {:ok, entry_schema}
  end

  defp build(document, entry_schema, base_uri, opts) when is_map(entry_schema) do
    bundle =
      document
      |> merge_entry_schema(entry_schema)
      |> put_bundle_base_uri(base_uri)

    with {:ok, {external_resources, base_aliases}} <- collect_external_resources(bundle, base_uri, opts) do
      bundle = rewrite_external_refs(bundle, base_uri, base_aliases)
      {:ok, put_external_resources(bundle, external_resources)}
    end
  end

  defp merge_entry_schema(document, entry_schema) when is_map(document) do
    Map.merge(document, entry_schema)
  end

  defp merge_entry_schema(_document, entry_schema), do: entry_schema

  defp put_bundle_base_uri(bundle, base_uri) when is_map(bundle) and is_binary(base_uri) do
    Map.put_new(bundle, "$id", base_uri)
  end

  defp put_bundle_base_uri(bundle, _base_uri), do: bundle

  defp collect_external_resources(bundle, base_uri, opts) do
    loader = Keyword.get(opts, :loader)

    bundle
    |> collect_external_ref_bases(base_uri)
    |> load_external_resources(loader, %{}, %{})
  end

  defp collect_external_ref_bases(schema, base_uri) do
    schema
    |> do_collect_external_ref_bases(base_uri, base_uri, MapSet.new())
    |> MapSet.to_list()
  end

  defp do_collect_external_ref_bases(schema, current_base, root_base, refs) when is_map(schema) do
    new_base = URIUtil.resolve(current_base, Map.get(schema, "$id"))

    refs =
      ["$ref", "$dynamicRef"]
      |> Enum.reduce(refs, fn keyword, acc ->
        case Map.get(schema, keyword) do
          ref when is_binary(ref) ->
            new_base
            |> URIUtil.resolve(ref)
            |> external_ref_base(root_base)
            |> maybe_put_ref_base(acc)

          _ ->
            acc
        end
      end)

    Enum.reduce(schema, refs, fn {_key, value}, acc ->
      do_collect_external_ref_bases(value, new_base, root_base, acc)
    end)
  end

  defp do_collect_external_ref_bases(list, current_base, root_base, refs) when is_list(list) do
    Enum.reduce(list, refs, fn value, acc ->
      do_collect_external_ref_bases(value, current_base, root_base, acc)
    end)
  end

  defp do_collect_external_ref_bases(_value, _current_base, _root_base, refs), do: refs

  defp external_ref_base(nil, _root_base), do: nil

  defp external_ref_base(ref, root_base) do
    {base, _fragment} = URIUtil.split_fragment(ref)

    cond do
      base == "" -> nil
      is_binary(root_base) and base == root_base -> nil
      true -> base
    end
  end

  defp maybe_put_ref_base(nil, refs), do: refs
  defp maybe_put_ref_base(base, refs), do: MapSet.put(refs, base)

  defp load_external_resources([], _loader, resources, base_aliases), do: {:ok, {resources, base_aliases}}

  defp load_external_resources([base | rest], loader, resources, base_aliases) do
    effective_base = Map.get(base_aliases, base, base)

    cond do
      Map.has_key?(resources, effective_base) ->
        load_external_resources(rest, loader, resources, base_aliases)

      not is_function(loader, 1) ->
        {:error, %Error{context: %ErrorContext{contrast: "load_remote", input: base, error_detail: :no_loader}}}

      true ->
        with {:ok, document, loaded_base} <- load_resource(loader, base) do
          document = put_bundle_base_uri(document, loaded_base)
          nested_refs = collect_external_ref_bases(document, loaded_base)
          resources = Map.put(resources, loaded_base, document)
          base_aliases = Map.put(base_aliases, base, loaded_base)
          pending = Enum.uniq(rest ++ nested_refs)
          load_external_resources(pending, loader, resources, base_aliases)
        end
    end
  end

  defp load_resource(loader, base) do
    case loader.(base) do
      {:ok, %{document: document} = loaded} when is_map(document) or is_boolean(document) ->
        {:ok, document, base_uri_or_original(Map.get(loaded, :base_uri), base)}

      {:ok, document} when is_map(document) or is_boolean(document) ->
        {:ok, document, base}

      {:error, reason} ->
        {:error, %Error{context: %ErrorContext{contrast: "load_remote", input: base, error_detail: reason}}}

      _ ->
        {:error, %Error{context: %ErrorContext{contrast: "invalid_loader_response", input: base}}}
    end
  end

  defp base_uri_or_original(base_uri, _original_base) when is_binary(base_uri), do: base_uri
  defp base_uri_or_original(_base_uri, original_base), do: original_base

  defp rewrite_external_refs(value, _current_base, base_aliases) when map_size(base_aliases) == 0 do
    value
  end

  defp rewrite_external_refs(schema, current_base, base_aliases) when is_map(schema) do
    new_base = URIUtil.resolve(current_base, Map.get(schema, "$id"))

    schema
    |> Enum.map(fn
      {keyword, ref} when keyword in ["$ref", "$dynamicRef"] and is_binary(ref) ->
        {keyword, rewrite_external_ref(ref, new_base, base_aliases)}

      {key, value} ->
        {key, rewrite_external_refs(value, new_base, base_aliases)}
    end)
    |> Map.new()
  end

  defp rewrite_external_refs(list, current_base, base_aliases) when is_list(list) do
    Enum.map(list, &rewrite_external_refs(&1, current_base, base_aliases))
  end

  defp rewrite_external_refs(value, _current_base, _base_aliases), do: value

  defp rewrite_external_ref(ref, current_base, base_aliases) do
    resolved = URIUtil.resolve(current_base, ref)
    {base, fragment} = URIUtil.split_fragment(resolved)

    case Map.get(base_aliases, base) do
      nil -> ref
      ^base -> ref
      aliased_base -> URIUtil.with_fragment(aliased_base, fragment)
    end
  end

  defp put_external_resources(bundle, resources) when map_size(resources) == 0 do
    bundle
  end

  defp put_external_resources(bundle, resources) do
    external_defs =
      resources
      |> Enum.sort_by(fn {base, _document} -> base end)
      |> Enum.with_index(1)
      |> Map.new(fn {{base, document}, index} ->
        {"jsonschex_external_#{index}", put_bundle_base_uri(document, base)}
      end)

    Map.update(bundle, "$defs", external_defs, fn defs ->
      Map.merge(defs, external_defs)
    end)
  end
end

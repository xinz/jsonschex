defmodule JSONSchex.Draft202012.ScopeScanner do
  @moduledoc false

  alias JSONSchex.{SchemaTraversal, URIUtil}

  def scan(schema, opts \\ []) do
    base_uri = Keyword.get(opts, :base_uri)
    owner = %{raw: schema, source_id: base_uri}

    do_scan(schema, base_uri, owner, {%{}, MapSet.new()})
    |> finish(opts)
  end

  def scan_all(document, base_uri, opts) do
    owner = %{raw: document, source_id: base_uri}

    do_scan_all(document, base_uri, owner, {%{}, MapSet.new()})
    |> finish(opts)
  end

  defp do_scan(schema, base_uri, owner, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""
    owner = update_resource_owner(schema, current_id, base_uri, new_base_uri, owner)
    entry = %{schema: schema, resource: owner}

    registry =
      if current_id do
        Map.put(registry, new_base_uri, entry)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(entry, "$anchor", new_base_uri)
      |> register_anchor(entry, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    SchemaTraversal.reduce_scope_subschemas(schema, {registry, refs}, fn subschema, acc ->
      do_scan(subschema, new_base_uri, owner, acc)
    end)
  end

  defp do_scan(_value, _base_uri, _owner, acc), do: acc

  defp do_scan_all(schema, base_uri, owner, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = if is_binary(current_id), do: URIUtil.resolve(base_uri, current_id), else: base_uri
    new_base_uri = new_base_uri || ""
    owner = update_resource_owner(schema, current_id, base_uri, new_base_uri, owner)
    entry = %{schema: schema, resource: owner}

    registry =
      if is_binary(current_id) do
        Map.put(registry, new_base_uri, entry)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(entry, "$anchor", new_base_uri)
      |> register_anchor(entry, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    Enum.reduce(schema, {registry, refs}, fn {_key, value}, acc ->
      do_scan_all(value, new_base_uri, owner, acc)
    end)
  end

  defp do_scan_all(list, base_uri, owner, acc) when is_list(list) do
    Enum.reduce(list, acc, fn item, inner_acc -> do_scan_all(item, base_uri, owner, inner_acc) end)
  end

  defp do_scan_all(_value, _base_uri, _owner, acc), do: acc

  defp update_resource_owner(schema, id, parent_base, resolved_base, owner) when is_binary(id) do
    resource_uri = URIUtil.base(resolved_base)

    # An ID can change the reference base without establishing a new resource owner.
    if URIUtil.base(id) != "" and resource_uri != URIUtil.base(parent_base || "") do
      %{raw: schema, source_id: resource_uri}
    else
      owner
    end
  end

  defp update_resource_owner(_schema, _id, _parent_base, _resolved_base, owner), do: owner

  defp finish({registry, refs}, opts) do
    raw_registry = Map.new(registry, fn {id, %{schema: schema}} -> {id, schema} end)

    if Keyword.get(opts, :with_resource_contexts, false) == true do
      contexts = Map.new(registry, fn {id, %{resource: owner}} -> {id, owner} end)
      {raw_registry, refs, contexts}
    else
      {raw_registry, refs}
    end
  end

  defp collect_refs(schema, refs) do
    Enum.reduce(["$ref", "$dynamicRef"], refs, fn key, acc ->
      case Map.get(schema, key) do
        "#" <> _ = value -> MapSet.put(acc, value)
        _ -> acc
      end
    end)
  end

  defp register_anchor(acc, %{schema: schema} = entry, keyword, base_uri) do
    case Map.get(schema, keyword) do
      anchor when is_binary(anchor) -> Map.put(acc, base_uri <> "#" <> anchor, entry)
      _ -> acc
    end
  end
end

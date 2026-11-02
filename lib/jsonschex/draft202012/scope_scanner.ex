defmodule JSONSchex.Draft202012.ScopeScanner do
  @moduledoc false

  alias JSONSchex.{SchemaTraversal, URIUtil}

  def scan_schema(schema, opts \\ []) do
    base_uri = Keyword.get(opts, :base_uri)
    {owner, registry} = initial_registry(schema, base_uri, opts)

    do_scan_schema(schema, base_uri, owner, {registry, MapSet.new()})
    |> finish()
  end

  def scan_document(document, base_uri, opts) do
    {owner, registry} = initial_registry(document, base_uri, opts)

    do_scan_document(document, base_uri, owner, {registry, MapSet.new()})
    |> finish()
  end

  defp do_scan_schema(schema, base_uri, owner, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""
    owner = update_resource_owner(schema, current_id, base_uri, new_base_uri, owner)

    registry =
      if current_id do
        put_scope(registry, new_base_uri, schema, owner)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(schema, owner, "$anchor", new_base_uri)
      |> register_anchor(schema, owner, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    SchemaTraversal.reduce_scope_subschemas(schema, {registry, refs}, fn subschema, acc ->
      do_scan_schema(subschema, new_base_uri, owner, acc)
    end)
  end

  defp do_scan_schema(_value, _base_uri, _owner, acc), do: acc

  defp do_scan_document(schema, base_uri, owner, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = if is_binary(current_id), do: URIUtil.resolve(base_uri, current_id), else: base_uri
    new_base_uri = new_base_uri || ""
    owner = update_resource_owner(schema, current_id, base_uri, new_base_uri, owner)

    registry =
      if is_binary(current_id) do
        put_scope(registry, new_base_uri, schema, owner)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(schema, owner, "$anchor", new_base_uri)
      |> register_anchor(schema, owner, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    Enum.reduce(schema, {registry, refs}, fn {_key, value}, acc ->
      do_scan_document(value, new_base_uri, owner, acc)
    end)
  end

  defp do_scan_document(list, base_uri, owner, acc) when is_list(list) do
    Enum.reduce(list, acc, fn item, inner_acc -> do_scan_document(item, base_uri, owner, inner_acc) end)
  end

  defp do_scan_document(_value, _base_uri, _owner, acc), do: acc

  defp update_resource_owner(_schema, _id, _parent_base, _resolved_base, nil), do: nil

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

  defp initial_registry(schema, base_uri, opts) do
    if Keyword.get(opts, :with_resource_contexts, false) == true do
      {%{raw: schema, source_id: base_uri}, {%{}, %{}}}
    else
      {nil, %{}}
    end
  end

  # Store raw entries directly; callers requesting provenance get a parallel
  # registry updated at the same point, with the same duplicate precedence.
  defp put_scope(registry, id, schema, nil), do: Map.put(registry, id, schema)
  defp put_scope({registry, contexts}, id, schema, owner),
    do: {Map.put(registry, id, schema), Map.put(contexts, id, owner)}

  defp finish({registry, refs}) when is_map(registry), do: {registry, refs}
  defp finish({{registry, contexts}, refs}), do: {registry, refs, contexts}

  defp collect_refs(schema, refs) do
    refs = collect_ref(Map.get(schema, "$ref"), refs)
    collect_ref(Map.get(schema, "$dynamicRef"), refs)
  end

  defp collect_ref("#" <> _ = value, refs), do: MapSet.put(refs, value)
  defp collect_ref(_value, refs), do: refs

  defp register_anchor(acc, schema, owner, keyword, base_uri) do
    case Map.get(schema, keyword) do
      anchor when is_binary(anchor) -> put_scope(acc, base_uri <> "#" <> anchor, schema, owner)
      _ -> acc
    end
  end
end

defmodule JSONSchex.Draft202012.ScopeScanner do
  @moduledoc false

  alias JSONSchex.{SchemaTraversal, URIUtil}

  def scan(schema), do: do_scan(schema, nil, {%{}, MapSet.new()})

  def scan_all(document, base_uri, _opts) do
    do_scan_all(document, base_uri, {%{}, MapSet.new()})
  end

  defp do_scan(schema, base_uri, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    registry =
      if current_id do
        Map.put(registry, new_base_uri, schema)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(schema, "$anchor", new_base_uri)
      |> register_anchor(schema, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    SchemaTraversal.reduce_scope_subschemas(schema, {registry, refs}, fn subschema, acc ->
      do_scan(subschema, new_base_uri, acc)
    end)
  end

  defp do_scan(_value, _base_uri, acc), do: acc

  defp do_scan_all(schema, base_uri, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = if is_binary(current_id), do: URIUtil.resolve(base_uri, current_id), else: base_uri
    new_base_uri = new_base_uri || ""

    registry =
      if is_binary(current_id) do
        Map.put(registry, new_base_uri, schema)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(schema, "$anchor", new_base_uri)
      |> register_anchor(schema, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    Enum.reduce(schema, {registry, refs}, fn {_key, value}, acc ->
      do_scan_all(value, new_base_uri, acc)
    end)
  end

  defp do_scan_all(list, base_uri, acc) when is_list(list) do
    Enum.reduce(list, acc, fn item, inner_acc -> do_scan_all(item, base_uri, inner_acc) end)
  end

  defp do_scan_all(_value, _base_uri, acc), do: acc

  defp collect_refs(schema, refs) do
    Enum.reduce(["$ref", "$dynamicRef"], refs, fn key, acc ->
      case Map.get(schema, key) do
        "#" <> _ = value -> MapSet.put(acc, value)
        _ -> acc
      end
    end)
  end

  defp register_anchor(acc, schema, keyword, base_uri) do
    case Map.get(schema, keyword) do
      anchor when is_binary(anchor) -> Map.put(acc, base_uri <> "#" <> anchor, schema)
      _ -> acc
    end
  end
end

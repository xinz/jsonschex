defmodule JSONSchex.ScopeScanner do
  @moduledoc """
  Scans a raw schema tree to discover all `$id`, `$anchor`, and `$dynamicAnchor`
  definitions, resolving them against parent base URIs to build a registry of
  absolute URI → raw schema mappings.

  The resulting registry is used by `JSONSchex.Compiler` to populate the `defs`
  field in the compiled `Schema`, enabling reference resolution during validation.

  ## Examples

      iex> schema = %{
      ...>   "$id" => "https://example.com/schema",
      ...>   "$defs" => %{
      ...>     "user" => %{"$id" => "user", "type" => "object"}
      ...>   }
      ...> }
      iex> registry = JSONSchex.ScopeScanner.scan(schema)
      iex> Map.has_key?(registry, "https://example.com/schema")
      true
      iex> Map.has_key?(registry, "https://example.com/user")
      true

  """

  alias JSONSchex.{SchemaTraversal, URIUtil}

  @doc """
  Scans a raw schema and returns a tuple `{registry, refs}` where:
  - `registry` is a map of `{absolute_uri => raw_schema}`.
  - `refs` is a MapSet of explicitly defined references.
  """
  def scan(schema) do
    do_scan(schema, nil, {%{}, MapSet.new()})
  end

  @doc """
  Scans every map/list node in a containing document for JSON Schema resource
  identifiers and references.

  This is intentionally broader than `scan/1`: fragment compilation may receive
  an OpenAPI document whose schema objects live under arbitrary paths such as
  `components.schemas` or `paths.*.requestBody.content.*.schema`.
  """
  def scan_all(document, base_uri \\ nil) do
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

    refs =
      Enum.reduce(["$ref", "$dynamicRef"], refs, fn key, acc ->
        case Map.get(schema, key) do
          "#" <> _ = value ->
            MapSet.put(acc, value)
          _ ->
            acc
        end
      end)

    schema
    |> SchemaTraversal.scope_subschemas()
    |> Enum.reduce({registry, refs}, fn subschema, acc -> do_scan(subschema, new_base_uri, acc) end)
  end

  defp do_scan(_, _, acc), do: acc

  defp do_scan_all(schema, base_uri, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

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
        "#" <> _ = value ->
          MapSet.put(acc, value)

        _ ->
          acc
      end
    end)
  end

  defp register_anchor(acc, schema, keyword, base_uri) do
    case Map.get(schema, keyword) do
      anchor when is_binary(anchor) ->
        Map.put(acc, base_uri <> "#" <> anchor, schema)
      _ ->
        acc
    end

  end

end

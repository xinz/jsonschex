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

  @draft7_ignored_scope_keywords ~w(
    $defs $anchor $dynamicAnchor $dynamicRef $vocabulary
    prefixItems dependentSchemas dependentRequired
    contentSchema unevaluatedItems unevaluatedProperties minContains maxContains deprecated
  )

  @doc """
  Scans a raw schema and returns a tuple `{registry, refs}` where:
  - `registry` is a map of `{absolute_uri => raw_schema}`.
  - `refs` is a MapSet of explicitly defined references.

  The `:draft` option defaults to `"draft2020_12"`. Use `"draft7"` to ignore
  `$ref` siblings and newer-draft annotations and scan tuple `additionalItems`.
  """
  def scan(schema, opts \\ []) do
    do_scan(schema, nil, {%{}, MapSet.new()}, Keyword.get(opts, :draft, "draft2020_12"))
  end

  @doc """
  Scans every map/list node in a containing document for JSON Schema resource
  identifiers and references.

  This is intentionally broader than `scan/1`: fragment compilation may receive
  an OpenAPI document whose schema objects live under arbitrary paths such as
  `components.schemas` or `paths.*.requestBody.content.*.schema`.
  The `:draft` option controls Draft 7 `$ref` sibling and newer-keyword handling.
  """
  def scan_all(document, base_uri \\ nil, opts \\ []) do
    do_scan_all(document, base_uri, {%{}, MapSet.new()}, Keyword.get(opts, :draft, "draft2020_12"))
  end

  defp do_scan(schema, base_uri, {registry, refs}, draft) when is_map(schema) do
    raw_schema = schema
    schema = scope_schema(schema, draft)
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    registry =
      if current_id do
        Map.put(registry, new_base_uri, raw_schema)
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

    SchemaTraversal.reduce_scope_subschemas(schema, {registry, refs}, fn subschema, acc ->
      do_scan(subschema, new_base_uri, acc, draft)
    end, draft)
  end

  defp do_scan(_, _, acc, _draft), do: acc

  defp do_scan_all(schema, base_uri, {registry, refs}, draft) when is_map(schema) do
    raw_schema = schema
    schema = scope_schema(schema, draft)
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    registry =
      if is_binary(current_id) do
        Map.put(registry, new_base_uri, raw_schema)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(schema, "$anchor", new_base_uri)
      |> register_anchor(schema, "$dynamicAnchor", new_base_uri)

    refs = collect_refs(schema, refs)

    Enum.reduce(schema, {registry, refs}, fn {key, value}, acc ->
      scan_document_child(key, value, new_base_uri, acc, draft)
    end)
  end

  defp do_scan_all(list, base_uri, acc, draft) when is_list(list) do
    Enum.reduce(list, acc, fn item, inner_acc -> do_scan_all(item, base_uri, inner_acc, draft) end)
  end

  defp do_scan_all(_value, _base_uri, acc, _draft), do: acc

  defp scan_document_child(key, schemas, base_uri, acc, "draft7")
       when key in ["properties", "patternProperties", "definitions", "dependencies", "schemas"] and is_map(schemas) do
    # Container keys name properties, definitions, or components, not schema keywords.
    Enum.reduce(schemas, acc, fn {_name, schema}, inner_acc ->
      do_scan_all(schema, base_uri, inner_acc, "draft7")
    end)
  end

  defp scan_document_child(_key, value, base_uri, acc, draft),
    do: do_scan_all(value, base_uri, acc, draft)

  # Filter discovery only; registry entries retain raw content for explicit pointers.
  defp scope_schema(%{"$ref" => _} = schema, "draft7"), do: Map.take(schema, ["$ref"])
  defp scope_schema(schema, "draft7") do
    schema = Map.drop(schema, @draft7_ignored_scope_keywords)

    if is_list(Map.get(schema, "items")), do: schema, else: Map.delete(schema, "additionalItems")
  end
  defp scope_schema(schema, _draft), do: schema

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

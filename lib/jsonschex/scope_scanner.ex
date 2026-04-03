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

  alias JSONSchex.URIUtil

  @doc """
  Scans a raw schema and returns a tuple `{registry, refs}` where:
  - `registry` is a map of `{absolute_uri => raw_schema}`.
  - `refs` is a MapSet of explicitly defined references.
  """
  def scan(schema) do
    do_scan(schema, nil, {%{}, MapSet.new()})
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

    Enum.reduce(schema, {registry, refs}, fn {key, value}, acc ->
      recurse_keyword(key, value, new_base_uri, acc)
    end)
  end

  defp do_scan(_, _, acc), do: acc

  defp register_anchor(acc, schema, keyword, base_uri) do
    case Map.get(schema, keyword) do
      anchor when is_binary(anchor) ->
        Map.put(acc, base_uri <> "#" <> anchor, schema)
      _ ->
        acc
    end

  end

  defp recurse_keyword(key, map, base, acc) when key in ["properties", "$defs", "definitions", "patternProperties", "dependentSchemas"] and is_map(map) do
    Enum.reduce(map, acc, fn {_k, sub}, inner_acc -> do_scan(sub, base, inner_acc) end)
  end

  defp recurse_keyword(key, list, base, acc) when key in ["allOf", "anyOf", "oneOf", "prefixItems"] and is_list(list) do
    Enum.reduce(list, acc, fn sub, inner_acc -> do_scan(sub, base, inner_acc) end)
  end

  defp recurse_keyword(key, sub, base, acc) when key in ["items", "additionalProperties", "if", "then", "else", "not", "contains", "propertyNames", "unevaluatedItems", "unevaluatedProperties"] and is_map(sub) do
    do_scan(sub, base, acc)
  end

  defp recurse_keyword(_, _, _, acc), do: acc
end

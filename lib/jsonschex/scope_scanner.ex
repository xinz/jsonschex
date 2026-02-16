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
  Scans a raw schema and returns a registry map of `{absolute_uri => raw_schema}`.

  ## Examples

      iex> schema = %{"$id" => "https://example.com/root", "$anchor" => "root"}
      iex> registry = JSONSchex.ScopeScanner.scan(schema)
      iex> Map.keys(registry)
      ["https://example.com/root", "https://example.com/root#root"]

  """
  def scan(schema) do
    do_scan(schema, nil, %{})
  end

  defp do_scan(schema, base_uri, acc) when is_map(schema) do
    current_id = Map.get(schema, "$id")

    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    acc =
      if current_id do
        Map.put(acc, new_base_uri, schema)
      else
        acc
      end

    acc =
      acc
      |> register_anchor(schema, "$anchor", new_base_uri)
      |> register_anchor(schema, "$dynamicAnchor", new_base_uri)

    Enum.reduce(schema, acc, fn {key, value}, a ->
      recurse_keyword(key, value, new_base_uri, a)
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
    Enum.reduce(map, acc, fn {_k, sub}, a -> do_scan(sub, base, a) end)
  end

  defp recurse_keyword(key, list, base, acc) when key in ["allOf", "anyOf", "oneOf", "prefixItems"] and is_list(list) do
    Enum.reduce(list, acc, fn sub, a -> do_scan(sub, base, a) end)
  end

  defp recurse_keyword(key, sub, base, acc) when key in ["items", "additionalProperties", "if", "then", "else", "not", "contains", "propertyNames", "unevaluatedItems", "unevaluatedProperties"] and is_map(sub) do
    do_scan(sub, base, acc)
  end

  defp recurse_keyword(_, _, _, acc), do: acc
end

defmodule JSONSchex.Compiler.Cache do
  @moduledoc false

  alias JSONSchex.Types.{Rule, Schema}
  alias JSONSchex.URIUtil

  # This immutable cache belongs to one compilation and contains only the initial tree,
  # whose nodes share the root vocabulary, loader and assertion options. Index
  # identities, not raw schema maps: hashing descendant trees would itself turn
  # nested-resource compilation into quadratic work.
  def build(%Schema{} = schema), do: index_schema(schema, %{})

  def fetch_scope(cache, id, raw, base) do
    case Map.get(cache, id) do
      %Schema{source_id: ^base, raw: candidate_raw} = candidate when candidate_raw === raw ->
        if keyword_order_preserved?(raw), do: {:ok, candidate}, else: nil

      _ ->
        nil
    end
  end

  # Scope compilation deletes $id before enumerating keywords. A map changing
  # representation can reorder the remaining keys and hence ordered diagnostics.
  defp keyword_order_preserved?(raw) do
    keywords = Map.drop(raw, ["unevaluatedProperties", "unevaluatedItems"])
    Enum.reject(Map.keys(keywords), &(&1 == "$id")) == Map.keys(Map.delete(keywords, "$id"))
  end

  defp index_schema(%Schema{raw: raw} = schema, index) when is_map(raw) do
    index =
      if is_binary(Map.get(raw, "$id")) and is_binary(schema.source_id) do
        Map.put_new(index, schema.source_id, schema)
      else
        index
      end

    index = Enum.reduce(["$anchor", "$dynamicAnchor"], index, fn keyword, acc ->
      case Map.get(raw, keyword) do
        anchor when is_binary(anchor) ->
          Map.put_new(acc, URIUtil.with_fragment(schema.source_id || "", anchor), schema)
        _ ->
          acc
      end
    end)

    index = Enum.reduce(schema.defs, index, fn {_key, child}, acc -> index_schema(child, acc) end)
    Enum.reduce(schema.rules, index, &index_rule/2)
  end

  defp index_schema(_schema, index), do: index

  # Visit only compiler-owned schema slots, never arbitrary enum/const data or
  # raw documents. Unrecognized future rule shapes safely miss reuse.
  defp index_rule(%Rule{name: name, params: pairs}, index)
       when name in [:properties, :patternProperties, :dependentSchemas] do
    Enum.reduce(pairs, index, fn {_key, child}, acc -> index_schema(child, acc) end)
  end

  defp index_rule(%Rule{name: name, params: schemas}, index)
       when name in [:allOf, :anyOf, :oneOf, :prefixItems] do
    Enum.reduce(schemas, index, &index_schema/2)
  end

  defp index_rule(%Rule{name: name, params: schema}, index)
       when name in [:not, :propertyNames], do: index_schema(schema, index)

  defp index_rule(%Rule{name: name, params: %{schema: schema}}, index)
       when name in [:contentSchema, :additionalProperties, :items, :contains,
                     :unevaluatedProperties, :unevaluatedItems], do: index_schema(schema, index)

  defp index_rule(%Rule{name: :if, params: branches}, index) do
    Enum.reduce([:if, :then, :else], index, fn branch, acc ->
      index_schema(Map.get(branches, branch), acc)
    end)
  end

  defp index_rule(%Rule{name: :dependencies, params: %{schemas: schemas}}, index) do
    Enum.reduce(schemas, index, fn {_key, child}, acc -> index_schema(child, acc) end)
  end

  defp index_rule(_rule, index), do: index
end

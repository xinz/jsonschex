defmodule JSONSchex.SchemaTraversal do
  @moduledoc false

  @single_schema_keywords [
    "additionalProperties",
    "contains",
    "contentSchema",
    "items",
    "not",
    "propertyNames",
    "unevaluatedItems",
    "unevaluatedProperties"
  ]
  @schema_map_keywords ["dependentSchemas", "patternProperties", "properties"]
  @schema_list_keywords ["allOf", "anyOf", "oneOf", "prefixItems"]
  @definition_keywords ["$defs", "definitions"]
  @conditional_keywords ["if", "then", "else"]

  @doc false
  def active_subschemas(schema) when is_map(schema) do
    single_subschemas = schemas_at_keys(schema, @single_schema_keywords)
    map_subschemas = schema_map_subschemas(schema, @schema_map_keywords)
    list_subschemas = schema_list_subschemas(schema, @schema_list_keywords)

    conditional_subschemas =
      if schema?(Map.get(schema, "if")) do
        schemas_at_keys(schema, @conditional_keywords)
      else
        []
      end

    dependency_subschemas = schema |> Map.get("dependencies", %{}) |> schema_map_values()

    Enum.concat([
      conditional_subschemas,
      list_subschemas,
      map_subschemas,
      single_subschemas,
      dependency_subschemas
    ])
  end

  def active_subschemas(_schema), do: []

  @doc false
  def metadata_subschemas(schema), do: scope_subschemas(schema)

  @doc false
  def scope_subschemas(schema) do
    schema
    |> reduce_scope_subschemas([], fn subschema, acc -> [subschema | acc] end)
    |> Enum.reverse()
  end

  @doc false
  def reduce_scope_subschemas(schema, acc, reducer) when is_map(schema) do
    acc = reduce_schema_lists(schema, @schema_list_keywords, acc, reducer)
    acc = reduce_schema_maps(schema, @schema_map_keywords ++ @definition_keywords, acc, reducer)
    acc = reduce_schemas_at_keys(schema, @single_schema_keywords ++ @conditional_keywords, acc, reducer)
    acc = reduce_schema_map(Map.get(schema, "dependencies"), acc, reducer)

    case Map.get(schema, "items") do
      items when is_list(items) -> reduce_schema_list(items, acc, reducer)
      _ -> acc
    end
  end

  def reduce_scope_subschemas(_schema, acc, _reducer), do: acc

  defp schemas_at_keys(schema, keywords) do
    keywords
    |> Enum.map(&Map.get(schema, &1))
    |> Enum.filter(&schema?/1)
  end

  defp schema_map_subschemas(schema, keywords) do
    Enum.flat_map(keywords, fn keyword ->
      schema
      |> Map.get(keyword, %{})
      |> schema_map_values()
    end)
  end

  defp schema_list_subschemas(schema, keywords) do
    Enum.flat_map(keywords, fn keyword ->
      schema
      |> Map.get(keyword, [])
      |> schema_list_values()
    end)
  end

  defp reduce_schema_lists(schema, keywords, acc, reducer) do
    Enum.reduce(keywords, acc, fn keyword, inner_acc ->
      reduce_schema_list(Map.get(schema, keyword), inner_acc, reducer)
    end)
  end

  defp reduce_schema_maps(schema, keywords, acc, reducer) do
    Enum.reduce(keywords, acc, fn keyword, inner_acc ->
      reduce_schema_map(Map.get(schema, keyword), inner_acc, reducer)
    end)
  end

  defp reduce_schemas_at_keys(schema, keywords, acc, reducer) do
    Enum.reduce(keywords, acc, fn keyword, inner_acc ->
      reduce_schema(Map.get(schema, keyword), inner_acc, reducer)
    end)
  end

  defp reduce_schema_map(value, acc, reducer) when is_map(value) do
    value
    |> Map.values()
    |> Enum.reduce(acc, fn subschema, inner_acc ->
      reduce_schema(subschema, inner_acc, reducer)
    end)
  end

  defp reduce_schema_map(_value, acc, _reducer), do: acc

  defp reduce_schema_list(value, acc, reducer) when is_list(value) do
    Enum.reduce(value, acc, fn subschema, inner_acc ->
      reduce_schema(subschema, inner_acc, reducer)
    end)
  end

  defp reduce_schema_list(_value, acc, _reducer), do: acc

  defp reduce_schema(subschema, acc, reducer) when is_map(subschema) or is_boolean(subschema),
    do: reducer.(subschema, acc)

  defp reduce_schema(_value, acc, _reducer), do: acc

  defp schema_map_values(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.filter(&schema?/1)
  end

  defp schema_map_values(_value), do: []

  defp schema_list_values(value) when is_list(value), do: Enum.filter(value, &schema?/1)
  defp schema_list_values(_value), do: []

  defp schema?(value), do: is_map(value) or is_boolean(value)
end

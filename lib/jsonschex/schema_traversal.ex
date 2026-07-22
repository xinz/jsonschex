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
  def scope_subschemas(schema) when is_map(schema) do
    single_subschemas = schemas_at_keys(schema, @single_schema_keywords ++ @conditional_keywords)
    map_subschemas = schema_map_subschemas(schema, @schema_map_keywords ++ @definition_keywords)
    list_subschemas = schema_list_subschemas(schema, @schema_list_keywords)
    dependency_subschemas = schema |> Map.get("dependencies", %{}) |> schema_map_values()

    legacy_items =
      case Map.get(schema, "items") do
        items when is_list(items) -> schema_list_values(items)
        _ -> []
      end

    Enum.concat([
      list_subschemas,
      map_subschemas,
      single_subschemas,
      dependency_subschemas,
      legacy_items
    ])
  end

  def scope_subschemas(_schema), do: []

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

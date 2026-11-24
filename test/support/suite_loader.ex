defmodule JSONSchex.Test.SuiteLoader do
  @moduledoc """
  Routes URI requests to either per-test-case `externalSchemas` or the local
  'priv' directory (for official meta-schemas).
  """

  # Path to our local copy of official schemas
  @priv_schemas "priv/schemas"
  alias JSONSchex.JSON

  def loader(external_schemas, opts \\ [])

  def loader(external_schemas, opts) when is_map(external_schemas) and map_size(external_schemas) > 0 do
    default_schema_uri = Keyword.get(opts, :default_schema_uri)

    fn uri ->
      case Map.fetch(external_schemas, uri) do
        {:ok, schema} ->
          {:ok, maybe_put_default_schema(schema, default_schema_uri)}

        :error ->
          load(uri)
      end
    end
  end

  def loader(_external_schemas, _opts), do: &load/1

  def load(uri) do
    cond do
      # Official Meta-Schemas -> Route to priv/schemas
      String.starts_with?(uri, "https://json-schema.org/") or
          String.starts_with?(uri, "http://json-schema.org/draft-07/") ->
        load_meta_schema(uri)

      # Remote loading is not actually required in the test suite `id.json` / `id-legacy.json`
      # This serves as an example
      String.starts_with?(uri, "http://example.com/schema-relative-uri-defs") ->
        :halt

      # Same case in `id.json` / `id-legacy.json`
      String.starts_with?(uri, "http://example.com/schema-refs-absolute-uris-defs") ->
        :halt

      true ->
        {:error, "Unknown remote URI scheme: #{uri}"}
    end
  end

  defp maybe_put_default_schema(schema, default_schema_uri)
       when is_map(schema) and is_binary(default_schema_uri) do
    Map.put_new(schema, "$schema", default_schema_uri)
  end

  defp maybe_put_default_schema(schema, _default_schema_uri), do: schema

  defp load_meta_schema(uri) do
    # The official Draft 7 URI uses http and a trailing #; the fragment is not a file path.
    %{path: path} = URI.parse(uri)
    relative_path = String.trim_leading(path, "/")
    read_json(Path.join(@priv_schemas, relative_path <> ".json"))
  end

  defp read_json(path) do
    # Try exact path, then try adding .json if missing
    cond do
      File.exists?(path) ->
        {:ok, JSON.decode!(File.read!(path))}

      File.exists?(path <> ".json") ->
        {:ok, JSON.decode!(File.read!(path <> ".json"))}

      true ->
        {:error, :not_found}
    end
  end
end

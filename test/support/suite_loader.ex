defmodule JSONSchex.Test.SuiteLoader do
  @moduledoc """
  Routes URI requests to either the local 'priv' directory (for official meta-schemas)
  or the 'test/fixtures' directory (for test suite remotes).
  """

  # Path to our local copy of official schemas
  @priv_schemas "priv/schemas"
  @remotes "test/fixtures/JSON-Schema-Test-Suite/remotes"
  alias JSONSchex.JSON

  def load(uri) do
    cond do
      # Official Meta-Schemas -> Route to priv/schemas
      String.starts_with?(uri, "https://json-schema.org/") ->
        load_meta_schema(uri)

      String.starts_with?(uri, "http://localhost:1234/") ->
        load_remotes(uri)

      # Remote loading is not actually required in the test suite `ref.json`
      # This serves as an example
      String.starts_with?(uri, "http://example.com/schema-relative-uri-defs") ->
        :halt

      # Same case to `ref.json`
      String.starts_with?(uri, "http://example.com/schema-refs-absolute-uris-defs") ->
        :halt

      true ->
        {:error, "Unknown remote URI scheme: #{uri}"}
    end
  end

  defp load_meta_schema(uri) do
    # Map: https://json-schema.org/draft/2020-12/schema
    # To:  priv/schemas/draft/2020-12/schema.json

    relative_path = String.replace(uri, "https://json-schema.org/", "")

    # If it ends in a directory-like name (no extension), assume .json
    # or specifically handle the root "schema" resource.
    path_with_ext = relative_path <> ".json"

    full_path = Path.join(@priv_schemas, path_with_ext)
    read_json(full_path)
  end

  defp load_remotes(uri) do
    # Map: http://localhost:1234/draft2020-12/
    # To:  test/fixtures/JSON-Schema-Test-Suite/remotes/draft2020-12/schema.json

    %{path: relative_path} = URI.parse(uri)
    full_path = Path.join(@remotes, relative_path)
    read_json(full_path)
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

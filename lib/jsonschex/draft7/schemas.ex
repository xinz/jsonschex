defmodule JSONSchex.Draft7.Schemas do
  @moduledoc """
  Provides the canonical Draft 7 meta-schema and its compiled reference registry.

  The canonical meta-schema is embedded as an Elixir map, so resolving built-in
  references does not read files or decode JSON at runtime.
  """

  alias JSONSchex.Compiler
  alias JSONSchex.Draft7.Dialect
  @base_uri Dialect.base_uri()
  @schema_uri Dialect.schema_uri()
  @compiled_defs_cache_key {__MODULE__, :compiled_defs}

  @schema %{
    "$schema" => @schema_uri,
    "$id" => @schema_uri,
    "title" => "Core schema meta-schema",
    "definitions" => %{
      "schemaArray" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{"$ref" => "#"}
      },
      "nonNegativeInteger" => %{"type" => "integer", "minimum" => 0},
      "nonNegativeIntegerDefault0" => %{
        "allOf" => [
          %{"$ref" => "#/definitions/nonNegativeInteger"},
          %{"default" => 0}
        ]
      },
      "simpleTypes" => %{
        "enum" => ["array", "boolean", "integer", "null", "number", "object", "string"]
      },
      "stringArray" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "uniqueItems" => true,
        "default" => []
      }
    },
    "type" => ["object", "boolean"],
    "properties" => %{
      "$id" => %{"type" => "string", "format" => "uri-reference"},
      "$schema" => %{"type" => "string", "format" => "uri"},
      "$ref" => %{"type" => "string", "format" => "uri-reference"},
      "$comment" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "default" => true,
      "readOnly" => %{"type" => "boolean", "default" => false},
      "writeOnly" => %{"type" => "boolean", "default" => false},
      "examples" => %{"type" => "array", "items" => true},
      "multipleOf" => %{"type" => "number", "exclusiveMinimum" => 0},
      "maximum" => %{"type" => "number"},
      "exclusiveMaximum" => %{"type" => "number"},
      "minimum" => %{"type" => "number"},
      "exclusiveMinimum" => %{"type" => "number"},
      "maxLength" => %{"$ref" => "#/definitions/nonNegativeInteger"},
      "minLength" => %{"$ref" => "#/definitions/nonNegativeIntegerDefault0"},
      "pattern" => %{"type" => "string", "format" => "regex"},
      "additionalItems" => %{"$ref" => "#"},
      "items" => %{
        "anyOf" => [
          %{"$ref" => "#"},
          %{"$ref" => "#/definitions/schemaArray"}
        ],
        "default" => true
      },
      "maxItems" => %{"$ref" => "#/definitions/nonNegativeInteger"},
      "minItems" => %{"$ref" => "#/definitions/nonNegativeIntegerDefault0"},
      "uniqueItems" => %{"type" => "boolean", "default" => false},
      "contains" => %{"$ref" => "#"},
      "maxProperties" => %{"$ref" => "#/definitions/nonNegativeInteger"},
      "minProperties" => %{"$ref" => "#/definitions/nonNegativeIntegerDefault0"},
      "required" => %{"$ref" => "#/definitions/stringArray"},
      "additionalProperties" => %{"$ref" => "#"},
      "definitions" => %{
        "type" => "object",
        "additionalProperties" => %{"$ref" => "#"},
        "default" => %{}
      },
      "properties" => %{
        "type" => "object",
        "additionalProperties" => %{"$ref" => "#"},
        "default" => %{}
      },
      "patternProperties" => %{
        "type" => "object",
        "additionalProperties" => %{"$ref" => "#"},
        "propertyNames" => %{"format" => "regex"},
        "default" => %{}
      },
      "dependencies" => %{
        "type" => "object",
        "additionalProperties" => %{
          "anyOf" => [
            %{"$ref" => "#"},
            %{"$ref" => "#/definitions/stringArray"}
          ]
        }
      },
      "propertyNames" => %{"$ref" => "#"},
      "const" => true,
      "enum" => %{
        "type" => "array",
        "items" => true,
        "minItems" => 1,
        "uniqueItems" => true
      },
      "type" => %{
        "anyOf" => [
          %{"$ref" => "#/definitions/simpleTypes"},
          %{
            "type" => "array",
            "items" => %{"$ref" => "#/definitions/simpleTypes"},
            "minItems" => 1,
            "uniqueItems" => true
          }
        ]
      },
      "format" => %{"type" => "string"},
      "contentMediaType" => %{"type" => "string"},
      "contentEncoding" => %{"type" => "string"},
      "if" => %{"$ref" => "#"},
      "then" => %{"$ref" => "#"},
      "else" => %{"$ref" => "#"},
      "allOf" => %{"$ref" => "#/definitions/schemaArray"},
      "anyOf" => %{"$ref" => "#/definitions/schemaArray"},
      "oneOf" => %{"$ref" => "#/definitions/schemaArray"},
      "not" => %{"$ref" => "#"}
    },
    "default" => true
  }

  @doc "Returns the bundled Draft 7 meta-schema for its canonical URI."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(uri) when uri in [@base_uri, @schema_uri], do: {:ok, @schema}

  def fetch(_uri), do: :error

  @doc """
  Returns compiled resources for a Draft 7 meta-schema reference.

  The `:format_assertion` and `:content_assertion` options default to `false`.
  Both canonical URI forms share the same cache for each boolean option pair.
  """
  def compiled_defs(uri, opts \\ [])

  def compiled_defs(uri, opts) when uri in [@base_uri, @schema_uri] do
    format_assertion = !!Keyword.get(opts, :format_assertion, false)
    content_assertion = !!Keyword.get(opts, :content_assertion, false)
    cache_key = compiled_defs_cache_key(format_assertion, content_assertion)

    case :persistent_term.get(cache_key, :undefined) do
      :undefined ->
        compiled = build_compiled_defs(format_assertion, content_assertion)
        :persistent_term.put(cache_key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  def compiled_defs(_uri, _opts), do: nil

  # Keep the default registry compatible with cache entries created by compiled_defs/1.
  defp compiled_defs_cache_key(false, false), do: @compiled_defs_cache_key

  defp compiled_defs_cache_key(format_assertion, content_assertion) do
    {__MODULE__, :compiled_defs, format_assertion, content_assertion}
  end

  defp build_compiled_defs(format_assertion, content_assertion) do
    {:ok, raw_schema} = fetch(@schema_uri)

    {:ok, compiled_schema} =
      Compiler.compile(raw_schema,
        draft: "draft7",
        base_uri: @base_uri,
        format_assertion: format_assertion,
        content_assertion: content_assertion
      )

    compiled_schema.defs
    |> Map.put(@base_uri, compiled_schema)
    |> Map.put(@schema_uri, compiled_schema)
  end
end

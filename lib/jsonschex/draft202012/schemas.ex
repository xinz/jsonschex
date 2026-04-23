defmodule JSONSchex.Draft202012.Schemas do
  @moduledoc """
  Provides built-in JSON Schema resources bundled directly in the module.

  This module embeds the canonical Draft 2020-12 meta-schema family as Elixir
  maps, avoiding runtime file reads and JSON decoding. It also exposes a
  compiled defs registry so built-in `$ref` and `$dynamicRef` targets can
  participate in normal runtime resolution.

  The public API is intentionally small:

  - `fetch/1` returns `{:ok, schema_map}` or `:error`
  - `known_uri?/1` reports whether a URI is bundled
  - `compiled_defs/1` returns a compiled defs registry for the built-in family
  """

  alias JSONSchex.Compiler
  alias JSONSchex.ScopeScanner

  @compiled_defs_cache_key {__MODULE__, :draft2020_12_compiled_defs}

  @draft2020_12_base_uri "https://json-schema.org/draft/2020-12"
  @draft2020_12_schema_uri @draft2020_12_base_uri <> "/schema"

  @draft2020_12_meta_core_uri @draft2020_12_base_uri <> "/meta/core"
  @draft2020_12_meta_applicator_uri @draft2020_12_base_uri <> "/meta/applicator"
  @draft2020_12_meta_unevaluated_uri @draft2020_12_base_uri <> "/meta/unevaluated"
  @draft2020_12_meta_validation_uri @draft2020_12_base_uri <> "/meta/validation"
  @draft2020_12_meta_meta_data_uri @draft2020_12_base_uri <> "/meta/meta-data"
  @draft2020_12_meta_format_annotation_uri @draft2020_12_base_uri <> "/meta/format-annotation"
  @draft2020_12_meta_format_assertion_uri @draft2020_12_base_uri <> "/meta/format-assertion"
  @draft2020_12_meta_content_uri @draft2020_12_base_uri <> "/meta/content"

  @draft2020_12_schema %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_schema_uri,
    "$vocabulary" => %{
      "https://json-schema.org/draft/2020-12/vocab/core" => true,
      "https://json-schema.org/draft/2020-12/vocab/applicator" => true,
      "https://json-schema.org/draft/2020-12/vocab/unevaluated" => true,
      "https://json-schema.org/draft/2020-12/vocab/validation" => true,
      "https://json-schema.org/draft/2020-12/vocab/meta-data" => true,
      "https://json-schema.org/draft/2020-12/vocab/format-annotation" => true,
      "https://json-schema.org/draft/2020-12/vocab/content" => true
    },
    "$dynamicAnchor" => "meta",
    "title" => "Core and Validation specifications meta-schema",
    "allOf" => [
      %{"$ref" => "meta/core"},
      %{"$ref" => "meta/applicator"},
      %{"$ref" => "meta/unevaluated"},
      %{"$ref" => "meta/validation"},
      %{"$ref" => "meta/meta-data"},
      %{"$ref" => "meta/format-annotation"},
      %{"$ref" => "meta/content"}
    ],
    "type" => ["object", "boolean"],
    "$comment" =>
      "This meta-schema also defines keywords that have appeared in previous drafts in order to prevent incompatible extensions as they remain in common use.",
    "properties" => %{
      "definitions" => %{
        "$comment" => "\"definitions\" has been replaced by \"$defs\".",
        "type" => "object",
        "additionalProperties" => %{"$dynamicRef" => "#meta"},
        "deprecated" => true,
        "default" => %{}
      },
      "dependencies" => %{
        "$comment" =>
          "\"dependencies\" has been split and replaced by \"dependentSchemas\" and \"dependentRequired\" in order to serve their differing semantics.",
        "type" => "object",
        "additionalProperties" => %{
          "anyOf" => [
            %{"$dynamicRef" => "#meta"},
            %{"$ref" => "meta/validation#/$defs/stringArray"}
          ]
        },
        "deprecated" => true,
        "default" => %{}
      },
      "$recursiveAnchor" => %{
        "$comment" => "\"$recursiveAnchor\" has been replaced by \"$dynamicAnchor\".",
        "$ref" => "meta/core#/$defs/anchorString",
        "deprecated" => true
      },
      "$recursiveRef" => %{
        "$comment" => "\"$recursiveRef\" has been replaced by \"$dynamicRef\".",
        "$ref" => "meta/core#/$defs/uriReferenceString",
        "deprecated" => true
      }
    }
  }

  @draft2020_12_meta_core %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_core_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Core vocabulary meta-schema",
    "type" => ["object", "boolean"],
    "properties" => %{
      "$id" => %{
        "$ref" => "#/$defs/uriReferenceString",
        "$comment" => "Non-empty fragments not allowed.",
        "pattern" => "^[^#]*#?$"
      },
      "$schema" => %{"$ref" => "#/$defs/uriString"},
      "$ref" => %{"$ref" => "#/$defs/uriReferenceString"},
      "$anchor" => %{"$ref" => "#/$defs/anchorString"},
      "$dynamicRef" => %{"$ref" => "#/$defs/uriReferenceString"},
      "$dynamicAnchor" => %{"$ref" => "#/$defs/anchorString"},
      "$vocabulary" => %{
        "type" => "object",
        "propertyNames" => %{"$ref" => "#/$defs/uriString"},
        "additionalProperties" => %{"type" => "boolean"}
      },
      "$comment" => %{"type" => "string"},
      "$defs" => %{
        "type" => "object",
        "additionalProperties" => %{"$dynamicRef" => "#meta"}
      }
    },
    "$defs" => %{
      "anchorString" => %{
        "type" => "string",
        "pattern" => "^[A-Za-z_][-A-Za-z0-9._]*$"
      },
      "uriString" => %{
        "type" => "string",
        "format" => "uri"
      },
      "uriReferenceString" => %{
        "type" => "string",
        "format" => "uri-reference"
      }
    }
  }

  @draft2020_12_meta_applicator %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_applicator_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Applicator vocabulary meta-schema",
    "type" => ["object", "boolean"],
    "properties" => %{
      "prefixItems" => %{"$ref" => "#/$defs/schemaArray"},
      "items" => %{"$dynamicRef" => "#meta"},
      "contains" => %{"$dynamicRef" => "#meta"},
      "additionalProperties" => %{"$dynamicRef" => "#meta"},
      "properties" => %{
        "type" => "object",
        "additionalProperties" => %{"$dynamicRef" => "#meta"},
        "default" => %{}
      },
      "patternProperties" => %{
        "type" => "object",
        "additionalProperties" => %{"$dynamicRef" => "#meta"},
        "propertyNames" => %{"format" => "regex"},
        "default" => %{}
      },
      "dependentSchemas" => %{
        "type" => "object",
        "additionalProperties" => %{"$dynamicRef" => "#meta"},
        "default" => %{}
      },
      "propertyNames" => %{"$dynamicRef" => "#meta"},
      "if" => %{"$dynamicRef" => "#meta"},
      "then" => %{"$dynamicRef" => "#meta"},
      "else" => %{"$dynamicRef" => "#meta"},
      "allOf" => %{"$ref" => "#/$defs/schemaArray"},
      "anyOf" => %{"$ref" => "#/$defs/schemaArray"},
      "oneOf" => %{"$ref" => "#/$defs/schemaArray"},
      "not" => %{"$dynamicRef" => "#meta"}
    },
    "$defs" => %{
      "schemaArray" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{"$dynamicRef" => "#meta"}
      }
    }
  }

  @draft2020_12_meta_unevaluated %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_unevaluated_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Unevaluated applicator vocabulary meta-schema",
    "type" => ["object", "boolean"],
    "properties" => %{
      "unevaluatedItems" => %{"$dynamicRef" => "#meta"},
      "unevaluatedProperties" => %{"$dynamicRef" => "#meta"}
    }
  }

  @draft2020_12_meta_validation %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_validation_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Validation vocabulary meta-schema",
    "type" => ["object", "boolean"],
    "properties" => %{
      "type" => %{
        "anyOf" => [
          %{"$ref" => "#/$defs/simpleTypes"},
          %{
            "type" => "array",
            "items" => %{"$ref" => "#/$defs/simpleTypes"},
            "minItems" => 1,
            "uniqueItems" => true
          }
        ]
      },
      "const" => true,
      "enum" => %{"type" => "array", "items" => true},
      "multipleOf" => %{"type" => "number", "exclusiveMinimum" => 0},
      "maximum" => %{"type" => "number"},
      "exclusiveMaximum" => %{"type" => "number"},
      "minimum" => %{"type" => "number"},
      "exclusiveMinimum" => %{"type" => "number"},
      "maxLength" => %{"$ref" => "#/$defs/nonNegativeInteger"},
      "minLength" => %{"$ref" => "#/$defs/nonNegativeIntegerDefault0"},
      "pattern" => %{"type" => "string", "format" => "regex"},
      "maxItems" => %{"$ref" => "#/$defs/nonNegativeInteger"},
      "minItems" => %{"$ref" => "#/$defs/nonNegativeIntegerDefault0"},
      "uniqueItems" => %{"type" => "boolean", "default" => false},
      "maxContains" => %{"$ref" => "#/$defs/nonNegativeInteger"},
      "minContains" => %{"$ref" => "#/$defs/nonNegativeInteger", "default" => 1},
      "maxProperties" => %{"$ref" => "#/$defs/nonNegativeInteger"},
      "minProperties" => %{"$ref" => "#/$defs/nonNegativeIntegerDefault0"},
      "required" => %{"$ref" => "#/$defs/stringArray"},
      "dependentRequired" => %{
        "type" => "object",
        "additionalProperties" => %{"$ref" => "#/$defs/stringArray"}
      }
    },
    "$defs" => %{
      "nonNegativeInteger" => %{"type" => "integer", "minimum" => 0},
      "nonNegativeIntegerDefault0" => %{
        "$ref" => "#/$defs/nonNegativeInteger",
        "default" => 0
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
    }
  }

  @draft2020_12_meta_meta_data %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_meta_data_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Meta-data vocabulary meta-schema",
    "type" => ["object", "boolean"],
    "properties" => %{
      "title" => %{"type" => "string"},
      "description" => %{"type" => "string"},
      "default" => true,
      "deprecated" => %{"type" => "boolean", "default" => false},
      "readOnly" => %{"type" => "boolean", "default" => false},
      "writeOnly" => %{"type" => "boolean", "default" => false},
      "examples" => %{"type" => "array", "items" => true}
    }
  }

  @draft2020_12_meta_format_annotation %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_format_annotation_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Format vocabulary meta-schema for annotation results",
    "type" => ["object", "boolean"],
    "properties" => %{
      "format" => %{"type" => "string"}
    }
  }

  @draft2020_12_meta_format_assertion %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_format_assertion_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Format vocabulary meta-schema for assertion results",
    "type" => ["object", "boolean"],
    "properties" => %{
      "format" => %{"type" => "string"}
    }
  }

  @draft2020_12_meta_content %{
    "$schema" => @draft2020_12_schema_uri,
    "$id" => @draft2020_12_meta_content_uri,
    "$dynamicAnchor" => "meta",
    "title" => "Content vocabulary meta-schema",
    "type" => ["object", "boolean"],
    "properties" => %{
      "contentEncoding" => %{"type" => "string"},
      "contentMediaType" => %{"type" => "string"},
      "contentSchema" => %{"$dynamicRef" => "#meta"}
    }
  }

  @schemas %{
    @draft2020_12_schema_uri => @draft2020_12_schema,
    @draft2020_12_meta_core_uri => @draft2020_12_meta_core,
    @draft2020_12_meta_applicator_uri => @draft2020_12_meta_applicator,
    @draft2020_12_meta_unevaluated_uri => @draft2020_12_meta_unevaluated,
    @draft2020_12_meta_validation_uri => @draft2020_12_meta_validation,
    @draft2020_12_meta_meta_data_uri => @draft2020_12_meta_meta_data,
    @draft2020_12_meta_format_annotation_uri => @draft2020_12_meta_format_annotation,
    @draft2020_12_meta_format_assertion_uri => @draft2020_12_meta_format_assertion,
    @draft2020_12_meta_content_uri => @draft2020_12_meta_content
  }

  @draft2020_12_family_uris Map.keys(@schemas)

  @doc """
  Returns `true` if the given URI is bundled with the library.

  ## Examples

      iex> JSONSchex.Draft202012.Schemas.known_uri?("https://json-schema.org/draft/2020-12/schema")
      true

      iex> JSONSchex.Draft202012.Schemas.known_uri?("https://example.com/custom")
      false
  """
  @spec known_uri?(String.t()) :: boolean()
  def known_uri?(uri) when is_binary(uri), do: Map.has_key?(@schemas, uri)
  def known_uri?(_), do: false

  @doc """
  Fetches a bundled schema by canonical URI.

  Returns `{:ok, map}` when the URI is known, otherwise returns `:error`.

  ## Examples

      iex> {:ok, schema} = JSONSchex.Draft202012.Schemas.fetch("https://json-schema.org/draft/2020-12/schema")
      iex> is_map(schema)
      true

      iex> JSONSchex.Draft202012.Schemas.fetch("https://example.com/custom")
      :error
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(uri) when is_binary(uri) do
    case Map.get(@schemas, uri) do
      nil -> :error
      schema -> {:ok, schema}
    end
  end

  def fetch(_), do: :error

  @doc """
  Returns the compiled defs registry for the built-in schema family containing
  the given URI.

  The returned map includes:
  - each built-in resource under its canonical absolute URI
  - all compiled defs discovered within each resource
  - all `$anchor` and `$dynamicAnchor` absolute entries discovered by scanning
    the raw built-in resources

  This allows built-in schemas to behave like a normal compiled defs registry
  during `$ref` and `$dynamicRef` resolution.
  """
  @spec compiled_defs(String.t()) :: map() | nil
  def compiled_defs(uri) when is_binary(uri) do
    case family_uris_for(uri) do
      [] ->
        nil

      _family_uris ->
        cached_compiled_defs()
    end
  end

  def compiled_defs(_), do: nil

  defp family_uris_for(uri) when uri in @draft2020_12_family_uris, do: @draft2020_12_family_uris
  defp family_uris_for(_), do: []

  defp cached_compiled_defs() do
    case :persistent_term.get(@compiled_defs_cache_key, :undefined) do
      :undefined ->
        compiled_defs = build_compiled_defs()
        :persistent_term.put(@compiled_defs_cache_key, compiled_defs)
        compiled_defs

      compiled_defs ->
        compiled_defs
    end
  end

  defp build_compiled_defs() do
    Enum.reduce(@draft2020_12_family_uris, %{}, fn family_uri, acc ->
      {:ok, raw_schema} = fetch(family_uri)

      {:ok, compiled_schema} = Compiler.compile(raw_schema, base_uri: family_uri)
      {scanned_defs, _refs} = ScopeScanner.scan(raw_schema)

      acc
      |> Map.put(family_uri, compiled_schema)
      |> Map.merge(compiled_schema.defs || %{})
      |> merge_scanned_anchor_entries(scanned_defs, compiled_schema)
    end)
  end

  defp merge_scanned_anchor_entries(defs, scanned_defs, compiled_schema) do
    Enum.reduce(scanned_defs, defs, fn {scanned_uri, _raw_schema}, acc ->
      Map.put_new(acc, scanned_uri, compiled_schema)
    end)
  end
end

# Dialect and $vocabulary Guide

This guide explains how JSONSchex interprets `$schema` and `$vocabulary`, and how those settings influence validation and compilation.

## Overview

- `$schema` identifies the JSON Schema dialect in use (e.g., Draft 2020-12).
- `$vocabulary` lists the vocabularies enabled by the meta-schema.
- JSONSchex uses these signals to determine which keywords are allowed and how to interpret them.

## Dialect resolution

JSONSchex resolves dialect in this order:

1. If the root schema contains `$schema` and an `external_loader` is provided, JSONSchex attempts to load the meta-schema at that URI.
2. If the meta-schema loads successfully, JSONSchex reads `$vocabulary` from it to build the enabled vocabulary set.
3. If no loader is available or the meta-schema cannot be loaded, JSONSchex proceeds with the default vocabulary set.

## $vocabulary Semantics

The `$vocabulary` object maps vocabulary URIs to a boolean:

- `true` means the vocabulary is **required**. If JSONSchex does not support it, compilation fails.
- `false` means the vocabulary is **optional**. If unsupported, it is ignored.

This behavior matches the Draft 2020-12 specification.

## Default Vocabularies

When no meta-schema can be loaded, JSONSchex uses its default vocabulary list. This includes the following 8 vocabulary URIs for Draft 2020-12:

1. `https://json-schema.org/draft/2020-12/vocab/core`
2. `https://json-schema.org/draft/2020-12/vocab/applicator`
3. `https://json-schema.org/draft/2020-12/vocab/validation`
4. `https://json-schema.org/draft/2020-12/vocab/unevaluated`
5. `https://json-schema.org/draft/2020-12/vocab/format-annotation`
6. `https://json-schema.org/draft/2020-12/vocab/format-assertion`
7. `https://json-schema.org/draft/2020-12/vocab/content`
8. `https://json-schema.org/draft/2020-12/vocab/meta-data`

This default set provides reasonable behavior for local schemas without remote meta-schema access.

You can access these programmatically:

```elixir
iex> JSONSchex.Vocabulary.defaults()
[
  "https://json-schema.org/draft/2020-12/vocab/core",
  "https://json-schema.org/draft/2020-12/vocab/applicator",
  "https://json-schema.org/draft/2020-12/vocab/validation",
  "https://json-schema.org/draft/2020-12/vocab/unevaluated",
  "https://json-schema.org/draft/2020-12/vocab/format-annotation",
  "https://json-schema.org/draft/2020-12/vocab/format-assertion",
  "https://json-schema.org/draft/2020-12/vocab/content",
  "https://json-schema.org/draft/2020-12/vocab/meta-data"
]
```

## Common outcomes

- Missing required vocabulary: compilation fails with an unsupported vocabulary error.
- Optional vocabulary unsupported: compilation continues, but those keywords are ignored.
- No loader available: `$schema` is not resolved remotely; defaults are used.

## Examples

### Example 1: Schema with explicit vocabulary

Here's a schema with explicit `$schema` and `$vocabulary`:

```elixir
# This schema requires the core and validation vocabularies
meta_schema = %{
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "$vocabulary" => %{
    "https://json-schema.org/draft/2020-12/vocab/core" => true,
    "https://json-schema.org/draft/2020-12/vocab/validation" => true,
    "https://example.com/custom-vocab" => false  # Optional, will be ignored if unsupported
  }
}

# With supported vocabularies - compilation succeeds
{:ok, compiled} = JSONSchex.compile(meta_schema)

# If a required vocabulary is unsupported - compilation fails
unsupported_schema = %{
  "$vocabulary" => %{
    "https://example.com/unsupported" => true  # Required but not supported
  }
}
{:error, msg} = JSONSchex.compile(unsupported_schema)
# msg will indicate the unsupported vocabulary
```

### Example 2: Using a custom meta-schema

You can create a custom meta-schema that restricts or extends the available vocabularies. Here's an example that only allows core and validation vocabularies:

```elixir
# Define a restricted meta-schema
restricted_meta = %{
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "$id" => "https://myapp.example.com/restricted-meta",
  "$vocabulary" => %{
    "https://json-schema.org/draft/2020-12/vocab/core" => true,
    "https://json-schema.org/draft/2020-12/vocab/validation" => true,
    # All other vocabularies are not listed, so they're disabled
  }
}

# Loader that provides our custom meta-schema
loader = fn
  "https://myapp.example.com/restricted-meta" -> {:ok, restricted_meta}
  _other_uri -> {:error, "Schema not found"}
end

# Schema that uses the custom meta-schema
schema = %{
  "$schema" => "https://myapp.example.com/restricted-meta",
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"}
  },
  # This would be ignored because applicator vocabulary is not enabled
  "allOf" => [%{"minProperties" => 1}]
}

# Compile with the custom loader
{:ok, compiled} = JSONSchex.compile(schema, external_loader: loader)

# The schema compiles, but 'allOf' is ignored because the applicator
# vocabulary is not in the restricted meta-schema's vocabulary list
```

### Example 3: Format assertion through vocabulary

The format vocabulary has two modes:

```elixir
# Meta-schema with format as annotation only
annotation_meta = %{
  "$vocabulary" => %{
    "https://json-schema.org/draft/2020-12/vocab/core" => true,
    "https://json-schema.org/draft/2020-12/vocab/format-annotation" => true
  }
}

# Meta-schema with format as assertion
assertion_meta = %{
  "$vocabulary" => %{
    "https://json-schema.org/draft/2020-12/vocab/core" => true,
    "https://json-schema.org/draft/2020-12/vocab/format-assertion" => true
  }
}

# The compile-time option overrides the vocabulary setting
schema = %{"type" => "string", "format" => "email"}

# Annotation mode - format is not validated
{:ok, compiled1} = JSONSchex.compile(schema, format_assertion: false)
JSONSchex.validate(compiled1, "not-an-email")  # => :ok

# Assertion mode - format is validated
{:ok, compiled2} = JSONSchex.compile(schema, format_assertion: true)
JSONSchex.validate(compiled2, "not-an-email")  # => {:error, [...]}
```

## Practical guidance

- If you rely on a custom meta-schema or vocabulary, provide an `external_loader`.
- Use `$schema` to make the dialect explicit and predictable.
- Avoid mixing keywords from unsupported vocabularies unless you also ship a loader that resolves the meta-schema.

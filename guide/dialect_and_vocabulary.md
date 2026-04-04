# Dialect and $vocabulary Guide

This guide explains how JSONSchex interprets `$schema` and `$vocabulary`, and how those settings influence validation and compilation.

## Overview

- `$schema` identifies the JSON Schema dialect in use (e.g., Draft 2020-12).
- `$vocabulary` lists the vocabularies enabled by the meta-schema.
- JSONSchex uses these signals to determine which keywords are allowed and how to interpret them.

## Dialect resolution

JSONSchex resolves dialect in this order:

1. If the root schema declares the canonical Draft 2020-12 meta-schema URI (`https://json-schema.org/draft/2020-12/schema`), JSONSchex treats it as a built-in dialect and does not invoke the external loader for that URI.
2. For the built-in Draft 2020-12 dialect, JSONSchex uses the standard Draft 2020-12 active vocabulary defaults, while still honoring an explicit root-level `$vocabulary` declaration when present.
3. If the root schema contains another `$schema` URI and an `external_loader` is provided, JSONSchex attempts to load that meta-schema remotely.
4. If a custom meta-schema loads successfully, JSONSchex reads `$vocabulary` from it to build the enabled vocabulary set.
5. If no loader is available or the meta-schema cannot be loaded, JSONSchex proceeds with the implementation default capability set.

## $vocabulary Semantics

The `$vocabulary` object maps vocabulary URIs to a boolean:

- `true` means the vocabulary is **required**. If JSONSchex does not support it, compilation fails.
- `false` means the vocabulary is **optional**. If unsupported, it is ignored.

This behavior matches the Draft 2020-12 specification.

## Default vocabularies

JSONSchex now distinguishes between two related vocabulary sets:

### 1. Built-in Draft 2020-12 active defaults

When a schema uses the canonical Draft 2020-12 meta-schema URI, JSONSchex activates the built-in Draft 2020-12 vocabulary set:

1. `https://json-schema.org/draft/2020-12/vocab/core`
2. `https://json-schema.org/draft/2020-12/vocab/applicator`
3. `https://json-schema.org/draft/2020-12/vocab/validation`
4. `https://json-schema.org/draft/2020-12/vocab/unevaluated`
5. `https://json-schema.org/draft/2020-12/vocab/format-annotation`
6. `https://json-schema.org/draft/2020-12/vocab/content`
7. `https://json-schema.org/draft/2020-12/vocab/meta-data`

Notably, this built-in active set does **not** enable `format-assertion` by default, which matches the expected Draft 2020-12 behavior.

You can access this set programmatically:

```elixir
iex> JSONSchex.Vocabulary.draft2020_12_defaults()
[
  "https://json-schema.org/draft/2020-12/vocab/core",
  "https://json-schema.org/draft/2020-12/vocab/applicator",
  "https://json-schema.org/draft/2020-12/vocab/validation",
  "https://json-schema.org/draft/2020-12/vocab/unevaluated",
  "https://json-schema.org/draft/2020-12/vocab/format-annotation",
  "https://json-schema.org/draft/2020-12/vocab/content",
  "https://json-schema.org/draft/2020-12/vocab/meta-data"
]
```

### 2. Full supported vocabulary set

JSONSchex also exposes the full set of vocabularies that the implementation understands. This capability set is used when validating required `$vocabulary` declarations:

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
- Canonical Draft 2020-12 `$schema`: handled internally without a remote meta-schema fetch.
- Explicit root `$vocabulary`: honored even when the schema uses the built-in Draft 2020-12 dialect.
- No loader available for a custom `$schema`: the meta-schema is not resolved remotely, so JSONSchex falls back to its implementation defaults.

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

- Use the canonical Draft 2020-12 `$schema` URI when you want standard behavior without requiring a remote meta-schema fetch.
- If you rely on a custom meta-schema or vocabulary, provide an `external_loader`.
- Use `$schema` to make the dialect explicit and predictable.
- Use an explicit root `$vocabulary` only when you need to override the built-in active vocabulary set for the selected dialect.
- Avoid mixing keywords from unsupported vocabularies unless you also ship a loader that resolves the meta-schema.

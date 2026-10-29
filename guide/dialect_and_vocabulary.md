# Dialect and $vocabulary Guide

This guide explains how JSONSchex interprets `$schema` and `$vocabulary`, and how those settings influence validation and compilation.

## Overview

- A recognized root `$schema` URI selects Draft 7 or Draft 2020-12 automatically. If neither a recognized URI nor a valid `:draft` selects a draft, compilation defaults to Draft 2020-12.
- `:draft` can explicitly select `"draft7"` or `"draft2020_12"` (string values, not atoms); when it conflicts with a recognized root `$schema`, compilation fails instead of silently choosing either one.
- `$vocabulary` applies to Draft 2020-12 meta-schemas. Draft 7 predates `$vocabulary` and uses its own keyword set.

## Draft selection

The runtime compiler and `JSONSchex.Schema.compile!/2` follow the same rules:

| Root `$schema` | `:draft` | Result |
| --- | --- | --- |
| Recognized URI | Omitted | Use the declared draft |
| Recognized URI | Matching value | Use that draft |
| Recognized URI | Conflicting value | Fail with `:draft_conflict` |
| Absent or unrecognized URI | Valid value | Use the option |
| Absent or unrecognized URI | Omitted | Use Draft 2020-12 |

Recognized URIs are `http://json-schema.org/draft-07/schema` (with or without a trailing `#`) and `https://json-schema.org/draft/2020-12/schema`. Other URIs do not infer a draft. The option accepts only the strings `"draft7"` and `"draft2020_12"`; invalid values return `:invalid_draft`. The compile-time macro raises `CompileError` instead of returning these errors.

For `compile_fragment/2`, draft detection uses the containing document's root `$schema`, not a nested fragment's declaration. Referenced external schemas declaring a different recognized draft are not automatically switched: their compilation reports a conflict. Cross-draft resolution remains outside this policy.

## Meta-schema and vocabulary resolution

### Draft 2020-12

1. The canonical meta-schema URI (`https://json-schema.org/draft/2020-12/schema`) is built in, so no loader is needed.
2. The built-in dialect uses Draft 2020-12 active vocabulary defaults and honors an explicit root-level `$vocabulary` declaration.
3. Other `$schema` URIs are loaded through `:loader` when one is supplied; a loaded meta-schema's `$vocabulary` selects the active vocabularies.
4. Without a loader, JSONSchex falls back to its Draft 2020-12 capability set.

The fallback capability set includes format-assertion; it differs from the canonical dialect's annotation-only format defaults. Declare the canonical `$schema` URI when those standard defaults are required.

### Draft 7

Declare `"$schema" => "http://json-schema.org/draft-07/schema#"`, or pass `draft: "draft7"` when there is no recognized declaration. The canonical meta-schema is embedded as an Elixir map, so built-in references require neither a loader nor runtime file access. Other remote schemas still require a caller-supplied loader.

Draft 7 uses its own keyword set and ignores `$vocabulary`. Newer-draft keywords such as `prefixItems`, `minContains`, `maxContains`, and `contentSchema` do not gain validation semantics. `$defs` annotations are not eagerly compiled, although explicit JSON Pointer references into their content remain possible.

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
- Canonical Draft 2020-12 or Draft 7 `$schema`: selects that draft without a remote meta-schema fetch.
- Recognized `$schema` conflicting with `:draft`: compilation returns a `:draft_conflict` error (or raises `CompileError` for `Schema.compile!/2`).
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
{:ok, compiled} = JSONSchex.compile(schema, loader: loader)

# The schema compiles, but 'allOf' is ignored because the applicator
# vocabulary is not in the restricted meta-schema's vocabulary list
```

### Example 3: Format assertion through vocabulary

`format_assertion: true` enables format validation explicitly. In Draft 2020-12, an active format-assertion vocabulary also enables it; setting the option to `false` does not override that vocabulary.

```elixir
# The canonical dialect uses format annotations by default.
schema = %{
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "string",
  "format" => "email"
}

{:ok, annotations} = JSONSchex.compile(schema)
:ok = JSONSchex.validate(annotations, "not-an-email")

# Explicit opt-in enables assertion without changing the vocabulary declaration.
{:ok, assertions} = JSONSchex.compile(schema, format_assertion: true)
{:error, _errors} = JSONSchex.validate(assertions, "not-an-email")

# An active assertion vocabulary enables checks even when the option is false.
assertion_schema = Map.put(schema, "$vocabulary", %{
  "https://json-schema.org/draft/2020-12/vocab/core" => true,
  "https://json-schema.org/draft/2020-12/vocab/validation" => true,
  "https://json-schema.org/draft/2020-12/vocab/format-assertion" => true
})

{:ok, vocabulary_assertions} = JSONSchex.compile(assertion_schema, format_assertion: false)
{:error, _errors} = JSONSchex.validate(vocabulary_assertions, "not-an-email")
```

## Practical guidance

- Use the canonical Draft 2020-12 `$schema` URI when you want standard behavior without requiring a remote meta-schema fetch.
- If you rely on a custom meta-schema or vocabulary, provide a `:loader`.
- Use `$schema` to make the dialect explicit and predictable.
- Use an explicit root `$vocabulary` only when you need to override the built-in active vocabulary set for the selected dialect.
- Avoid mixing keywords from unsupported vocabularies unless you also ship a loader that resolves the meta-schema.

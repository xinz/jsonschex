# Content and Format Assertions Guide

This guide explains how JSONSchex handles the `content*` vocabulary and the `format` keyword, including how to enable assertion behavior.

## Overview

JSONSchex treats certain vocabularies as **annotation-only by default**. You can opt into assertion behavior at compile time:

- `contentEncoding`, `contentMediaType`, `contentSchema` are enabled by `content_assertion: true`
- `format` is enabled by `format_assertion: true`

If the corresponding assertion flag is not enabled, the keyword is accepted but does not enforce validation.

## Content Vocabulary Assertions

### Keywords

- `contentEncoding`
- `contentMediaType`
- `contentSchema`

### Default behavior

By default, these keywords are **annotations only**. No decoding or parsing is performed.

### Enabling assertions

Pass `content_assertion: true` when compiling:

```elixir
{:ok, compiled} =
  JSONSchex.compile(schema, content_assertion: true)
```

### Behavior when enabled

When `content_assertion` is enabled:

- `contentEncoding` supports:
  - `base64`
  - `base64url`
- `contentMediaType` supports:
  - `application/json`
  - Any media type ending in `+json`
- The decoded content is validated against `contentSchema`.

### Error reporting

Errors are surfaced using the following rule identifiers:

- `:contentEncoding` for decoding failures
- `:contentMediaType` for media type parsing failures
- The underlying schema rule for `contentSchema` validation failures

### Complete End-to-End Example

Here's a complete example showing content validation with base64-encoded JSON validated against a `contentSchema`:

```elixir
# Define a schema with content assertions
schema = %{
  "type" => "object",
  "properties" => %{
    "encodedData" => %{
      "type" => "string",
      "contentEncoding" => "base64",
      "contentMediaType" => "application/json",
      "contentSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["name", "age"]
      }
    }
  }
}

# Compile with content assertions enabled
{:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

# Valid case: properly encoded JSON that matches the content schema
valid_json = Jason.encode!(%{"name" => "Alice", "age" => 30})
valid_base64 = Base.encode64(valid_json)
valid_data = %{"encodedData" => valid_base64}

JSONSchex.validate(compiled, valid_data)
# => :ok

# Invalid case 1: Bad base64 encoding
invalid_base64 = %{"encodedData" => "not-valid-base64!!!"}
JSONSchex.validate(compiled, invalid_base64)
# => {:error, [%JSONSchex.Types.Error{
#      path: "/encodedData",
#      rule: :contentEncoding,
#      message: "Failed to decode contentEncoding: base64"
#    }]}

# Invalid case 2: Valid base64 but not JSON
non_json_base64 = Base.encode64("This is not JSON")
JSONSchex.validate(compiled, %{"encodedData" => non_json_base64})
# => {:error, [%JSONSchex.Types.Error{
#      path: "/encodedData",
#      rule: :contentMediaType,
#      message: "Failed to decode contentMediaType: application/json"
#    }]}

# Invalid case 3: Valid JSON but doesn't match contentSchema
invalid_json = Jason.encode!(%{"name" => "Bob", "age" => -5})  # age is negative
invalid_data = %{"encodedData" => Base.encode64(invalid_json)}
{:error, [error]} = JSONSchex.validate(compiled, invalid_data)
# error.path => "/encodedData"
# error.rule => :minimum
# error.message => "Value -5 is less than minimum 0"

# Invalid case 4: Missing required field in content
incomplete_json = Jason.encode!(%{"name" => "Charlie"})  # missing age
incomplete_data = %{"encodedData" => Base.encode64(incomplete_json)}
{:error, [error]} = JSONSchex.validate(compiled, incomplete_data)
# error.path => "/encodedData"
# error.rule => :required
# error.message => "Missing required properties: age"
```

### Practical Use Cases

Content vocabulary assertions are useful for:

1. **API Responses** — Validating that encoded payloads match expected schemas
2. **Data Storage** — Ensuring stored encoded data is valid before saving
3. **Message Queues** — Validating message payloads that are base64-encoded
4. **Configuration Files** — Checking that embedded encoded configs are valid

## Format assertions

### Keyword

- `format`

### Default behavior

`format` is **annotation-only** by default.

### Enabling assertions

Pass `format_assertion: true` when compiling:

```elixir
{:ok, compiled} =
  JSONSchex.compile(schema, format_assertion: true)
```

### Supported Format Values

When `format_assertion` is enabled, the following format values are supported:

#### Date and Time Formats
- `date-time` — RFC 3339 date-time (e.g., `"2024-01-15T10:30:00Z"`)
- `date` — RFC 3339 full-date (e.g., `"2024-01-15"`)
- `time` — RFC 3339 full-time (e.g., `"10:30:00Z"`)
- `duration` — ISO 8601 duration (e.g., `"P3Y6M4DT12H30M5S"`)

#### Email Formats
- `email` — Email address (e.g., `"user@example.com"`)
- `idn-email` — Internationalized email address (requires `idna` dependency)

#### Hostname Formats
- `hostname` — DNS hostname (e.g., `"example.com"`)
- `idn-hostname` — Internationalized hostname (requires `idna` dependency)

#### IP Address Formats
- `ipv4` — IPv4 address (e.g., `"192.168.1.1"`)
- `ipv6` — IPv6 address (e.g., `"2001:0db8:85a3::8a2e:0370:7334"`)

#### URI Formats
- `uri` — Absolute URI with scheme (e.g., `"https://example.com/path"`)
- `uri-reference` — URI reference (absolute or relative, e.g., `"/path/to/resource"`)
- `iri` — Internationalized Resource Identifier
- `iri-reference` — IRI reference (absolute or relative)
- `uri-template` — URI template (RFC 6570, e.g., `"https://api.example.com/users/{id}"`)

#### Identifier Formats
- `uuid` — UUID (e.g., `"550e8400-e29b-41d4-a716-446655440000"`)

#### JSON Pointer Formats
- `json-pointer` — JSON Pointer (e.g., `"/foo/bar/0"`)
- `relative-json-pointer` — Relative JSON Pointer (e.g., `"1/foo"`)

#### Pattern Format
- `regex` — ECMA-262 regular expression

### Behavior when enabled

When `format_assertion` is enabled:

- JSONSchex validates data against the format registry.
- Unknown format values pass validation by default (per the specification).
- Errors are returned with `:format` rule identifier.

### Format Validation Examples

```elixir
# Email validation
email_schema = %{"type" => "string", "format" => "email"}
{:ok, compiled} = JSONSchex.compile(email_schema, format_assertion: true)

JSONSchex.validate(compiled, "user@example.com")
# => :ok

JSONSchex.validate(compiled, "not-an-email")
# => {:error, [%JSONSchex.Types.Error{rule: :format, message: "Format mismatch: email"}]}

# UUID validation
uuid_schema = %{"type" => "string", "format" => "uuid"}
{:ok, compiled} = JSONSchex.compile(uuid_schema, format_assertion: true)

JSONSchex.validate(compiled, "550e8400-e29b-41d4-a716-446655440000")
# => :ok

JSONSchex.validate(compiled, "not-a-uuid")
# => {:error, [%JSONSchex.Types.Error{rule: :format, message: "Format mismatch: uuid"}]}

# Date-time validation
datetime_schema = %{"type" => "string", "format" => "date-time"}
{:ok, compiled} = JSONSchex.compile(datetime_schema, format_assertion: true)

JSONSchex.validate(compiled, "2024-01-15T10:30:00Z")
# => :ok

JSONSchex.validate(compiled, "not a date")
# => {:error, [%JSONSchex.Types.Error{rule: :format, message: "Format mismatch: date-time"}]}

# IPv4 validation
ipv4_schema = %{"type" => "string", "format" => "ipv4"}
{:ok, compiled} = JSONSchex.compile(ipv4_schema, format_assertion: true)

JSONSchex.validate(compiled, "192.168.1.1")
# => :ok

JSONSchex.validate(compiled, "999.999.999.999")
# => {:error, [%JSONSchex.Types.Error{rule: :format, message: "Format mismatch: ipv4"}]}
```

## Practical guidance

- Enable assertions only when you need strict validation; annotation-only mode is faster and more permissive.
- If you validate user input that must conform to content or format constraints, enable the relevant assertion flags.
- You can enable both `content_assertion` and `format_assertion` in the same compile call.

```elixir
# Enable both content and format assertions
{:ok, compiled} = JSONSchex.compile(
  schema,
  content_assertion: true,
  format_assertion: true
)
```

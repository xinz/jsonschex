# Structural `$ref` Guide

This guide explains the low-level reference discovery helpers in `JSONSchex.Ref`.

Unlike `JSONSchex.compile/2`, this API is intentionally **policy-free**. It does not rewrite documents, merge sibling keywords, or apply OpenAPI-specific reference semantics. Instead, it exposes reusable mechanics for:

- discovering `$ref` occurrences in nested maps and lists
- resolving local and external references
- tracking source and base URI context
- walking the transitive `$ref` graph
- detecting cycles during transitive traversal

Use this API when you need to inspect or normalize documents **before** compilation, or when your application owns its own reference expansion policy.

## `:source` vs `:base_uri`

These two options are related, but they are not the same:

- `:base_uri` controls how relative references resolve
- `:source` identifies where the current document came from

In practice, `:source` is primarily provenance metadata that is copied into returned locations, resolutions, errors, and walk events. However, when `:base_uri` is omitted and `:source` is a binary, `JSONSchex.Ref` also uses `:source` as the initial base URI.

That means:

- if you only care about resolution semantics, passing `:base_uri` is enough
- if you also want meaningful source metadata, pass `:source`
- if your source path or URI should also act as the reference base, you can pass only `:source`

## Overview

`JSONSchex.Ref` exposes three main entry points:

- `scan/2` — discover structural `$ref` locations
- `resolve/3` — resolve one location or raw ref string
- `walk/2` — traverse reachable `$ref` targets transitively

## `scan/2`

`scan/2` walks nested maps and lists structurally and returns a list of `%JSONSchex.Ref.Location{}` values.

Each location includes:

- `:raw_ref` — original `$ref` string
- `:path` — path to the `$ref` key within the scanned document
- `:source` — caller-supplied source identifier used for provenance
- `:base_uri` — effective base URI at that location, honoring nested `$id`
- `:absolute_uri` — resolved target URI when it can be derived
- `:fragment` — target fragment without the leading `#`

Example:

```elixir
root = %{
  "$id" => "https://example.com/root.json",
  "$defs" => %{
    "user" => %{
      "$id" => "schemas/user.json",
      "schema" => %{"$ref" => "#/$defs/name"},
      "$defs" => %{
        "name" => %{"type" => "string"}
      }
    }
  }
}

[location] = JSONSchex.Ref.scan(root)

location.raw_ref
#=> "#/$defs/name"

location.path
#=> ["$defs", "user", "schema", "$ref"]

location.base_uri
#=> "https://example.com/schemas/user.json"

location.absolute_uri
#=> "https://example.com/schemas/user.json#/$defs/name"
```

## `resolve/3`

`resolve/3` resolves one ref from a given document context.

You can pass either:

- a raw reference string
- a `%JSONSchex.Ref.Location{}` returned by `scan/2`

Passing a `Location` is usually the better choice because it preserves nested `$id` scoping.

If you omit `:base_uri`, a binary `:source` also becomes the initial base URI for the root document.

### Loader contract

External documents are loaded through `:loader` or `:external_loader`.

The loader receives a **document URI without the fragment** and may return either:

- `{:ok, document}`
- `{:ok, %{document: document, source: source}}`
- `{:error, term}`

Example:

```elixir
root = %{
  "user" => %{"$ref" => "schemas/common.json#/$defs/id"}
}

loader = fn uri ->
  case uri do
    "specs/schemas/common.json" ->
      {:ok,
       %{
         document: %{
           "$defs" => %{
             "id" => %{"type" => "string"}
           }
         },
         source: uri
       }}

    _ ->
      {:error, :enoent}
  end
end

[location] = JSONSchex.Ref.scan(root, source: "specs/root.json")

{:ok, resolution} =
  JSONSchex.Ref.resolve(root, location,
    source: "specs/root.json",
    loader: loader
  )

resolution.target_uri
#=> "specs/schemas/common.json#/$defs/id"

resolution.target_pointer
#=> "#/$defs/id"

resolution.target_value
#=> %{"type" => "string"}
```

### Built-in Draft 2020-12 resources

Bundled Draft 2020-12 resources can be resolved without a custom loader.

```elixir
root = %{
  "$ref" => "https://json-schema.org/draft/2020-12/meta/core#/$defs/uriString"
}

[location] = JSONSchex.Ref.scan(root)
{:ok, resolution} = JSONSchex.Ref.resolve(root, location)

resolution.target_value
#=> %{"type" => "string", "format" => "uri"}
```

## `walk/2`

`walk/2` performs a depth-first transitive traversal over reachable `$ref` targets.

It returns `{:ok, events}` where `events` is an ordered list of:

- `%JSONSchex.Ref.Resolution{}`
- `%JSONSchex.Ref.Error{}`
- `%JSONSchex.Ref.Cycle{}`

This makes `walk/2` inspection-oriented rather than fail-fast: you can see successful edges, missing targets, and cycles in one result.

### Cycle handling

When a resolved target would recurse into an already-active target, `walk/2` emits `%JSONSchex.Ref.Cycle{}` and stops expanding that branch.

### External document caching

Within a single `walk/2` call, externally loaded documents are cached internally by document URI. Repeated edges still emit their own resolution events, but loader calls are not repeated for the same external resource.

Example:

```elixir
root = %{
  "$id" => "https://example.com/root.json",
  "$defs" => %{
    "a" => %{"$ref" => "#/$defs/b"},
    "b" => %{"$ref" => "#/$defs/a"}
  },
  "start" => %{"$ref" => "#/$defs/a"}
}

{:ok, events} = JSONSchex.Ref.walk(root, base_uri: "https://example.com/root.json")

Enum.map(events, & &1.__struct__)
#=> [JSONSchex.Ref.Resolution, JSONSchex.Ref.Resolution, JSONSchex.Ref.Cycle, ...]
```

## Structured errors

`resolve/3` and `walk/2` use `%JSONSchex.Ref.Error{}` for resolution failures.

Current error kinds are:

- `:invalid_ref`
- `:missing_document`
- `:missing_target`
- `:invalid_loader_response`

These errors preserve the originating location and target URI when available, making them useful for downstream diagnostics.

## Choosing between APIs

Use `JSONSchex.compile/2` when you want validation-ready compiled schemas.

Use `JSONSchex.Ref` when you want structural facts and traversal mechanics, but your application will decide what to do with those facts.

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

`JSONSchex.Ref` exposes a small set of public structural `$ref` entry points and
helpers:

- `scan/2` — discover structural `$ref` locations
- `resolve/3` — resolve one location or raw ref string
- `walk/2` — traverse reachable `$ref` targets transitively
- `transform/3` — apply a callback-driven structural rewrite over discovered `$ref` locations
- `rebase/3` — rewrite a resource so its refs remain valid under a new root resource URI
- `render_ref/3` — render a stable `$ref` string for a resolved target
- `target_uri/1` — compute a canonical absolute URI for a resolved target
- `collect_external_resources/2` — collect reachable non-root resources keyed by canonical resource URI
- `bundle/3` — return a structured bundle-oriented view containing rebased root and collected resources
- `index_walk_events/1` — convert ordered walk events into a location-keyed index

## `scan/2`

`scan/2` walks nested maps and lists structurally and returns a list of `%JSONSchex.Ref.Location{}` values.

Each location includes:

- `:raw_ref` — original `$ref` string
- `:path` — path to the `$ref` key within the scanned document
- `:source` — caller-supplied source identifier used for provenance
- `:base_uri` — effective base URI at that location, honoring nested `$id`
- `:absolute_uri` — resolved target URI when it can be derived

When you need the fragment portion, derive it from `location.absolute_uri` (or `location.raw_ref`) via `JSONSchex.URIUtil.fragment/1`.

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

External documents are loaded through `:loader`.

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

resolution.location.absolute_uri
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

## `transform/3`

`transform/3` builds on the same traversal engine as `walk/2`, but lets you decide what to do with each discovered location.

It accepts the same root-context options as `resolve/3` and `walk/2`:

- `:source`
- `:base_uri`
- `:loader`

The callback receives:

- the `%JSONSchex.Ref.Location{}` being processed
- one of:
  - `{:ok, resolution}`
  - `{:cycle, resolution, cycle}`
  - `{:error, error}`

It returns one of:

- `{:replace, term}` — replace the node containing the `$ref`
- `:keep` — keep the current node unchanged
- `{:error, term}` — abort the transform

Nested targets are transformed before the callback runs for a successful parent location, which makes `transform/3` useful for post-order expansion.

When a callback is triggered for a nested ref discovered inside a resolved target, the returned `%JSONSchex.Ref.Location{}` path is expressed in that resolved target's own document context. In other words, it is not prefixed by the original referring location's path.

### Expanding non-cyclic refs

A simple downstream expansion policy can replace every successful ref with its resolved target value:

```elixir
policy = fn _location, outcome ->
  case outcome do
    {:ok, resolution} -> {:replace, resolution.target_value}
    {:cycle, _resolution, _cycle} -> :keep
    {:error, error} -> {:error, error}
  end
end

{:ok, expanded} =
  JSONSchex.Ref.transform(document, policy,
    source: "specs/root.json",
    loader: loader
  )
```

### Preserving recursive back-edges

For recursive schemas, a downstream policy can preserve a cycle edge while still expanding non-cyclic refs:

```elixir
policy = fn location, outcome ->
  case outcome do
    {:ok, resolution} ->
      {:replace, resolution.target_value}

    {:cycle, resolution, _cycle} ->
      {:replace, %{"$ref" => JSONSchex.Ref.render_ref(location, resolution)}}

    {:error, error} ->
      {:error, error}
  end
end
```

That keeps `jsonschex` structural and low-level, while letting downstream code decide its own rewrite policy.

## `render_ref/3`

`render_ref/3` renders a stable `$ref` string for a resolved target.

Supported modes are:

- `:original` — reuse the original raw `$ref` spelling from the source location
- `:absolute` — render an absolute target URI
- `:prefer_local` — default; render a local fragment for same-resource targets, otherwise prefer a relative resource ref and fall back to absolute rendering
- `:mounted` — render the target as it should appear from a rebased or mounted resource context

`mode: :mounted` expects:

- `:mount_base_uri` — the rebased containing resource base URI
- optional `:resource_uri_map` — target-resource remapping applied before rendering

Examples:

- same-resource pointer target → `#/$defs/name`
- same-resource anchor target → `#name`
- same-resource root target → `#`
- cross-resource target → `schemas/common.json#/$defs/name` or an absolute URI
- mounted nested target → `../common.json#Pet` or another rebased relative form

This is especially useful when `transform/3` decides to preserve a cycle edge instead of expanding it, or when downstream bundling code needs to render refs from a rebased resource context.

## `target_uri/1`

`target_uri/1` returns the canonical absolute URI for a `%JSONSchex.Ref.Resolution{}` when it can be derived.

This is useful when downstream code needs a stable identity key for:

- rebasing
- resource caches
- bundle indexes
- comparing original vs rebased targets

```elixir
resolution = %JSONSchex.Ref.Resolution{
  location: %JSONSchex.Ref.Location{
    raw_ref: "schemas/common.json#/$defs/id",
    path: ["schema", "$ref"],
    absolute_uri: "specs/schemas/common.json#/$defs/id"
  },
  target_source: "specs/schemas/common.json",
  target_document: %{"$defs" => %{"id" => %{"type" => "integer"}}},
  target_value: %{"type" => "integer"},
  target_pointer: "#/$defs/id"
}

JSONSchex.Ref.target_uri(resolution)
#=> "specs/schemas/common.json#/$defs/id"
```

## `rebase/3`

`rebase/3` rewrites a resource so its refs remain valid under a new root resource URI.

This is a structural rebasing helper, not an expansion helper. It:

- rewrites `$ref` strings as needed
- preserves already-correct same-resource refs when possible
- keeps nested relative `$id` resources relative to the new root
- preserves absolute nested `$id` resources as separate identities
- optionally applies explicit target remaps through `:resource_uri_map`

It accepts:

- `target_base_uri` — the new root resource URI
- `:source` — provenance for the current document
- `:base_uri` — current starting base URI used before rebasing
- `:resource_uri_map` — optional explicit remaps for target resources outside the current document

Example:

```elixir
root = %{
  "$id" => "https://example.com/root.json",
  "$defs" => %{
    "user" => %{
      "$id" => "schemas/user.json",
      "$defs" => %{"name" => %{"type" => "string"}},
      "schema" => %{"$ref" => "#/$defs/name"}
    }
  },
  "start" => %{"$ref" => "https://example.com/schemas/user.json#/$defs/name"}
}

{:ok, rebased} =
  JSONSchex.Ref.rebase(root, "https://bundle.example/root.json")

rebased["$id"]
#=> "https://bundle.example/root.json"

rebased["start"]["$ref"]
#=> "schemas/user.json#/$defs/name"
```

## `collect_external_resources/2`

`collect_external_resources/2` builds on `walk/2` and groups successful reachable non-root resources by canonical resource URI.

Each entry contains:

- `:document` — the resource root document
- `:source` — the loaded document source, when available
- `:resolutions` — all successful incoming resolutions that targeted that resource

Only successful `%Resolution{}` events are collected. `%Error{}` and `%Cycle{}` events are ignored for collection purposes.

```elixir
{:ok, resources} =
  JSONSchex.Ref.collect_external_resources(document,
    source: "specs/root.json",
    loader: loader
  )

Map.keys(resources)
#=> ["specs/schemas/common.json"]
```

## `bundle/3`

`bundle/3` returns a structured bundle-oriented view of the root document and its reachable external resources.

It combines:

- `walk/2`
- `index_walk_events/1`
- `collect_external_resources/2`
- `rebase/3`

The returned map currently includes:

- `:root_document`
- `:resources_by_uri`
- `:rebased_resources_by_uri`
- `:resource_uri_map`
- `:walk_events`
- `:walk_index`
- `:location_index`
- `:resource_index`

This is intentionally still a low-level, policy-free helper rather than a final downstream bundling contract, but it already removes a lot of repetitive collection and rebasing glue.

```elixir
{:ok, bundle} =
  JSONSchex.Ref.bundle(document, "specs/bundle/root.json",
    source: "specs/root.json",
    loader: loader,
    resource_uri_map: %{
      "specs/schemas/common.json" => "specs/bundle/common.json"
    }
  )

bundle.root_document["$id"]
#=> "specs/bundle/root.json"

bundle.rebased_resources_by_uri["specs/schemas/common.json"]["$id"]
#=> "specs/bundle/common.json"
```

## `index_walk_events/1`

`index_walk_events/1` turns the ordered output of `walk/2` into a map keyed by `location_key/1`.

This is useful when downstream code wants fast lookup by location rather than replaying the ordered event stream.

```elixir
{:ok, events} = JSONSchex.Ref.walk(document, source: "specs/root.json", loader: loader)
index = JSONSchex.Ref.index_walk_events(events)

location = hd(JSONSchex.Ref.scan(document, source: "specs/root.json"))
key = JSONSchex.Ref.location_key(location)

resolution = index.resolutions[key]
```

## Local files, nested `$id`, and loader consistency

A common downstream workflow is using local file refs together with nested `$id` boundaries.

Example:

```elixir
root = %{
  "$id" => "specs/root.json",
  "components" => %{
    "user" => %{
      "$id" => "schemas/user.json",
      "schema" => %{"$ref" => "./common.json#/$defs/id"}
    }
  }
}

loader = fn
  "specs/schemas/common.json" ->
    {:ok,
     %{
       "$defs" => %{
         "id" => %{"type" => "integer"}
       }
     }}

  _ ->
    {:error, :enoent}
end

[location] = JSONSchex.Ref.scan(root, source: "specs/root.json")
{:ok, resolution} = JSONSchex.Ref.resolve(root, location, source: "specs/root.json", loader: loader)
```

In that example:

- `scan/2` records the nested resource base as `specs/schemas/user.json`
- the relative ref `./common.json#/$defs/id` resolves to `specs/schemas/common.json#/$defs/id`
- the loader receives the **document URI without the fragment**: `specs/schemas/common.json`

Runtime validation uses the same document-loading contract for unresolved external refs, so preserved local-file `$ref` values can participate in validation through `loader` as well.

### Recursive local-file traversal with `walk/2`

The same loader contract works for recursive local-file schemas too:

```elixir
root = %{
  "$id" => "specs/root.json",
  "start" => %{"$ref" => "schemas/node.json#/$defs/node"}
}

loader = fn
  "specs/schemas/node.json" ->
    {:ok,
     %{
       "$defs" => %{
         "node" => %{
           "type" => "object",
           "properties" => %{
             "next" => %{"$ref" => "#/$defs/node"}
           }
         }
       }
     }}

  _ ->
    {:error, :enoent}
end

{:ok, events} =
  JSONSchex.Ref.walk(root,
    source: "specs/root.json",
    loader: loader
  )

Enum.map(events, & &1.__struct__)
#=> [JSONSchex.Ref.Resolution, JSONSchex.Ref.Resolution, JSONSchex.Ref.Cycle]
```

In that example:

- the root ref resolves through the loader to `specs/schemas/node.json#/$defs/node`
- the nested `#/$defs/node` ref is resolved inside the loaded document
- `walk/2` emits a `%JSONSchex.Ref.Cycle{}` instead of recursing forever
- the external document is still loaded only once for the whole traversal

## Structured errors

`resolve/3` and `walk/2` use `%JSONSchex.Ref.Error{}` for resolution failures.

Current error kinds are:

- `:invalid_ref`
- `:missing_document`
- `:missing_target`
- `:invalid_loader_response`

These errors preserve the originating location, which includes the resolved target URI when it can be derived via `location.absolute_uri`, making them useful for downstream diagnostics.

## Choosing between APIs

Use `JSONSchex.compile/2` when you want validation-ready compiled schemas.

Use `JSONSchex.Ref` when you want structural facts and traversal mechanics, but your application will decide what to do with those facts.

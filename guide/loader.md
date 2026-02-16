# Loader and Remote $ref Guide

This guide explains how JSONSchex resolves remote references and how to supply an external loader when compiling schemas.

## Overview

JSONSchex supports:

- Remote `$ref` resolution
- `$schema` resolution when a meta-schema needs to be fetched
- `$id`-based base URI scoping for nested schemas

Remote fetching is **opt-in** via the `external_loader` option passed to `JSONSchex.compile/2`.

## Loader contract

Your loader is a function that receives a URI string and returns one of:

- `{:ok, map}` — a decoded JSON Schema map
- `{:error, term}` — any error reason you want to propagate

Any other return value is treated as invalid.

### Minimal example

```elixir
# Assuming you have a schema that references external schemas
schema = %{
  "type" => "object",
  "properties" => %{
    "user" => %{"$ref" => "https://example.com/user.json"}
  }
}

loader = fn uri ->
  case MySchemaStore.fetch(uri) do
    {:ok, json_string} -> Jason.decode(json_string)
    {:error, reason} -> {:error, reason}
  end
end

{:ok, compiled} =
  JSONSchex.compile(schema, external_loader: loader, base_uri: "https://example.com/root.json")
```

### HTTP-based loader example

For production use, you'll typically want to load schemas over HTTP. Here's a more complete example using a common HTTP client pattern:

```elixir
defmodule MyApp.SchemaLoader do
  @moduledoc """
  Loads JSON Schemas from HTTP URLs with caching.
  """

  # Simple in-memory cache using Agent
  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def loader(uri) do
    # Check cache first
    case Agent.get(__MODULE__, &Map.get(&1, uri)) do
      nil ->
        # Not cached, fetch from HTTP
        fetch_and_cache(uri)

      cached_schema ->
        {:ok, cached_schema}
    end
  end

  defp fetch_and_cache(uri) do
    # Using your HTTP client of choice (e.g., HTTPoison, Finch, Req)
    case HTTPoison.get(uri, [{"Accept", "application/json"}]) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, schema} ->
            # Cache the decoded schema
            Agent.update(__MODULE__, &Map.put(&1, uri, schema))
            {:ok, schema}

          {:error, _} = error ->
            error
        end

      {:ok, %{status_code: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

# Usage
MyApp.SchemaLoader.start_link()

schema = %{
  "$ref" => "https://json-schema.org/draft/2020-12/schema"
}

{:ok, compiled} = JSONSchex.compile(schema, external_loader: &MyApp.SchemaLoader.loader/1)
```

**Important considerations for HTTP loaders:**

- Always set timeouts to avoid hanging on slow responses
- Implement caching to avoid repeated fetches of the same schema
- Handle HTTP errors gracefully (404, 500, network failures)
- Consider validating fetched schemas before returning them
- Be mindful of infinite recursion if schemas reference each other circularly

## When the loader is called

The loader is invoked when:

1. A `$ref` points to a **remote URI** that is not already in the registry.
2. A `$schema` URI must be loaded to resolve dialect and `$vocabulary` (if a loader is provided).

If no loader is supplied, JSONSchex skips remote fetches and proceeds with defaults where possible.

## Remote $ref resolution flow

At a high level:

1. Resolve the `$ref` against the current base URI.
2. Check the local registry for a match.
3. If the ref is remote and not in the registry, call the loader.
4. Compile the remote schema and merge its registry into the root context.
5. Continue validation from the referenced fragment, if any.

## :base_uri option and $id interaction

Understanding how `:base_uri` and `$id` interact is crucial for correct reference resolution:

### Base URI Resolution

- The `:base_uri` option sets the starting point for resolving relative references at compile time
- Each `$id` in a nested schema updates the base URI for that subtree
- Anchors like `$anchor` and `$dynamicAnchor` are registered under the current base URI

### Scoping Rules

When JSONSchex encounters a schema with an `$id`:

1. **Relative `$id`** — Resolved against the current base URI to create a new absolute base
2. **Absolute `$id`** — Becomes the new base URI for that schema and its children
3. **No `$id`** — Inherits the parent's base URI

**Example:**

```elixir
schema = %{
  "$id" => "https://example.com/root",
  "$defs" => %{
    "user" => %{
      "$id" => "schemas/user",  # Resolves to https://example.com/schemas/user
      "$anchor" => "userSchema",
      "type" => "object"
    },
    "admin" => %{
      "$id" => "https://other.com/admin",  # Absolute, replaces base
      "$anchor" => "adminSchema",
      "type" => "object"
    }
  }
}

{:ok, compiled} = JSONSchex.compile(schema)

# References can now use:
# - "https://example.com/schemas/user" or "#/$defs/user" for user schema
# - "https://example.com/schemas/user#userSchema" for anchor
# - "https://other.com/admin" or "#/$defs/admin" for admin schema
# - "https://other.com/admin#adminSchema" for admin anchor
```

### When to set :base_uri

You typically need `:base_uri` when:

1. Your schema uses relative `$ref` values but has no root `$id`
2. You're loading a schema from a URL and want references to resolve relative to that URL
3. You're testing with schemas that expect a specific base context

**Default behavior:** If you don't set `:base_uri` and the schema has no `$id`, references are resolved relative to an empty base, which means only fragment references (`#/...`) and absolute URIs will work.

If you rely on relative references, always set `:base_uri` at compile time. By default, there is no need to set it—the compiler will use the input schema definition to extract the base URI for the entire compiling context.

## Error handling

If the loader returns `{:error, reason}`:

- Validation fails with an error message that includes the URI and reason.
- The error is returned as part of validation, not raised as an exception.

If the loader returns an unexpected value:

- JSONSchex treats it as an invalid loader response.

## Caching recommendations

Loaders are called on-demand. For performance, consider caching:

- Remote schema maps keyed by URI
- Compiled schema artifacts if your application lifecycle allows it

## Tips and best practices

- Keep the loader side-effect free and deterministic.
- Validate or sanitize the returned schema map before returning `{:ok, map}`.
- Propagate the same loader for nested resolutions by always passing it to `JSONSchex.compile/2`.
- **Note**: JSONSchex supports `urn:` scheme URIs for schema identification. The `URIUtil` and `Reference` modules both handle URN references specially during resolution.

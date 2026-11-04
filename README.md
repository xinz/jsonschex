# JSONSchex

[![hex.pm version](https://img.shields.io/hexpm/v/jsonschex.svg?v=1)](https://hex.pm/packages/jsonschex)
[![Draft 2020-12](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Felixir-jsonschex%2Fcompliance%2Fdraft2020-12.json)](https://bowtie.report/#/implementations/elixir-jsonschex)

JSONSchex is a performance-focused JSON Schema validator for Elixir, supporting [Draft 2020-12](https://json-schema.org/draft/2020-12) and [Draft 7](https://json-schema.org/draft-07).

## Features

- **Draft 7 and Draft 2020-12:** 100% pass rate on the bundled [official JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) cases [run for both drafts](guide/test_suite.md).
- **Compile once, validate repeatedly:** reuse compiled `Schema` structs instead of recompiling schemas for every validation.
- **Measured performance:** reproducible [Benchee benchmarks](https://github.com/xinz/jsonschex/blob/main/bench/README.md) compare validation throughput and memory usage across Elixir JSON Schema libraries; see the [results](https://github.com/xinz/jsonschex/blob/main/bench/results.txt).
- **OpenAPI integration:** supports [Oasis](https://hex.pm/packages/oasis), an Elixir/Plug OpenAPI v3 server and code generator.

## Installation

Requires Elixir 1.14 or later. Add JSONSchex to your dependencies:

```elixir
def deps do
  [
    {:jsonschex, "~> 0.10"}
  ]
end
```

## Quick start

Pass schemas and data as decoded Elixir terms; schema objects use maps with string keys.

```elixir
{:ok, compiled} =
  JSONSchex.compile(%{
    "type" => "array",
    "items" => %{"type" => "integer"}
  })

:ok = JSONSchex.validate(compiled, [1, 2, 3])
{:error, errors} = JSONSchex.validate(compiled, [1, "bad"])

Enum.map(errors, &JSONSchex.format_error/1)
# => ["At /1: Expected type integer, got string"]
```

## Draft selection

Draft 2020-12 is the default. A recognized root `$schema` selects the draft automatically:

```elixir
# Draft 7 uses array-form items for positional validation.
schema = %{
  "$schema" => "http://json-schema.org/draft-07/schema#",
  "items" => [%{"type" => "integer"}],
  "additionalItems" => false
}

{:ok, compiled} = JSONSchex.compile(schema)
:ok = JSONSchex.validate(compiled, [1])
{:error, _errors} = JSONSchex.validate(compiled, [1, 2])

# Without a recognized declaration, select Draft 7 explicitly with a string value.
{:ok, _compiled} = JSONSchex.compile(Map.delete(schema, "$schema"), draft: "draft7")
```

The `:draft` option accepts `"draft7"` and `"draft2020_12"` as strings, not atoms. It must agree with a recognized root `$schema`; a conflict returns`{:error, %JSONSchex.Types.Error{rule: :draft_conflict}}`. `JSONSchex.Schema.compile!/2` follows the same policy, raising `CompileError` instead. See the [dialect guide](guide/dialect_and_vocabulary.md) for custom meta-schemas and vocabulary behavior.

## Compile-time schemas

For static schemas, compile and embed a `Schema` struct in a module attribute with `JSONSchex.Schema.compile!/2` or the compact `~X` sigil.

### Using `JSONSchex.Schema.compile!/2`

You can embed the compiled schema directly in your module with `JSONSchex.Schema.compile!/2`:

```elixir
defmodule MyApp.UserSchema do
  require JSONSchex.Schema

  @schema JSONSchex.Schema.compile!(%{
    "type" => "string",
    "format" => "email"
  }, format_assertion: true)

  def schema, do: @schema
end

:ok = JSONSchex.validate(MyApp.UserSchema.schema(), "user@example.com")
```

### Using the `~X` sigil

`use JSONSchex` imports the `~X` sigil for Elixir schema literals:

```elixir
defmodule MyApp.NumberSchema do
  use JSONSchex

  @schema ~X|%{"type" => "integer", "minimum" => 10}|

  def schema, do: @schema
end
```

For a narrower import, use `import JSONSchex.Sigil, only: [sigil_X: 2]` instead. `~X` parses Elixir code, not JSON, and supports these modifiers:

- `f` — `format_assertion: true`
- `c` — `content_assertion: true`

For compile-time embeddable options such as `:loader`, prefer remote
captures like `&MyLoader.fetch/1` over anonymous functions.

`~X` is preferred over `~J` to avoid the common sigil-name conflict with Jason.

## How it works

1. **Compile** — Convert schema keywords into reusable, serializable rule descriptors; register resource IDs, anchors, and eligible local references; and select the draft's keywords and vocabularies.
2. **Validate** — Execute those rules against each value, resolve references, track evaluated properties/items where required, and return structured validation errors.

Both drafts support `$ref`; Draft 2020-12 also supports `$dynamicRef`. Canonical meta-schemas for both drafts are embedded and need no loader. Other external resources require a caller-supplied `:loader` when resolved.

Reusing the compiled schema avoids repeating the initial schema compilation for every value. Human-readable error messages are formatted only when requested.

## Error reporting

`JSONSchex.validate/2` returns `:ok` or `{:error, errors}`, where each error is a `JSONSchex.Types.Error` struct:

- `path` — Path segments stored deepest-first: `["email", 0, "users"]` represents `/users/0/email`. An empty list identifies the root.
- `rule` — The failed validation rule, such as `:type` or `:minimum`.
- `context` — An `ErrorContext` struct carrying the constraint, processed input, and additional details, when present.
- `value` — The failing input value, when available.

Use `JSONSchex.format_error/1` to render a root-first JSON Pointer and a readable message:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "user" => %{
      "type" => "object",
      "properties" => %{"age" => %{"type" => "integer", "minimum" => 0}}
    }
  }
}

{:ok, compiled} = JSONSchex.compile(schema)
{:error, [error]} = JSONSchex.validate(compiled, %{"user" => %{"age" => -5}})

{error.rule, error.path, error.value}
# => {:minimum, ["age", "user"], -5}

JSONSchex.format_error(error)
# => "At /user/age: Value -5 is less than minimum 0"
```

Regex engine failures return `:indeterminate_pattern` and stop validation. See
the [regex validation guide](guide/regex_validation.md) for execution limits,
error details, and guidance on avoiding excessive backtracking.

## Compile options

`JSONSchex.compile/2` accepts these options:

| Option | Purpose |
| --- | --- |
| `:draft` | `"draft7"` or `"draft2020_12"`; see [draft selection](#draft-selection). |
| `:base_uri` | Starting URI or path for resolving relative IDs and references. |
| `:loader` | Callback that loads decoded external resources; see the [loader guide](guide/loader.md). |
| `:format_assertion` | Explicitly enable `format` checks (default: `false`). An active format-assertion vocabulary also enables them. |
| `:content_assertion` | Enable supported `content*` checks (default: `false`). |

The canonical Draft 2020-12 dialect treats `format` as annotation-only by default.
In Draft 2020-12, omitting `$schema` or using an unresolved custom meta-schema activates a fallback vocabulary set that includes format assertions, even with `format_assertion: false`. See the [content and format guide](guide/content_and_format.md)
for assertion behavior and the [dialect guide](guide//dialect_and_vocabulary.md) for vocabulary selection.

## Fragments and reference resolution

### Compile or bundle a fragment

Use `JSONSchex.compile_fragment/2` when a schema lives inside a larger document, such as OpenAPI, so local references retain their containing-document context:

```elixir
document = %{
  "components" => %{"schemas" => %{"Name" => %{"type" => "string"}}},
  "schema" => %{"$ref" => "#/components/schemas/Name"}
}

{:ok, compiled} = JSONSchex.compile_fragment(document, entry: "#/schema")
:ok = JSONSchex.validate(compiled, "Ada")
```

- `:entry` accepts a JSON Pointer or URI reference, such as `"#/schema"` or `"/api/openapi.yaml#/schema"`.
- Draft detection uses the containing document's root `$schema`; use `:draft` when it is absent or unrecognized.
- Supply `:base_uri` for relative external references. If omitted, a URI/path in `:entry` supplies that base.
- Loaders may return `{:ok, schema}` or `{:ok, %{document: schema, base_uri: base_uri}}`. Wrapper metadata uses atom keys only.

`JSONSchex.bundle_fragment/2` accepts the same entry options and returns `{:ok, raw_schema}` with reachable external resources mounted under `$defs`.
Compile the complete returned schema with `JSONSchex.compile/2`. Generated `jsonschex_` definition keys are collision-safe internal storage names, not stable reference paths; resources retain their identity through `$id` and anchors.

### Resolve selected references

`JSONSchex.Ref.resolve_selected/2` resolves selected `$ref` nodes in JSON-like documents without compiling a schema. Its required `:select` callback receives `(path, node)` and decides which reference nodes to replace with their target values. Unselected references are preserved, while their sibling values are still traversed. Preserved descendant references are rebased when external content is inlined. External loading uses the same `:base_uri` and `:loader` options.

## Optional dependencies

Add only the dependencies your application needs alongside `:jsonschex` in `mix.exs`:

| Dependency | When to add it |
| --- | --- |
| `{:jason, "~> 1.4"}` | JSON decoding and encoding on Elixir versions before 1.18. Elixir 1.18+ uses the built-in `JSON` module. |
| `{:decimal, "~> 3.2"}` | High-precision `multipleOf` checks. Without it, native arithmetic can lose precision or overflow. |
| `{:idna, "~> 6.0 or ~> 7.1"}` | Internationalized domain names in `idn-hostname` and `idn-email` format checks. |

## Guides

See the `guide/` directory for detailed documentation:

- [Loader and remote `$ref` handling](guide/loader.md)
- [Dialect and `$vocabulary` behavior](guide/dialect_and_vocabulary.md)
- [Feature matrix (Draft 2020-12 support)](guide/feature_matrix.md)
- [Content and format assertion options](guide/content_and_format.md)
- [Regex validation and execution limits](guide/regex_validation.md)
- [Test suite coverage](guide/test_suite.md)

## Development

Clone the repository, initialize its pinned test fixtures, and run the tests:

```sh
git clone https://github.com/xinz/jsonschex.git
cd jsonschex
git submodule update --init --recursive
mix deps.get
mix test
```

The submodules provide the [official JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
and [RFC 6570 URI Template tests](https://github.com/uri-templates/uritemplate-test).
To deliberately update the official fixtures to their upstream revision:

```sh
git submodule update --remote -- test/fixtures/JSON-Schema-Test-Suite
git submodule status -- test/fixtures/JSON-Schema-Test-Suite
```

## Test suite summary

`mix test` runs both official draft suites, including optional format and content
fixtures with their assertion options enabled. The `optional/cross-draft` fixtures
are excluded: automatic cross-draft resolution is outside the current support scope.

Run just the official suites with:

```sh
mix test test/official_jsts_draft7_test.exs test/official_jsts_test.exs
```

See the [test coverage guide](guide/test_suite.md) for fixture paths, exclusions,
and focused debugging.

## Benchmark

More benchmark details can be found in the [`bench/`](https://github.com/xinz/jsonschex/tree/main/bench) directory.

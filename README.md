# JSONSchex

[![hex.pm version](https://img.shields.io/hexpm/v/jsonschex.svg?v=1)](https://hex.pm/packages/jsonschex)
[![Draft 2020-12](https://img.shields.io/endpoint?url=https%3A%2F%2Fbowtie.report%2Fbadges%2Felixir-jsonschex%2Fcompliance%2Fdraft2020-12.json)](https://bowtie.report/#/implementations/elixir-jsonschex)

JSONSchex supports [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12) and [Draft 7](https://json-schema.org/draft-07) for Elixir, with a design that focuses on practical performance. Draft 2020-12 is the default when no recognized root `$schema` or explicit `:draft` selects another draft.

## Features

- Supports Draft 7 semantics alongside Draft 2020-12 core, applicator, validation, unevaluated, and content vocabularies.
- Passes the included [official JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) fixtures for both drafts.
- Designed for performance and simplicity: compile a schema once into an executable `Schema` struct, then validate data repeatedly with no repeated parsing overhead.
- Supports an Elixir/Plug OpenAPI v3 server implementation and code generator with JSON Schema validation, see [Oasis](https://hex.pm/packages/oasis).

## Installation

```elixir
def deps do
  [
    {:jsonschex, "~> 0.9"}
  ]
end
```

## Quick start

```elixir
{:ok, compiled} =
  JSONSchex.compile(%{
    "type" => "array",
    "items" => %{"type" => "integer"}
  })

:ok = JSONSchex.validate(compiled, [1, 2, 3])
{:error, errors} = JSONSchex.validate(compiled, [1, "bad"])
```

## Draft selection

A recognized root `$schema` selects Draft 7 or Draft 2020-12 automatically:

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

The accepted `:draft` values are `"draft7"` and `"draft2020_12"`. A recognized
`$schema` and an explicit `:draft` must agree; otherwise compilation returns
`:draft_conflict`. Without either, Draft 2020-12 is the default.
`JSONSchex.Schema.compile!/2` follows the same policy and raises `CompileError`
on conflict. See the [dialect guide](guide/dialect_and_vocabulary.md) for details.

## Compile-time schemas

If your schema is a static literal known during compilation, JSONSchex supports
both an explicit macro API and a compact sigil form.

- Prefer `JSONSchex.Schema.compile!/2` when you want the most explicit API.
- Prefer `~X` when you want a compact module-attribute literal.

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

You can also use the `~X` sigil from `JSONSchex.Sigil` for Elixir map literals representing JSON Schemas:

```elixir
defmodule MyApp.NumberSchema do
  use JSONSchex

  @schema ~X|%{"type" => "integer", "minimum" => 10}|

  def schema, do: @schema
end
```

If you prefer the explicit form, you can import the sigil directly:

```elixir
defmodule MyApp.NumberSchema do
  import JSONSchex.Sigil, only: [sigil_X: 2]

  @schema ~X|%{"type" => "integer", "minimum" => 10}|

  def schema, do: @schema
end
```

`use JSONSchex` imports the `~X` sigil for you. `~X` parses Elixir code, not JSON. It currently supports these modifiers:

- `f` — `format_assertion: true`
- `c` — `content_assertion: true`

For compile-time embeddable options such as `:loader`, prefer remote
captures like `&MyLoader.fetch/1` over anonymous functions.

`~X` is preferred over `~J` to avoid the common sigil-name conflict with Jason.

## How it works

JSONSchex follows a **two-phase approach** for optimal performance:

1. **Compile** — Parse and optimize a JSON Schema into an executable `Schema` struct. During compilation:
   - Schema resources and eligible local fragment references are registered according to the selected draft
   - Keywords are compiled into serializable rule descriptors consumed by the validator
   - Remote `$ref` schemas can be loaded via a configured loader
   - Canonical Draft 7 and Draft 2020-12 meta-schemas are embedded; built-in references need no loader
   - Draft 2020-12 vocabularies are resolved from `$schema` and `$vocabulary`; Draft 7 uses its own keyword set

2. **Validate** — Execute the compiled schema against data. During validation:
   - Rules are executed in order, accumulating errors
   - Evaluated property/item keys are tracked for `unevaluatedProperties` and `unevaluatedItems`
   - `$ref` is resolved in both drafts; `$dynamicRef` is supported in Draft 2020-12
   - All errors are collected and returned together

This design allows you to compile a schema once and reuse it for multiple validations, significantly improving performance for repeated validations.

### Error reporting

When validation fails, `JSONSchex.validate/2` returns `{:error, errors}` where `errors` is a list of `JSONSchex.Types.Error` structs.

JSONSchex uses a **lazy error reporting** model for performance. Errors contain raw data (path lists, context maps) rather than pre-formatted strings. You can use `JSONSchex.format_error/1` to generate human-readable messages when needed.

Each error contains:

- `path` — List of path segments indicating where the error occurred (e.g., `["users", 0, "email"]`)
- `rule` — Atom identifying the failed validation rule (e.g., `:type`, `:minimum`)
- `context` — Map containing details about the failure (e.g., `%JSONSchex.Types.ErrorContext{contrast: "integer", input: "string"}`)
- `value` — The input value that caused the error

**Example:**

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "email" => %{"type" => "string", "format" => "email"},
    "age" => %{"type" => "integer", "minimum" => 0}
  },
  "required" => ["email"]
}

{:ok, compiled} = JSONSchex.compile(schema, format_assertion: true)

{:error, errors} = JSONSchex.validate(compiled, %{"age" => -5})

# Inspect raw errors
# [
#   %JSONSchex.Types.Error{
#     path: ["age"],
#     rule: :minimum,
#     context: %JSONSchex.Types.ErrorContext{
#       contrast: 0,
#       input: -5,
#       error_detail: nil
#     },
#     value: -5
#   },
#   %JSONSchex.Types.Error{
#     path: [],
#     rule: :required,
#     context: %JSONSchex.Types.ErrorContext{
#       contrast: ["email"],
#       input: nil,
#       error_detail: nil
#     },
#     value: nil
#   }
# ]

# Format errors for display
Enum.map(errors, &JSONSchex.format_error/1)
# [
#   "At /age: Value -5 is less than minimum 0",
#   "Missing required properties: email"
# ]
```

### Compile options

`JSONSchex.compile/2` accepts an optional keyword list with the following options:

- `:loader` — Function for loading remote `$ref` schemas (see [Loader guide](guide/loader.md))
- `:base_uri` — Starting base URI for resolving relative references (see [Loader guide](guide/loader.md))
- `:draft` — `"draft7"` or `"draft2020_12"` (as strings). A recognized root `$schema` selects the draft automatically; a conflicting option returns `:draft_conflict`. Without either, Draft 2020-12 is the default. `JSONSchex.Schema.compile!/2` uses the same policy, raising a compile error on conflict.
- `:format_assertion` — Explicitly enable `format` validation (default: `false`). The canonical Draft 2020-12 dialect is annotation-only by default; an active format-assertion vocabulary also enables validation (see [Content and format guide](guide/content_and_format.md)).
- `:content_assertion` — Enable strict content vocabulary validation (default: `false`, see [Content and format guide](guide/content_and_format.md))

`JSONSchex.compile_fragment/2` accepts a containing document plus an `:entry` JSON Pointer or URI reference. Draft detection uses the containing document's root `$schema`; pass `:draft` when that declaration is absent or unrecognized. Use `:base_uri` when a document-local entry contains relative external references. If `:entry` includes a base URI/path and `:base_uri` is omitted, that base is used for relative reference resolution. `JSONSchex.bundle_fragment/2` uses the same entry options and returns a raw schema with reachable external resources mounted under `$defs`. Generated `$defs` keys beginning with `jsonschex_` are collision-safe internal storage names, not stable reference paths; resources retain their identity through `$id` and anchors. Loader wrapper responses use atom metadata keys only: `{:ok, %{document: schema, base_uri: base_uri}}`.

`JSONSchex.Ref.resolve_selected/2` provides selector-driven `$ref` resolution for JSON-like documents. It resolves only `$ref` nodes selected by a caller-provided `:select` function, replaces selected refs with their target values, preserves unselected refs, continues walking their sibling values, and rebases preserved descendant refs when external content is inlined. It uses the same `:base_uri` / `:loader` mechanics for external resources.

## Optional Dependencies

JSONSchex has these optional dependencies that enable additional functionality:

- **`jason` (~> 1.4)**: Required for JSON decoding only when using Elixir earlier than 1.18.

- **`decimal` (~> 3.2)**: Required for arbitrary precision decimal validation in the `multipleOf` keyword. Without this dependency, `multipleOf` validation may have precision issues with very large or very small decimal numbers.

- **`idna` (~> 6.0 or ~> 7.1)**: Required for internationalized domain name (IDN) support. Enables validation of `idn-hostname` and `idn-email` formats. Without this dependency, these formats may not be validated in expected ways.

To include these dependencies, add them to your `mix.exs`:

```elixir
def deps do
  [
    {:jason, "~> 1.4"},
    {:decimal, "~> 3.2"},
    {:idna, "~> 6.0 or ~> 7.1"}
  ]
end
```

## Guides

See the `guide/` directory for detailed documentation:

- [Loader and remote `$ref` handling](guide/loader.md)
- [Dialect and `$vocabulary` behavior](guide/dialect_and_vocabulary.md)
- [Feature matrix (Draft 2020-12 support)](guide/feature_matrix.md)
- [Content and format assertion options](guide/content_and_format.md)
- [Test suite coverage](guide/test_suite.md)

## Development

Clone the repository and initialize the git submodules that provide the local test fixtures:

```sh
git clone https://github.com/xinz/jsonschex.git
cd jsonschex
git submodule update --init --recursive
```

Or update git remote submodules in the root directory of this repo:

```sh
git submodule update --remote -- test/fixtures/JSON-Schema-Test-Suite && git submodule status -- test/fixtures/JSON-Schema-Test-Suite
```

This pulls two external test suites into `test/fixtures/`:

- **[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)** — The official language-agnostic test suite for JSON Schema (Draft 7 and Draft 2020-12).
- **[uritemplate-test](https://github.com/uri-templates/uritemplate-test)** — Test cases for RFC 6570 URI Template validation.

Then fetch dependencies and run the tests:

```sh
mix deps.get
mix test
```

## Test suite summary

JSONSchex runs the included JSON Schema Test Suite fixtures for Draft 7 and Draft 2020-12 with all tests passing.

- Default suite paths:
  - `test/fixtures/JSON-Schema-Test-Suite/tests/draft7`
  - `test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12`
- Exclusions:
  - `optional/cross-draft`

Debug test files can selectively run single suite files for focused investigation.

## Benchmark

More benchmark details can be found in the [`bench/`](https://github.com/xinz/jsonschex/tree/main/bench) directory.

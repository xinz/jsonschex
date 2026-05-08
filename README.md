# JSONSchex

[![hex.pm version](https://img.shields.io/hexpm/v/jsonschex.svg?v=1)](https://hex.pm/packages/jsonschex)

JSONSchex is an implementation of [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12) for Elixir, with a design that focuses on practical performance.

## Features

- Implements JSON Schema Draft 2020-12 in full, including all core, applicator, validation, unevaluated, and content vocabulary keywords.
- Passes 100% of the [official JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) for Draft 2020-12.
- Designed for performance and simplicity: compile a schema once into an executable `Schema` struct, then validate data repeatedly with no repeated parsing overhead.

## Installation

```elixir
def deps do
  [
    {:jsonschex, "~> 0.5"}
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

## Compile-time schemas

If your schema is a static literal known during compilation, you can embed the
compiled schema directly in your module with `JSONSchex.Schema.compile!/2`:

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

The syntax `use JSONSchex` imports `~X` sigil, and `~X` parses Elixir code, not JSON format. It currently supports these modifiers:

- `f` — `format_assertion: true`
- `c` — `content_assertion: true`

For compile-time embeddable options such as `:external_loader`, prefer remote
captures like `&MyLoader.fetch/1` over anonymous functions.

`~X` is preferred over `~J` to avoid the common sigil-name conflict with Jason.

## How it works

JSONSchex follows a **two-phase approach** for optimal performance:

1. **Compile** — Parse and optimize a JSON Schema into an executable `Schema` struct. During compilation:
   - All `$id`, `$anchor`, and discovered local fragment references are scanned and registered
   - Keywords are compiled into serializable rule descriptors consumed by the validator
   - Remote `$ref` schemas can be loaded via an external loader
   - The built-in Draft 2020-12 dialect is recognized without requiring a remote meta-schema load
   - Vocabularies are resolved based on `$schema` and `$vocabulary` declarations

2. **Validate** — Execute the compiled schema against data. During validation:
   - Rules are executed in order, accumulating errors
   - Evaluated property/item keys are tracked for `unevaluatedProperties` and `unevaluatedItems`
   - References (`$ref`, `$dynamicRef`) are resolved from the compiled registry
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

- `:external_loader` — Function for loading remote `$ref` schemas (see [Loader guide](guide/loader.md))
- `:base_uri` — Starting base URI for resolving relative references (see [Loader guide](guide/loader.md))
- `:format_assertion` — Enable strict `format` validation (default: `false`; the built-in Draft 2020-12 dialect keeps `format` annotation-only unless explicitly enabled, see [Content and format guide](guide/content_and_format.md))
- `:content_assertion` — Enable strict content vocabulary validation (default: `false`, see [Content and format guide](guide/content_and_format.md))

## Optional Dependencies

JSONSchex has these optional dependencies that enable additional functionality:

- **`jason` (~> 1.4)**: Required for JSON decoding only when using Elixir earlier than 1.18.

- **`decimal` (~> 2.0)**: Required for arbitrary precision decimal validation in the `multipleOf` keyword. Without this dependency, `multipleOf` validation may have precision issues with very large or very small decimal numbers.

- **`idna` (~> 6.0 or ~> 7.1)**: Required for internationalized domain name (IDN) support. Enables validation of `idn-hostname` and `idn-email` formats. Without this dependency, these formats may not be validated in expected ways.

To include these dependencies, add them to your `mix.exs`:

```elixir
def deps do
  [
    {:jsonschex, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:decimal, "~> 2.0"},
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

- **[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)** — The official language-agnostic test suite for JSON Schema (Draft 2020-12).
- **[uritemplate-test](https://github.com/uri-templates/uritemplate-test)** — Test cases for RFC 6570 URI Template validation.

Then fetch dependencies and run the tests:

```sh
mix deps.get
mix test
```

## Test suite summary

JSONSchex runs the JSON Schema Test Suite for Draft 2020-12 with all tests passing.

- Default suite path:
  - `test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12`
- Exclusions:
  - `optional/cross-draft`

Debug test files can selectively run single suite files for focused investigation.

## Benchmark

More benchmark details can be found in the [`bench/`](https://github.com/xinz/jsonschex/tree/main/bench) directory.

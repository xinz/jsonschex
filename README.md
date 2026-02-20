# JSONSchex

[![hex.pm version](https://img.shields.io/hexpm/v/jsonschex.svg?v=1)](https://hex.pm/packages/jsonschex)

JSONSchex is a [JSON Schema specification](https://json-schema.org/specification) implementation in Elixir. It fully supports [Draft 2020-12](https://json-schema.org/draft/2020-12) and latest specifications, and its design focuses on practical performance.

## Features

- Implements [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12) in full, including all core, applicator, validation, unevaluated, and content vocabulary keywords
- Passes 100% of the [official JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) for Draft 2020-12
- Designed for performance and simplicity: compile a schema once into an executable `Schema` struct, then validate data repeatedly with no repeated parsing overhead

## Installation

```elixir
def deps do
  [
    {:jsonschex, "~> 0.1.0"}
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

## How it works

JSONSchex follows a **two-phase approach** for optimal performance:

1. **Compile** — Parse and optimize a JSON Schema into an executable `Schema` struct. During compilation:
   - All `$id` and anchor definitions are scanned and registered
   - Keywords are converted into executable validation functions
   - Remote `$ref` schemas can be loaded via an external loader
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
- `context` — Map containing details about the failure (e.g., `%{expected: "integer", actual: "string"}`)
- `message` — Optional string (often `nil`), populated only if explicitly set

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
#     path: [],
#     rule: :required,
#     context: %{missing: ["email"]}
#   },
#   %JSONSchex.Types.Error{
#     path: ["age"],
#     rule: :minimum,
#     context: %{minimum: 0, actual: -5}
#   }
# ]

# Format errors for display
Enum.map(errors, &JSONSchex.format_error/1)
# [
#   "Missing required properties: email",
#   "At /age: Value -5 is less than minimum 0"
# ]
```

### Compile options

`JSONSchex.compile/2` accepts an optional keyword list with the following options:

- `:external_loader` — Function for loading remote `$ref` schemas (see [Loader guide](guide/loader.md))
- `:base_uri` — Starting base URI for resolving relative references (see [Loader guide](guide/loader.md))
- `:format_assertion` — Enable strict `format` validation (default: `false`, see [Content and format guide](guide/content_and_format.md))
- `:content_assertion` — Enable strict content vocabulary validation (default: `false`, see [Content and format guide](guide/content_and_format.md))

## Optional Dependencies

JSONSchex has these optional dependencies that enable additional functionality:

- **`jason` (~> 1.0)**: Required for JSON decoding if using a version of Elixir is earlier than 1.18.

- **`decimal` (~> 2.0)**: Required for arbitrary precision decimal validation in the `multipleOf` keyword. Without this dependency, `multipleOf` validation may have precision issues with very large or very small decimal numbers.

- **`idna` (~> 6.0 or ~> 7.1)**: Required for internationalized domain name (IDN) support. Enables validation of `idn-hostname` and `idn-email` formats. Without this dependency, these formats may not be validated in expected ways.

To include these dependencies, add them to your `mix.exs`:

```elixir
def deps do
  [
    {:jsonschex, "~> 0.1.0"},
    {:jason, "~> 1.4"},
    {:decimal, "~> 2.0"},
    {:idna, "~> 6.0 or 7.1"}
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

This pulls two external test suites into `test/fixtures/`:

- **[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)** — The official language-agnostic test suite for JSON Schema (Draft 2020-12).
- **[uritemplate-test](https://github.com/uri-templates/uritemplate-test)** — Test cases for RFC 6570 URI Template validation.

Then fetch dependencies and run the tests:

```sh
mix deps.get
mix test
```

## Test suite summary

JSONSchex runs the JSON Schema Test Suite for Draft 2020-12, all tests passing.

- Default suite path:
  - `test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12`
- Exclusions:
  - `optional/cross-draft`

Debug test files can selectively run single suite files for focused investigation.

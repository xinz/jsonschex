# Test Suite Coverage Guide

This guide describes how JSONSchex runs the official JSON Schema Test Suites, what is included by default, and how to debug or customize coverage.

## Overview

JSONSchex includes the JSON Schema Test Suite fixtures and runs Draft 7 and Draft 2020-12 tests by default against the unified validation suite:

- `test/fixtures/JSON-Schema-Test-Suite/validation/tests`

Each test case in the unified suite specifies dialect applicability via `compatibility`, optional behavior via `tags` (`format-assertion` / `format-annotation`), and per-case remote documents via `externalSchemas`.

## Default exclusions

The following test sets are excluded by default:

- `proposals/` directory (volatile pre-release proposal tests targeting future releases)
- `optional/cross-draft` (cross-draft resolution is outside the current support scope)
- High-precision decimal suites in `optional/bignum` (`float comparison with high precision`, `float comparison with high precision on negative numbers`, `enum comparison with high precision`, `const comparison with high precision`, and `uniqueItems comparison with high precision`), because Elixir's `JSON`/`Jason` decoders parse JSON decimals into IEEE 754 64-bit floats before validation

Passing the included fixtures does not imply complete cross-draft support.

## Draft 7 status

The Draft 7 fixture suite passes `draft: "draft7"` and filters test cases with `compatibility` for Draft 7 (`7`). The Draft 2020-12 fixture suite passes `draft: "draft2020_12"` and filters test cases with `compatibility` for Draft 2020-12 (`2020`). When a fixture schema omits `$schema`, the runner injects the dialect's canonical `$schema` URI so built-in dialect defaults (such as annotation-only `format` in Draft 2020-12) match the specification.

Focused regressions live in `test/draft7_compatibility_test.exs`. The runner enables `format_assertion: true` for test cases tagged `format-assertion` and `content_assertion: true` for `optional/content.json`; `optional/cross-draft` remains excluded.

## How official test suites are run

JSONSchex uses a test runner that scans `test/fixtures/JSON-Schema-Test-Suite/validation/tests`, filters each test case by its `compatibility` constraint for the target draft, wires any per-case `externalSchemas` into the schema loader, and executes all eligible JSON files, excluding the paths and suites listed above.

The JSON Schema Test Suite is included as a Git submodule (see `.gitmodules` in the repository root).

You can run the full test suite with:

```bash
mix test
```

The suite runner is invoked in separate test files:

- `test/official_jsts_test.exs` for Draft 2020-12
- `test/official_jsts_draft7_test.exs` for Draft 7

## Running tests

### Run all tests

```bash
mix test
```

This executes the entire test suite, including Draft 7 and Draft 2020-12 (except exclusions).

### Run one draft's suite

```bash
mix test test/official_jsts_test.exs
mix test test/official_jsts_draft7_test.exs
```

### Run with verbose output

```bash
mix test --trace
```

This shows each test as it runs, which is helpful for identifying slow or problematic tests.

## Debugging a single suite file

There are debug test modules that can run a single suite file for focused investigations. These live in `test/debug_*.exs`.

### Example: Running a specific JSON test file

To debug a specific test case from the official suite:

1. **Identify the test file** you want to debug (e.g., `test/fixtures/JSON-Schema-Test-Suite/validation/tests/type.json`)

2. **Create or edit a debug test file** (e.g., `test/debug_type_test.exs`):

```elixir
defmodule JSONSchex.DebugTypeTest do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner

  # This macro generates an ExUnit test for each compatible case in the fixture.
  run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/type.json")
end
```

3. **Run just that test file**:

```bash
mix test test/debug_type_test.exs --trace
```

The single-file macro defaults to Draft 2020-12; pass `draft: "draft7"` as a second argument (`run_suite(path, draft: "draft7")`) to target Draft 7. On Elixir 1.19 or newer, you can also filter the existing official test module:

```bash
mix test test/official_jsts_draft7_test.exs --name-pattern 'JSTS: type -'
```

The `--name-pattern` option was introduced in Elixir 1.19. On older supported Elixir versions, run the complete Draft 7 module instead:

```bash
mix test test/official_jsts_draft7_test.exs --trace
```

### Example: Testing a single schema from a suite file

For even more focused debugging, you can extract a specific test case:

```elixir
defmodule JSONSchex.DebugSingleTest do
  use ExUnit.Case

  test "debug specific type test case" do
    schema = %{"type" => "integer"}
    assert {:ok, compiled} = JSONSchex.compile(schema)

    # Check acceptance and the specific rejection rule, not just any error.
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "not an integer")
  end
end
```

This is helpful for isolating regressions or investigating a failing test case.

### Using IEx for Interactive Debugging

You can also use IEx to interactively test schemas:

```bash
iex -S mix
```

Then in the IEx session:

```elixir
# Load a schema from a test file
{:ok, content} = File.read("test/fixtures/JSON-Schema-Test-Suite/validation/tests/type.json")
%{"tests" => tests} = JSONSchex.JSON.decode!(content)

# Get the first test group
[first_group | _] = tests
schema = first_group["schema"]

# Compile and test
{:ok, compiled} = JSONSchex.compile(schema)
JSONSchex.validate(compiled, 1)
JSONSchex.validate(compiled, "not a number")
```

## Notes on optional vocabularies

The runner explicitly enables `format_assertion: true` for test cases tagged `format-assertion` and `content_assertion: true` for `optional/content.json`. Application code must opt into content assertions separately. Format checks can also be enabled by an active Draft 2020-12 format-assertion vocabulary.

Draft 7 ignores `contentSchema`, including when content assertions are enabled. Its supported `contentEncoding` and `contentMediaType` checks still run. See the [content and format guide](content_and_format.md).

## Best practices

- Keep the default exclusions minimal and explicit.
- Use debug test files to isolate issues before changing global test coverage.
- When adding new keyword support, run the relevant subset of the suite first, then the full suite.
- Use `--trace` flag to see which tests are slow or hanging.
- Check the official test suite repository for updates: https://github.com/json-schema-org/JSON-Schema-Test-Suite

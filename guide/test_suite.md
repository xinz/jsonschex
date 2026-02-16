# Test Suite Coverage Guide

This guide describes how JSONSchex runs the official JSON Schema Test Suites, what is included by default, and how to debug or customize coverage.

## Overview

JSONSchex includes the JSON Schema Test Suite fixtures and runs Draft 2020-12 tests by default, all tests passing.

Default suite path:

- `test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12`

## Default exclusions

The following test sets are excluded by default:

- `optional/cross-draft`

These exclusions are configured in the test runner and are intended to avoid cross-draft scenarios that are outside the scope of Draft 2020-12.

## How official test suites are run

JSONSchex uses a test runner that scans the test suite directory and executes all eligible JSON files, excluding the paths listed above.

The JSON Schema Test Suite is included as a Git submodule (see `.gitmodules` in the repository root).

You can run the full test suite with:

```bash
mix test
```

The main suite runner is invoked in:

- `test/official_jsts_test.exs`

## Running tests

### Run all tests

```bash
mix test
```

This executes the entire test suite, including all Draft 2020-12 tests (except exclusions).

### Run a specific test file

```bash
mix test test/official_jsts_test.exs
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

1. **Identify the test file** you want to debug (e.g., `test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/type.json`)

2. **Create or edit a debug test file** (e.g., `test/debug_type_test.exs`):

```elixir
defmodule JSONSchex.DebugTypeTest do
  use ExUnit.Case

  alias JSONSchex.SuiteRunner

  test "debug type validation" do
    # Run a specific test file from the suite
    suite_file = "test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/type.json"
    
    result = SuiteRunner.run_suite(suite_file)
    
    # This will show detailed output for debugging
    assert result.passed == result.total
  end
end
```

3. **Run just that test file**:

```bash
mix test test/debug_type_test.exs --trace
```

### Example: Testing a single schema from a suite file

For even more focused debugging, you can extract a specific test case:

```elixir
defmodule JSONSchex.DebugSingleTest do
  use ExUnit.Case

  test "debug specific type test case" do
    # Specific schema from the type.json test file
    schema = %{"type" => "integer"}
    
    {:ok, compiled} = JSONSchex.compile(schema)
    
    # Test valid data
    assert :ok = JSONSchex.validate(compiled, 1)
    
    # Test invalid data
    assert {:error, errors} = JSONSchex.validate(compiled, "not an integer")
    assert length(errors) > 0
    [error] = errors
    assert error.rule == :type
    
    IO.inspect(error, label: "Validation error")
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
{:ok, content} = File.read("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/type.json")
{:ok, tests} = Jason.decode(content)

# Get the first test group
[first_group | _] = tests
schema = first_group["schema"]

# Compile and test
{:ok, compiled} = JSONSchex.compile(schema)
JSONSchex.validate(compiled, 1)
JSONSchex.validate(compiled, "not a number")
```

## Notes on optional vocabularies

Some tests are gated by vocabularies or compile-time options:

- `format` assertions require `format_assertion: true`
- `content*` assertions require `content_assertion: true`

If these options are not enabled, tests expecting assertion behavior may not apply.

## Best practices

- Keep the default exclusions minimal and explicit.
- Use debug test files to isolate issues before changing global test coverage.
- When adding new keyword support, run the relevant subset of the suite first, then the full suite.
- Use `--trace` flag to see which tests are slow or hanging.
- Check the official test suite repository for updates: https://github.com/json-schema-org/JSON-Schema-Test-Suite

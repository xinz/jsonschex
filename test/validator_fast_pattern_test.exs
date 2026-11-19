defmodule JSONSchex.Validator.FastPatternTest do
  use ExUnit.Case, async: true

  doctest JSONSchex.Guards

  require JSONSchex.Schema
  alias JSONSchex.Compiler.ECMARegex
  alias JSONSchex.Validator.Pattern

  @fast_patterns [
    {"exact literal", "^hello_world$", {:exact, "hello_world"}},
    {"exact empty", "^$", {:exact, ""}},
    {"prefix literal", "^x-api-", {:prefix, "x-api-"}},
    {"prefix escaped dot", "^v1\\.0\\.", {:prefix, "v1.0."}},
    {"suffix literal", "_id$", {:suffix, "_id"}},
    {"suffix escaped dot", "\\.json$", {:suffix, ".json"}},
    {"plain substring", "status_ok", {:contains, "status_ok"}},
    {"empty pattern", "", {:contains, ""}},
    {"digits plus", "^\\d+$", {:ascii_class, :digit, 1, :infinity}},
    {"digits exact", "^[0-9]{4}$", {:ascii_class, :digit, 4, 4}},
    {"digits range", "^\\d{2,5}$", {:ascii_class, :digit, 2, 5}},
    {"digits min", "^[0-9]{3,}$", {:ascii_class, :digit, 3, :infinity}},
    {"hex fixed", "^[0-9a-fA-F]{8}$", {:ascii_class, :hex, 8, 8}},
    {"word star", "^\\w*$", {:ascii_class, :word, 0, :infinity}}
  ]

  @fallback_patterns [
    "^[^a-z]+$",
    "^(foo|bar)$",
    "^[a-z]+\\d+$",
    "^a.b$",
    "^\\s+$",
    "^[\\p{L}]+$",
    "^a?b$"
  ]

  test "recognizes supported ASCII fast-path patterns" do
    for {label, source, expected} <- @fast_patterns do
      assert Pattern.compile_fast(source) == expected,
             "Expected #{label} (#{inspect(source)}) to compile to #{inspect(expected)}"
    end

    assert {:ascii_class, table, 1, :infinity} = Pattern.compile_fast("^[a-z0-9_-]+$")
    assert is_tuple(table) and tuple_size(table) == 128
  end

  test "falls back to nil for complex or Unicode-sensitive patterns" do
    for source <- @fallback_patterns do
      assert Pattern.compile_fast(source) == nil,
             "Expected #{inspect(source)} to fall back to Regex"
    end
  end

  test "fast-path validation matches ECMA-262 Regex semantics on all edge cases" do
    patterns =
      Enum.map(@fast_patterns, &elem(&1, 1)) ++
        ["^[a-z0-9_-]+$", "^[A-Z]{2,3}$", "^[a-z]?$"]

    subjects = [
      "",
      "a",
      "A",
      "US",
      "USA",
      "USAA",
      "hello_world",
      "hello_world\n",
      "\nhello_world",
      "x-api-key",
      "my-x-api-key",
      "v1.0.2",
      "v1X0X2",
      "user_id",
      "user_id\n",
      "config.json",
      "configXjson",
      "foo status_ok bar",
      "0",
      "1234",
      "12345",
      "123456",
      "1234\n",
      "deadBEEF",
      "deadBEE!",
      "my-service_v2",
      "my-service/v2",
      "café",
      "日本語",
      "😀"
    ]

    for pattern <- patterns do
      {:ok, regex} = ECMARegex.compile(pattern)
      {:ok, compiled} = JSONSchex.compile(%{"type" => "string", "pattern" => pattern})

      for subject <- subjects do
        expected = Pattern.match?(regex, subject, [])
        actual = JSONSchex.validate(compiled, subject) == :ok

        assert actual == expected,
               "Mismatch for pattern #{inspect(pattern)} on #{inspect(subject)}: expected=#{expected}, actual=#{actual}"
      end
    end
  end

  test "compiled schema with fast-path pattern preserves Regex error contrast" do
    {:ok, compiled} = JSONSchex.compile(%{"type" => "string", "pattern" => "^[a-z0-9_-]+$"})
    assert :ok = JSONSchex.validate(compiled, "valid-slug_123")
    assert {:error, [error]} = JSONSchex.validate(compiled, "INVALID!")
    assert error.rule == :pattern
    assert match?(%Regex{}, error.context.contrast)
  end

  test "fast-path pattern schemas are embeddable via JSONSchex.Schema.compile!/1" do
    embedded = JSONSchex.Schema.compile!(%{"type" => "string", "pattern" => "^[a-z0-9_-]+$"})
    assert :ok = JSONSchex.validate(embedded, "embedded-ok_1")
    assert {:error, [%{rule: :pattern}]} = JSONSchex.validate(embedded, "Bad!")
  end
end

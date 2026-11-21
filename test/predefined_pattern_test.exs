defmodule JSONSchex.PredefinedPatternTest do
  use ExUnit.Case, async: true

  doctest JSONSchex.Guards
  doctest JSONSchex.PredefinedPattern

  require JSONSchex.Schema
  alias JSONSchex.Compiler.ECMARegex
  alias JSONSchex.PredefinedPattern
  alias JSONSchex.Validator.Pattern

  @predefined_patterns [
    {"exact literal", "^hello_world$", {:exact, "hello_world"}},
    {"exact empty", "^$", {:exact, ""}},
    {"prefix literal", "^x-api-", {:prefix, "x-api-"}},
    {"prefix escaped dot", "^v1\\.0\\.", {:prefix, "v1.0."}},
    {"suffix literal", "_id$", {:suffix, "_id"}},
    {"suffix escaped dot", "\\.json$", {:suffix, ".json"}},
    {"plain substring", "status_ok", {:contains, "status_ok"}},
    {"empty pattern", "", {:contains, ""}},
    {"digits plus", "^\\d+$", {:ascii_class, :digit, 1, :infinity}},
    {"bracketed digits", ~S|^[\d]+$|, {:ascii_class, :digit, 1, :infinity}},
    {"digits exact", "^[0-9]{4}$", {:ascii_class, :digit, 4, 4}},
    {"digits range", "^\\d{2,5}$", {:ascii_class, :digit, 2, 5}},
    {"digits min", "^[0-9]{3,}$", {:ascii_class, :digit, 3, :infinity}},
    {"hex fixed", "^[0-9a-fA-F]{8}$", {:ascii_class, :hex, 8, 8}},
    {"word star", "^\\w*$", {:ascii_class, :word, 0, :infinity}},
    {"bracketed word", ~S|^[\w]+$|, {:ascii_class, :word, 1, :infinity}},
    {"explicit word", "^[A-Z_0-9a-z]+$", {:ascii_class, :word, 1, :infinity}}
  ]

  @escaped_range %{"pattern" => ~S|^[\.-z]+$|}
  JSONSchex.Schema.defvalidator :escaped_range, @escaped_range

  @fallback_patterns [
    "^[^a-z]+$",
    "^(foo|bar)$",
    "^[a-z]+\\d+$",
    "^a.b$",
    "^\\s+$",
    "^[\\p{L}]+$",
    "^a?b$"
  ]

  test "recognizes predefined ASCII pattern shapes" do
    for {label, source, expected} <- @predefined_patterns do
      assert PredefinedPattern.compile(source) == expected,
             "Expected #{label} (#{inspect(source)}) to compile to #{inspect(expected)}"
    end

    assert {:ascii_class, table, 1, :infinity} = PredefinedPattern.compile("^[a-z0-9_-]+$")
    assert is_tuple(table) and tuple_size(table) == 128
  end

  test "falls back to nil for complex or Unicode-sensitive patterns" do
    for source <- @fallback_patterns do
      assert PredefinedPattern.compile(source) == nil
      assert {:ok, %{rules: [%{params: params}]}} = JSONSchex.compile(%{"pattern" => source})
      assert %Regex{} = params.regex
      refute Map.has_key?(params, :matcher)
    end
  end

  test "predefined matchers agree with the compiled regex" do
    patterns =
      Enum.map(@predefined_patterns, &elem(&1, 1)) ++
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
      {:ok, %{rules: [%{params: %{matcher: matcher}}]} = compiled} = JSONSchex.compile(%{"pattern" => pattern})

      for subject <- subjects do
        expected = Pattern.match?(regex, subject, [])
        assert PredefinedPattern.match?(matcher, subject) == expected
        assert JSONSchex.valid?(compiled, subject) == expected
        actual = JSONSchex.validate(compiled, subject) == :ok

        assert actual == expected,
               "Mismatch for pattern #{inspect(pattern)} on #{inspect(subject)}: expected=#{expected}, actual=#{actual}"
      end
    end
  end

  test "a range consumes class atoms, including escaped endpoints" do
    for source <- [@escaped_range["pattern"], ~S|^[A-\]]$|, ~S|^[\+-\.]$|, ~S|^[-a-c\-]$|] do
      {:ok, regex} = ECMARegex.compile(source)
      {:ok, schema} = JSONSchex.compile(%{"pattern" => source})

      for byte <- 32..126 do
        expected = Pattern.match?(regex, <<byte>>, [])
        assert (JSONSchex.validate(schema, <<byte>>) == :ok) == expected
        assert JSONSchex.valid?(schema, <<byte>>) == expected
      end
    end

    assert escaped_range?("Ada")
    assert :ok = escaped_range("Ada")
    refute escaped_range?("-")
    assert {:error, [%{rule: :pattern}]} = escaped_range("-")
    assert PredefinedPattern.compile(~S|^[\d-z]$|) == nil
    assert PredefinedPattern.compile(~S|^[A-\w]$|) == nil
  end

  test "compiled schema with a predefined pattern preserves Regex error contrast" do
    {:ok, compiled} = JSONSchex.compile(%{"type" => "string", "pattern" => "^[a-z0-9_-]+$"})
    assert :ok = JSONSchex.validate(compiled, "valid-slug_123")
    assert {:error, [error]} = JSONSchex.validate(compiled, "INVALID!")
    assert error.rule == :pattern
    assert match?(%Regex{}, error.context.contrast)
  end

  test "predefined pattern schemas are embeddable via JSONSchex.Schema.compile!/1" do
    embedded = JSONSchex.Schema.compile!(%{"type" => "string", "pattern" => "^[a-z0-9_-]+$"})
    assert :ok = JSONSchex.validate(embedded, "embedded-ok_1")
    assert {:error, [%{rule: :pattern}]} = JSONSchex.validate(embedded, "Bad!")
  end
end

defmodule JSONSchex.Test.CompilerErrorTest do
  use ExUnit.Case
  alias JSONSchex.Types.CompileError

  describe "type keyword errors" do
    test "rejects an unknown type string" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"type" => "1"})
      assert error.error == :invalid_keyword_value
      assert error.path == ["type"]
      assert error.value == "1"
    end

    test "rejects an array containing unknown type strings" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"type" => ["string", "foo"]})
      assert error.error == :invalid_keyword_value
      assert error.path == ["type"]
      assert error.value == ["string", "foo"]
    end

    test "rejects a value that is neither a string nor an array" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"type" => 42})
      assert error.error == :invalid_keyword_value
      assert error.path == ["type"]
      assert error.value == 42
    end

    test "accepts all seven valid type strings" do
      for t <- ~w(string integer number boolean object array null) do
        assert {:ok, _} = JSONSchex.compile(%{"type" => t}),
               "expected compile to succeed for type=#{inspect(t)}"
      end
    end

    test "accepts an array of valid type strings" do
      assert {:ok, _} = JSONSchex.compile(%{"type" => ["string", "null"]})
    end
  end

  describe "numeric keyword errors (minimum / maximum / exclusiveMinimum / exclusiveMaximum)" do
    test "rejects a string value for minimum" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"minimum" => "five"})
      assert error.error == :invalid_keyword_value
      assert error.path == ["minimum"]
      assert error.value == "five"
    end

    test "rejects nil for maximum" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"maximum" => nil})
      assert error.error == :invalid_keyword_value
      assert error.path == ["maximum"]
    end

    test "rejects a list for exclusiveMinimum" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"exclusiveMinimum" => []})
      assert error.error == :invalid_keyword_value
      assert error.path == ["exclusiveMinimum"]
    end

    test "rejects a string for exclusiveMaximum" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"exclusiveMaximum" => "3"})
      assert error.error == :invalid_keyword_value
      assert error.path == ["exclusiveMaximum"]
    end

    test "accepts a valid number for each numeric keyword" do
      for kw <- ~w(minimum maximum exclusiveMinimum exclusiveMaximum) do
        assert {:ok, _} = JSONSchex.compile(%{kw => 5}),
               "expected compile to succeed for #{kw}=5"

        assert {:ok, _} = JSONSchex.compile(%{kw => -1.5}),
               "expected compile to succeed for #{kw}=-1.5"
      end
    end
  end

  describe "multipleOf keyword errors" do
    test "rejects zero" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"multipleOf" => 0})
      assert error.error == :invalid_keyword_value
      assert error.path == ["multipleOf"]
      assert error.value == 0
    end

    test "rejects a negative number" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"multipleOf" => -1})
      assert error.error == :invalid_keyword_value
      assert error.path == ["multipleOf"]
      assert error.value == -1
    end

    test "rejects a non-number string" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"multipleOf" => "2"})
      assert error.error == :invalid_keyword_value
      assert error.path == ["multipleOf"]
    end

    test "accepts a strictly positive integer" do
      assert {:ok, _} = JSONSchex.compile(%{"multipleOf" => 3})
    end

    test "accepts a strictly positive float" do
      assert {:ok, _} = JSONSchex.compile(%{"multipleOf" => 0.5})
    end
  end

  describe "non-negative integer keyword errors" do
    @non_neg_int_keywords ~w(minLength maxLength minProperties maxProperties minItems maxItems)

    test "rejects a negative integer for each keyword" do
      for kw <- @non_neg_int_keywords do
        assert {:error, %CompileError{} = error} = JSONSchex.compile(%{kw => -1}),
               "expected compile to fail for #{kw}=-1"

        assert error.error == :invalid_keyword_value
        assert error.path == [kw]
        assert error.value == -1
      end
    end

    test "rejects a fractional float for each keyword" do
      for kw <- @non_neg_int_keywords do
        assert {:error, %CompileError{} = error} = JSONSchex.compile(%{kw => 1.5}),
               "expected compile to fail for #{kw}=1.5"

        assert error.error == :invalid_keyword_value
        assert error.path == [kw]
        assert error.value == 1.5
      end
    end

    test "rejects a non-number string for each keyword" do
      for kw <- @non_neg_int_keywords do
        assert {:error, %CompileError{} = error} = JSONSchex.compile(%{kw => "two"}),
               "expected compile to fail for #{kw}=\"two\""

        assert error.error == :invalid_keyword_value
        assert error.path == [kw]
      end
    end

    test "accepts a non-negative integer for each keyword" do
      for kw <- @non_neg_int_keywords do
        assert {:ok, _} = JSONSchex.compile(%{kw => 0}),
               "expected compile to succeed for #{kw}=0"

        assert {:ok, _} = JSONSchex.compile(%{kw => 5}),
               "expected compile to succeed for #{kw}=5"
      end
    end

    test "accepts a whole-number float for each keyword (JSTS compatibility)" do
      # JSON has no integer/float distinction; parsers may return 2.0 for a
      # schema written as {"minLength": 2}.
      for kw <- @non_neg_int_keywords do
        assert {:ok, _} = JSONSchex.compile(%{kw => 2.0}),
               "expected compile to succeed for #{kw}=2.0"
      end
    end
  end

  describe "uniqueItems keyword errors" do
    test "rejects a string value" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"uniqueItems" => "yes"})
      assert error.error == :invalid_keyword_value
      assert error.path == ["uniqueItems"]
      assert error.value == "yes"
    end

    test "rejects an integer value" do
      assert {:error, %CompileError{} = error} = JSONSchex.compile(%{"uniqueItems" => 1})
      assert error.error == :invalid_keyword_value
      assert error.path == ["uniqueItems"]
    end

    test "accepts true and false" do
      assert {:ok, _} = JSONSchex.compile(%{"uniqueItems" => true})
      assert {:ok, _} = JSONSchex.compile(%{"uniqueItems" => false})
    end
  end

  describe "invalid_keyword_value errors nested in $defs" do
    test "path is prefixed with $defs key for an invalid type" do
      schema = %{"$defs" => %{"item" => %{"type" => "bad"}}}
      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :invalid_keyword_value
      assert error.path == ["$defs", "item", "type"]
      assert error.value == "bad"
    end

    test "path is prefixed with $defs key for an invalid minimum" do
      schema = %{"$defs" => %{"item" => %{"minimum" => "x"}}}
      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :invalid_keyword_value
      assert error.path == ["$defs", "item", "minimum"]
      assert error.value == "x"
    end
  end

  describe "error formatting via format_error/1" do
    test "formats an invalid type string" do
      {:error, error} = JSONSchex.compile(%{"type" => "1"})
      msg = JSONSchex.format_error(error)
      assert msg =~ "Keyword 'type'"
      assert msg =~ ~s(got: "1")
    end

    test "formats an invalid type array" do
      {:error, error} = JSONSchex.compile(%{"type" => ["string", "foo"]})
      assert JSONSchex.format_error(error) =~
               "Keyword 'type' contains unknown type(s): foo"
    end

    test "formats a wrong value type for type keyword" do
      {:error, error} = JSONSchex.compile(%{"type" => 42})
      assert JSONSchex.format_error(error) =~ "Keyword 'type'"
      assert JSONSchex.format_error(error) =~ "got: 42"
    end

    test "formats a non-number minimum" do
      {:error, error} = JSONSchex.compile(%{"minimum" => "five"})
      assert JSONSchex.format_error(error) ==
               ~s(Keyword 'minimum' must be a number, got: "five")
    end

    test "formats a non-positive multipleOf" do
      {:error, error} = JSONSchex.compile(%{"multipleOf" => -1})
      assert JSONSchex.format_error(error) ==
               "Keyword 'multipleOf' must be a strictly positive number, got: -1"
    end

    test "formats a negative minLength" do
      {:error, error} = JSONSchex.compile(%{"minLength" => -1})
      assert JSONSchex.format_error(error) ==
               "Keyword 'minLength' must be a non-negative integer, got: -1"
    end

    test "formats a non-boolean uniqueItems" do
      {:error, error} = JSONSchex.compile(%{"uniqueItems" => "yes"})
      assert JSONSchex.format_error(error) ==
               ~s(Keyword 'uniqueItems' must be a boolean, got: "yes")
    end
  end

  describe "String.Chars protocol for CompileError" do
    test "to_string/1 delegates to format_error/1" do
      {:error, error} = JSONSchex.compile(%{"type" => "1"})
      assert to_string(error) == JSONSchex.format_error(error)
    end

    test "string interpolation works for CompileError" do
      {:error, error} = JSONSchex.compile(%{"minimum" => "bad"})
      assert "#{error}" == JSONSchex.format_error(error)
    end
  end

  describe "Regex compilation errors" do
    test "returns structured error for invalid pattern" do
      schema = %{"pattern" => "["}
      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :invalid_regex
      assert error.path == ["pattern"]
      assert List.starts_with?(error.message, ~c"missing terminating ]") == true
    end

    test "returns structured error for invalid patternProperties regex" do
      schema = %{
        "patternProperties" => %{
          "[" => %{"type" => "string"}
        }
      }
      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :invalid_regex
      assert error.path == ["patternProperties", "["]
      assert List.starts_with?(error.message, ~c"missing terminating ]") == true
    end

    test "returns structured error for invalid regex in additionalProperties dependency" do
      # additionalProperties needs to compile regexes from patternProperties to exclude them.
      schema = %{
        "patternProperties" => %{
          "[" => %{"type" => "string"}
        },
        "additionalProperties" => false
      }

      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :invalid_regex
      assert error.path == ["patternProperties", "["]
      assert List.starts_with?(error.message, ~c"missing terminating ]") == true
    end
  end

  describe "Vocabulary errors" do
    test "returns structured error for unsupported vocabulary in $vocabulary" do
      schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$vocabulary" => %{
          "https://json-schema.org/draft/2020-12/vocab/core" => true,
          "http://example.com/vocab/unknown" => true
        }
      }
      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :unsupported_vocabulary
      assert error.path == ["$vocabulary", "http://example.com/vocab/unknown"]
      assert error.value == true
    end
  end

  describe "Definitions errors" do
    test "returns nested structured error for error in $defs" do
      schema = %{
        "$defs" => %{
          "bad_def" => %{"pattern" => "["}
        }
      }
      assert {:error, %CompileError{} = error} = JSONSchex.compile(schema)
      assert error.error == :invalid_regex
      assert error.path == ["$defs", "bad_def", "pattern"]
      assert error.value == "["
      assert List.starts_with?(error.message, ~c"missing terminating ]") == true
    end
  end
end

defmodule JSONSchex.Test.CompilerErrorTest do
  use ExUnit.Case
  alias JSONSchex.Types.CompileError

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

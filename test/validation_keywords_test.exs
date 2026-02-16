defmodule JSONSchex.Test.ValidationKeywords do
  use ExUnit.Case

  test "validates required fields" do
    schema = %{"type" => "object", "required" => ["id"]}
    {:ok, compiled} = JSONSchex.compile(schema)

    assert :ok == JSONSchex.validate(compiled, %{"id" => 1})

    assert {:error, [error]} = JSONSchex.validate(compiled, %{"name" => "Gem"})
    assert error.rule == :required
    assert JSONSchex.format_error(error) =~ "Missing required properties: id"
  end

  test "validates enum values" do
    schema = %{"enum" => ["red", "blue"]}
    {:ok, compiled} = JSONSchex.compile(schema)

    assert :ok == JSONSchex.validate(compiled, "red")

    assert {:error, [error]} = JSONSchex.validate(compiled, "green")
    assert error.rule == :enum
  end

  test "validates pattern" do
    # Simple Email Regex
    schema = %{"type" => "string", "pattern" => "^\\S+@\\S+\\.\\S+$"}
    {:ok, compiled} = JSONSchex.compile(schema)

    assert :ok == JSONSchex.validate(compiled, "user@example.com")

    assert {:error, [error]} = JSONSchex.validate(compiled, "not-an-email")
    assert error.rule == :pattern
  end

  test "validates properties when value is nil" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"}
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(compiled, %{"name" => nil})
    assert error.rule == :type
  end

  test "dependentSchemas compilation errors are returned" do
    schema = %{
      "dependentSchemas" => %{
        "foo" => %{"pattern" => "["}
      }
    }

    assert {:error, error} = JSONSchex.compile(schema)
    assert error.error == :invalid_regex
    assert error.value == "["
    assert error.path == ["dependentSchemas", "foo", "pattern"]
  end

  test "normalizes error lists to Error structs" do
    schema = %{
      "type" => "object",
      "dependentRequired" => %{"a" => ["b"]}
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(compiled, %{"a" => 1})
    assert error.rule == :dependentRequired
    assert JSONSchex.format_error(error) =~ "Dependency failure"
  end
end

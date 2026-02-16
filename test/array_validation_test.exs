defmodule JSONSchex.Test.ArrayValidation do
  use ExUnit.Case
  #alias JSONSchex.Types.Error

  describe "prefixItems and items" do
    test "validates tuple structure (prefixItems)" do
      # First item string, second integer
      schema = %{
        "type" => "array",
        "prefixItems" => [
          %{"type" => "string"},
          %{"type" => "integer"}
        ]
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, ["Gem", 10])

      # Fail index 1
      assert {:error, [error]} = JSONSchex.validate(compiled, ["Gem", "Not Int"])
      assert error.path == [1]
      assert error.rule == :type
    end

    test "validates additional items (items)" do
      # First item string, REST are integers
      schema = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "string"}],
        "items" => %{"type" => "integer"}
      }
      {:ok, compiled} = JSONSchex.compile(schema)
      #IO.inspect compiled

      assert :ok == JSONSchex.validate(compiled, ["Gem", 1, 2, 3])

      # Fail at index 2 (part of 'items')
      assert {:error, [error]} = JSONSchex.validate(compiled, ["Gem", 1, "bad"])
      assert error.path == [2]
      assert error.rule == :type
      assert JSONSchex.format_error(error) =~ "Expected type \"integer\", got \"string\""
    end
  end

  describe "unevaluatedItems" do
    test "forbids extra items" do
      # Tuple of 2 items, no more allowed
      schema = %{
        "type" => "array",
        "prefixItems" => [
          %{"type" => "string"},
          %{"type" => "string"}
        ],
        "unevaluatedItems" => false
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, ["A", "B"])

      # Index 2 is extra
      assert {:error, [error]} = JSONSchex.validate(compiled, ["A", "B", "Extra"])
      assert error.path == [2]
      assert error.rule == :unevaluatedItems
      assert JSONSchex.format_error(error) =~ "Item is not allowed"
    end

    test "allows extra items if valid against schema" do
      # Tuple of 1 item (string), leftovers must be boolean
      schema = %{
        "prefixItems" => [%{"type" => "string"}],
        "unevaluatedItems" => %{"type" => "boolean"}
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, ["Title", true, false])

      assert {:error, [error]} = JSONSchex.validate(compiled, ["Title", true, "Not Bool"])
      assert error.path == [2]
      assert error.rule == :type
    end
  end
end

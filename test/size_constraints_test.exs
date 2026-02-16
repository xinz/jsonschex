defmodule JSONSchex.Test.SizeConstraints do
  use ExUnit.Case

  describe "Object Size" do
    test "minProperties and maxProperties" do
      schema = %{"minProperties" => 1, "maxProperties" => 2}
      {:ok, compiled} = JSONSchex.compile(schema)

      # Valid
      assert :ok == JSONSchex.validate(compiled, %{"a" => 1})
      assert :ok == JSONSchex.validate(compiled, %{"a" => 1, "b" => 2})

      # Invalid (Too few)
      assert {:error, [e1]} = JSONSchex.validate(compiled, %{})
      assert e1.rule == :minProperties

      # Invalid (Too many)
      assert {:error, [e2]} = JSONSchex.validate(compiled, %{"a" => 1, "b" => 2, "c" => 3})
      assert e2.rule == :maxProperties
    end
  end

  describe "Array Size" do
    test "minItems and maxItems" do
      schema = %{"minItems" => 2, "maxItems" => 3}
      {:ok, compiled} = JSONSchex.compile(schema)

      # Valid
      assert :ok == JSONSchex.validate(compiled, [1, 2])
      assert :ok == JSONSchex.validate(compiled, [1, 2, 3])

      # Invalid
      assert {:error, [e1]} = JSONSchex.validate(compiled, [1])
      assert e1.rule == :minItems

      assert {:error, [e2]} = JSONSchex.validate(compiled, [1, 2, 3, 4])
      assert e2.rule == :maxItems
    end
  end

  describe "Unique Items" do
    test "ensures uniqueness" do
      schema = %{"uniqueItems" => true}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, [1, 2, 3])
      assert :ok == JSONSchex.validate(compiled, []) # Empty is unique
      assert :ok == JSONSchex.validate(compiled, ["a", "b"])

      # Duplicates
      assert {:error, [e]} = JSONSchex.validate(compiled, [1, 2, 1])
      assert e.rule == :uniqueItems

      # Complex duplicates (Maps)
      assert {:error, [e2]} = JSONSchex.validate(compiled, [%{"a" => 1}, %{"a" => 1}])
      assert e2.rule == :uniqueItems
    end
  end
end

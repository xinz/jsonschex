defmodule JSONSchex.Compiler.PredicatesTest do
  use ExUnit.Case

  test "unique items that numbers are unique if mathematically unequal" do
    assert {:error, %{uniqueItems: true}} = JSONSchex.Compiler.Predicates.check_unique_items([1.0, 1], true)

    schema =%{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "uniqueItems" => true
    }

    {:ok, c} = JSONSchex.compile(schema)
    assert {:error, _} = JSONSchex.validate(c, [1.0, 1])
  end

  test "type number in a list" do
    schema = %{
      "type" => ["number"]
    }
    {:ok, c} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(c, 1)
  end

  test "validates string length using unicode code points (not graphemes)" do
    data = "#️⃣"
    assert String.length(data) == 1
    assert length(String.to_charlist(data)) == 3

    schema = %{"type" => "string", "minLength" => 3}
    {:ok, c} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(c, data)

    schema = %{"type" => "string", "maxLength" => 1}
    {:ok, c} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(c, data)
    assert error.rule == :maxLength
  end
end

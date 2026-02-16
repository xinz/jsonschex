defmodule JSONSchex.Test.PropertyErrorSemantics do
  use ExUnit.Case

  test "propertyNames returns nested errors from the name schema" do
    schema = %{
      "type" => "object",
      "propertyNames" => %{"minLength" => 2}
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(compiled, %{"a" => 1})
    assert error.rule == :minLength
    assert error.path == ["a"]
  end

  test "dependentRequired returns Error structs with rule and path" do
    schema = %{
      "type" => "object",
      "dependentRequired" => %{
        "a" => ["b", "c"]
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(compiled, %{"a" => 1})
    assert error.rule == :dependentRequired
    assert error.path == []
    assert String.contains?(JSONSchex.format_error(error), "requires")
  end
end
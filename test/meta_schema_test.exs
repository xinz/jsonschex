defmodule JSONSchex.Test.MetaSchema do
  use ExUnit.Case

  test "ensure draft2020-12 $schema validates correctly" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "const" => %{"foo" => "bar", "baz" => "bax"}
    }
    
    {:ok, compiled} = JSONSchex.compile(schema)
    data = %{"foo" => "bar", "baz" => "bax"}
    assert JSONSchex.validate(compiled, data) == :ok
    
    data2 = %{"foo" => "bar"}
    assert {:error, [%{rule: :const}]} = JSONSchex.validate(compiled, data2)
  end

  test "compile with nested $schema does not attempt to resolve dialect" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "properties" => %{
        "nested" => %{
          "$schema" => "http://json-schema.org/draft-07/schema#",
          "type" => "string"
        }
      }
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)
    assert JSONSchex.validate(compiled, %{"nested" => "value"}) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, %{"nested" => 123})
  end
end
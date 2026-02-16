defmodule JSONSchex.Test.Anchor do
  use ExUnit.Case

  test "Location-independent identifier" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "#foo",
      "$defs" => %{
          "A" => %{
              "$anchor" => "foo",
              "type" => "integer"
          }
      }
    }

    {:ok, c} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(c, 1)
    assert {:error, [error]} = JSONSchex.validate(c, "1")
    assert error.rule == :type
    assert JSONSchex.format_error(error) =~ "Expected type \"integer\", got \"string\""
  end

end

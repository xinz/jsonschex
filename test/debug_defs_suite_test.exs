defmodule JSONSchex.Test.Defs do
  use ExUnit.Case

  test "debug - validate definition against metaschema" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "https://json-schema.org/draft/2020-12/schema"
    }

    assert {:ok, c} = JSONSchex.compile(schema, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert {:error, _errors} = JSONSchex.validate(c, %{"$defs" => %{"foo" => %{"type" => 1}}})
    assert :ok == JSONSchex.validate(c, %{"$defs" => %{"foo" => %{"type" => "integer"}}})
  end

end

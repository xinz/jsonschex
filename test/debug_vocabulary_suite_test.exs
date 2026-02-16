defmodule JSONSchex.Test.DebugVocabularySuite do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner
  alias JSONSchex.JSON

  # Directly runs ONLY this file, ignoring any global ignore lists
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/vocabulary.json")

  test "debug - schema that uses custom metaschema with with no validation vocabulary" do
    schema = """
    {
        "$id": "https://schema/using/no/validation",
        "$schema": "http://localhost:1234/draft2020-12/metaschema-no-validation.json",
        "properties": {
            "badProperty": false,
            "numberProperty": {
                "minimum": 10
            }
        }
    }
    """
    {:ok, a} = JSON.decode(schema)
    {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1])
    assert {:error, _} = JSONSchex.validate(c, %{"badProperty" => "this property should not exist"})
    assert :ok == JSONSchex.validate(c, %{"numberProperty" => 1})
    assert :ok == JSONSchex.validate(c, %{"numberProperty" => 20})
  end
end

defmodule JSONSchex.Test.DebugVocabularySuite do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner
  alias JSONSchex.JSON

  # Directly runs ONLY this file, ignoring any global ignore lists
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/vocabulary.json")

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

    external_schemas = %{
      "http://localhost:1234/draft2020-12/metaschema-no-validation.json" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "http://localhost:1234/draft2020-12/metaschema-no-validation.json",
        "$vocabulary" => %{
          "https://json-schema.org/draft/2020-12/vocab/core" => true,
          "https://json-schema.org/draft/2020-12/vocab/applicator" => true
        },
        "$dynamicAnchor" => "meta",
        "allOf" => [
          %{"$ref" => "https://json-schema.org/draft/2020-12/meta/applicator"},
          %{"$ref" => "https://json-schema.org/draft/2020-12/meta/core"}
        ]
      }
    }

    loader = JSONSchex.Test.SuiteLoader.loader(external_schemas)
    {:ok, a} = JSON.decode(schema)
    {:ok, c} = JSONSchex.compile(a, loader: loader)
    assert {:error, _} = JSONSchex.validate(c, %{"badProperty" => "this property should not exist"})
    assert :ok == JSONSchex.validate(c, %{"numberProperty" => 1})
    assert :ok == JSONSchex.validate(c, %{"numberProperty" => 20})
  end
end

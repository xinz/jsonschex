defmodule JSONSchex.Test.VocabularyDialectTest do
  use ExUnit.Case

  test "compile fails when metaschema requires unknown vocabulary" do
    schema = %{
      "$schema" => "http://localhost:1234/draft2020-12/metaschema-required-unknown-vocabulary.json",
      "type" => "number"
    }

    metaschema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/metaschema-required-unknown-vocabulary.json",
      "$vocabulary" => %{
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://json-schema.org/draft/2020-12/vocab/validation" => true,
        "http://localhost:1234/draft/2020-12/vocab/unknown-required" => true
      },
      "$dynamicAnchor" => "meta",
      "allOf" => [
        %{"$ref" => "https://json-schema.org/draft/2020-12/meta/core"},
        %{"$ref" => "https://json-schema.org/draft/2020-12/meta/validation"}
      ]
    }

    loader = fn
      "http://localhost:1234/draft2020-12/metaschema-required-unknown-vocabulary.json" ->
        {:ok, metaschema}

      uri ->
        JSONSchex.Test.SuiteLoader.load(uri)
    end

    assert {:error, error} = JSONSchex.compile(schema, external_loader: loader)

    assert error.error == :unsupported_vocabulary
    assert error.path == ["$vocabulary", "http://localhost:1234/draft/2020-12/vocab/unknown-required"]
    assert error.value == true
  end

  test "compile fails when schema declares required unknown vocabulary" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$vocabulary" => %{
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "http://localhost:1234/draft/2020-12/vocab/unknown-required-inline" => true
      },
      "type" => "string"
    }

    assert {:error, error} = JSONSchex.compile(schema)
    assert error.error == :unsupported_vocabulary
    assert error.path == ["$vocabulary", "http://localhost:1234/draft/2020-12/vocab/unknown-required-inline"]
    assert error.value == true
  end
end

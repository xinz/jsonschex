defmodule JSONSchex.Test.FormatAssertionTest do
  use ExUnit.Case

  test "standard draft 2020-12 disables format assertion by default" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "format" => "email"
    }

    # Default behavior: format is annotation only
    {:ok, compiled} = JSONSchex.compile(schema, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert JSONSchex.validate(compiled, "not-an-email") == :ok
    assert JSONSchex.validate(compiled, "test@example.com") == :ok
  end

  test "compile option format_assertion: true overrides default behavior" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "format" => "email"
    }

    # Forced assertion
    {:ok, compiled} = JSONSchex.compile(schema, format_assertion: true, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    
    assert {:error, errors} = JSONSchex.validate(compiled, "not-an-email")
    assert Enum.any?(errors, fn e -> e.rule == :format end)

    assert JSONSchex.validate(compiled, "test@example.com") == :ok
  end

  test "schema without $schema uses internal defaults (which includes assertion)" do
    # When no $schema is provided, JSONSchex uses Vocabulary.defaults()
    # which currently includes all known vocabularies (including format-assertion).
    schema = %{
      "format" => "email"
    }

    {:ok, compiled} = JSONSchex.compile(schema)
    
    assert {:error, errors} = JSONSchex.validate(compiled, "not-an-email")
    assert Enum.any?(errors, fn e -> e.rule == :format end)
  end

  test "custom dialect can enable format assertion via $vocabulary" do
    custom_meta_uri = "http://example.com/dialect-with-format"
    custom_meta = %{
      "$id" => custom_meta_uri,
      "$vocabulary" => %{
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://json-schema.org/draft/2020-12/vocab/format-assertion" => true
      }
    }

    loader = fn
      ^custom_meta_uri -> {:ok, custom_meta}
      _ -> {:error, :not_found}
    end

    schema = %{
      "$schema" => custom_meta_uri,
      "format" => "email"
    }

    {:ok, compiled} = JSONSchex.compile(schema, external_loader: loader)

    assert {:error, errors} = JSONSchex.validate(compiled, "not-an-email")
    assert Enum.any?(errors, fn e -> e.rule == :format end)
  end

  test "format assertion propagates to remote references" do
    remote_uri = "http://example.com/remote-format.json"
    remote_schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "format" => "email"
    }

    loader = fn
      ^remote_uri -> {:ok, remote_schema}
      uri -> JSONSchex.Test.SuiteLoader.load(uri)
    end

    main_schema = %{
      "$ref" => remote_uri
    }

    # Without assertion option (should pass invalid email)
    {:ok, compiled_default} = JSONSchex.compile(main_schema, external_loader: loader)
    assert JSONSchex.validate(compiled_default, "not-an-email") == :ok

    # With assertion option (should fail invalid email)
    {:ok, compiled_forced} = JSONSchex.compile(main_schema, external_loader: loader, format_assertion: true)
    assert {:error, errors} = JSONSchex.validate(compiled_forced, "not-an-email")
    assert Enum.any?(errors, fn e -> e.rule == :format end)
  end
end
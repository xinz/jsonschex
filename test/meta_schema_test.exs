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

  test "ensure draft2020-12 $schema won't trigger external loader in compile" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "const" => %{"foo" => "bar", "baz" => "bax"}
    }

    loader = fn
      uri ->
        raise "#{uri} is unknown"
    end

    {:ok, compiled} = JSONSchex.compile(schema, external_loader: loader)

    data = %{"foo" => "bar", "baz" => "bax"}
    assert JSONSchex.validate(compiled, data) == :ok

    invalid_schema = "https://json-schema-unknown.org/dRaFt/2020-12/schema"

    schema = %{
      "$schema" => invalid_schema,
      "const" => %{"foo" => "bar", "baz" => "bax"}
    }

    assert_raise RuntimeError, ~r/#{invalid_schema} is unknown/, fn ->
      JSONSchex.compile(schema, external_loader: loader)
    end
  end

  test "built-in draft2020-12 $schema honors explicit supported optional $vocabulary without loader" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$vocabulary" => %{
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://json-schema.org/draft/2020-12/vocab/validation" => true,
        "https://json-schema.org/draft/2020-12/vocab/format-annotation" => false
      },
      "type" => "string",
      "format" => "email"
    }

    loader = fn
      uri ->
        raise "#{uri} is unknown"
    end

    assert {:ok, compiled} = JSONSchex.compile(schema, external_loader: loader)
    assert JSONSchex.validate(compiled, "not-an-email") == :ok
  end

  test "built-in draft2020-12 $schema rejects unsupported required $vocabulary without loader" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$vocabulary" => %{
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://example.com/custom-vocab" => true
      }
    }

    loader = fn
      uri ->
        raise "#{uri} is unknown"
    end

    assert {:error, error} = JSONSchex.compile(schema, external_loader: loader)
    assert error.rule == :unsupported_vocabulary
    assert error.path == ["$vocabulary", "https://example.com/custom-vocab"]
    assert error.value == true
  end

  test "validate definition against meta schema" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "https://json-schema.org/draft/2020-12/schema"
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)

    data = %{
      "$defs" => %{
        "foo" => %{
          "type" => "integer"
        }
      }
    }

    assert JSONSchex.validate(compiled, data) == :ok

    data = %{
      "$defs" => %{
        "foo" => %{
          "type" => 1
        }
      }
    }

    assert {:error, _} = JSONSchex.validate(compiled, data)
  end

  test "remote ref, containing refs itself" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "https://json-schema.org/draft/2020-12/schema"
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)

    data = %{
      "minLength" => 1
    }

    assert :ok == JSONSchex.validate(compiled, data)

    data = %{
      "minLength" => -1
    }

    assert {:error, [e]} = JSONSchex.validate(compiled, data)
    assert e.rule == :minimum and e.value == -1
  end
end

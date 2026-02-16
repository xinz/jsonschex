defmodule JSONSchex.Test.ContentVocabulary do
  use ExUnit.Case

  test "contentMediaType and contentEncoding are annotations only (ignored in validation)" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentEncoding" => "base64"
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    # Not base64 and not JSON, but should still be valid because content* are annotations only.
    assert :ok == JSONSchex.validate(compiled, "not-base64-json")
  end

  test "contentSchema is ignored by default (content assertion disabled)" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentSchema" => %{
        "type" => "object",
        "required" => ["id"]
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    # Even though the contentSchema would require {"id": ...}, validation should pass because
    # content assertion is disabled by default.
    assert :ok == JSONSchex.validate(compiled, ~S({"name":"no-id"}))
  end

  test "contentSchema validates decoded content when content assertion is enabled" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentSchema" => %{
        "type" => "object",
        "required" => ["id"]
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert {:error, [error]} = JSONSchex.validate(compiled, ~S({"name":"no-id"}))
    assert error.rule == :required

    assert :ok == JSONSchex.validate(compiled, ~S({"id":"ok"}))
  end

  test "contentEncoding with JSON media type validates decoded content" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentEncoding" => "base64",
      "contentSchema" => %{
        "type" => "object",
        "required" => ["id"]
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert {:error, [error]} = JSONSchex.validate(compiled, "eyJuYW1lIjoibm8taWQifQ==")
    assert error.rule == :required

    assert :ok == JSONSchex.validate(compiled, "eyJpZCI6Im9rIn0=")
  end

  test "contentEncoding rejects invalid base64 when assertion enabled" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentEncoding" => "base64",
      "contentSchema" => %{
        "type" => "object"
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert {:error, [error]} = JSONSchex.validate(compiled, "%%%")
    assert error.rule == :contentEncoding
  end

  test "contentEncoding rejects invalid base64url when assertion enabled" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentEncoding" => "base64url",
      "contentSchema" => %{
        "type" => "object"
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert {:error, [error]} = JSONSchex.validate(compiled, "%%%")
    assert error.rule == :contentEncoding
  end

  test "contentSchema fails on unsupported contentMediaType when assertion enabled" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "text/plain",
      "contentSchema" => %{
        "type" => "object"
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert {:error, [error]} = JSONSchex.validate(compiled, "plain text")
    assert error.rule == :contentMediaType
  end

  test "contentMediaType rejects invalid JSON when assertion enabled" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentSchema" => %{
        "type" => "object"
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert {:error, [error]} = JSONSchex.validate(compiled, "{not valid json")
    assert error.rule == :contentMediaType
  end

  test "content keywords do not bypass base type validation" do
    schema = %{
      "type" => "string",
      "contentMediaType" => "application/json"
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(compiled, 123)
    assert error.rule == :type
  end
end

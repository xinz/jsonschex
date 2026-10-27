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
    assert JSONSchex.format_error(error) == ~s(Failed to decode string as 'base64': "%%%")
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
    assert JSONSchex.format_error(error) == ~s(Failed to decode string as 'base64url': "%%%")
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
    assert JSONSchex.format_error(error) ==
      ~s(Failed to decode as 'application/json': {:invalid_byte, 1, 110}, input: "{not valid json")
  end

  test "content assertions work without contentSchema when enabled" do
    schema = %{
      "contentMediaType" => "application/json",
      "contentEncoding" => "base64"
    }

    {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)

    assert :ok == JSONSchex.validate(compiled, Base.encode64(~S({"id":1})))

    assert {:error, [encoding_error]} = JSONSchex.validate(compiled, "%")
    assert encoding_error.rule == :contentEncoding

    assert {:error, [media_error]} = JSONSchex.validate(compiled, Base.encode64("{:}"))
    assert media_error.rule == :contentMediaType
  end

  test "standalone content rules retain specification keyword names in both drafts" do
    cases = [
      {%{"contentEncoding" => "base64"}, :contentEncoding, "%", :contentEncoding, Base.encode64("ok")},
      {%{"contentMediaType" => "application/json"}, :contentMediaType, "not-json", :contentMediaType, "{}"},
      {%{"contentEncoding" => "base64", "contentMediaType" => "application/json"},
       :contentMediaType, "%", :contentEncoding, Base.encode64("{}")}
    ]

    for draft <- ["draft7", "draft2020_12"],
        {schema, name, invalid, error_rule, valid} <- cases do
      assert {:ok, annotations} = JSONSchex.compile(schema, draft: draft)
      assert annotations.rules == []
      assert :ok == JSONSchex.validate(annotations, invalid)

      assert {:ok, assertions} =
               JSONSchex.compile(schema, draft: draft, content_assertion: true)
      assert [%{name: ^name}] = assertions.rules
      assert :ok == JSONSchex.validate(assertions, valid)
      assert :ok == JSONSchex.validate(assertions, 123)
      assert {:error, [%{rule: ^error_rule}]} = JSONSchex.validate(assertions, invalid)
    end
  end

  test "contentAssertion remains an unknown input keyword in both drafts" do
    refute JSONSchex.Draft7.Dialect.keyword?("contentAssertion")

    for draft <- ["draft7", "draft2020_12"] do
      assert {:ok, compiled} =
               JSONSchex.compile(%{"contentAssertion" => false}, draft: draft, content_assertion: true)
      assert compiled.rules == []
      assert :ok == JSONSchex.validate(compiled, "arbitrary content")
    end
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

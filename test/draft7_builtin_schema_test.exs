defmodule JSONSchex.Test.Draft7BuiltinSchemaTest do
  use ExUnit.Case

  alias JSONSchex.Draft7.Schemas, as: Draft7Schemas

  @uris [
    "http://json-schema.org/draft-07/schema",
    "http://json-schema.org/draft-07/schema#"
  ]

  @invalid_schema_metadata [
    {"pattern metadata", %{"pattern" => "["}, "["},
    {"$id metadata", %{"$id" => "not a URI"}, "not a URI"},
    {"recursive definitions pattern metadata",
     %{"definitions" => %{"node" => %{"pattern" => "["}}}, "["},
    {"recursive definitions $id metadata",
     %{"definitions" => %{"node" => %{"$id" => "not a URI"}}}, "not a URI"}
  ]

  for uri <- @uris do
    test "direct compilation of #{uri} honors format assertion options" do
      assert {:ok, raw_schema} = Draft7Schemas.fetch(unquote(uri))

      for format_assertion <- [false, true] do
        assert {:ok, compiled} =
                 JSONSchex.compile(raw_schema, format_assertion: format_assertion)

        for {_description, instance, value} <- @invalid_schema_metadata do
          result = JSONSchex.validate(compiled, instance)

          if format_assertion do
            assert_format_error(result, value)
          else
            assert :ok == result
          end
        end
      end
    end

    test "built-in #{uri} accepts valid schemas and preserves annotation-only defaults" do
      uri = unquote(uri)
      schema = %{"$schema" => uri, "$ref" => uri}

      valid_schemas = [
        true,
        false,
        %{},
        %{"pattern" => "^[a-z]+$"},
        %{"$id" => "schemas/example.json"},
        %{
          "$schema" => uri,
          "$id" => "https://example.test/schema",
          "$ref" => "#/definitions/node",
          "definitions" => %{
            "node" => %{
              "$id" => "node.json",
              "pattern" => "^[a-z]+$",
              "properties" => %{"next" => %{"$ref" => "#"}}
            }
          }
        }
      ]

      for opts <- [[], [format_assertion: false], [format_assertion: true]] do
        assert {:ok, compiled} = JSONSchex.compile(schema, opts)

        for instance <- valid_schemas do
          assert :ok == JSONSchex.validate(compiled, instance)
        end

        unless Keyword.get(opts, :format_assertion, false) do
          for {_description, instance, _value} <- @invalid_schema_metadata do
            assert :ok == JSONSchex.validate(compiled, instance)
          end
        end
      end
    end

    for {description, instance, value} <- @invalid_schema_metadata do
      test "built-in #{uri} isolates format assertion options for #{description} with a warm cache" do
        uri = unquote(uri)
        instance = unquote(Macro.escape(instance))
        value = unquote(value)
        schema = %{"$schema" => uri, "$ref" => uri}

        # The built-in registry is shared across compilations. Exercise every option
        # transition before asserting, without clearing the cache or assuming it is cold.
        results =
          for format_assertion <- [false, true, false, true, false] do
            assert {:ok, compiled} =
                     JSONSchex.compile(schema, format_assertion: format_assertion)

            {format_assertion, JSONSchex.validate(compiled, instance)}
          end

        for {format_assertion, result} <- results do
          if format_assertion do
            assert_format_error(result, value)
          else
            assert :ok == result
          end
        end
      end
    end
  end

  test "built-in cache variants preserve both assertion flags and share canonical aliases" do
    for format_assertion <- [false, true], content_assertion <- [false, true] do
      opts = [format_assertion: format_assertion, content_assertion: content_assertion]
      defs = Draft7Schemas.compiled_defs(hd(@uris), opts)
      assert defs === Draft7Schemas.compiled_defs(List.last(@uris), opts)

      for {_uri, compiled} <- defs do
        assert compiled.draft == "draft7"
        assert compiled.format_assertion == format_assertion
        assert compiled.content_assertion == content_assertion
      end
    end

    assert Draft7Schemas.compiled_defs(hd(@uris)) ===
             Draft7Schemas.compiled_defs(hd(@uris), format_assertion: false, content_assertion: false)
    assert Draft7Schemas.compiled_defs("https://example.com/not-a-built-in", format_assertion: true) == nil
  end

  defp assert_format_error(result, value) do
    assert {:error, errors} = result
    assert Enum.any?(errors, &(&1.rule == :format and &1.value == value))
  end
end

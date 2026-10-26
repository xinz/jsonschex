defmodule JSONSchex.Test.Draft7Compatibility do
  use ExUnit.Case

  test "built-in Draft 7 schema matches the official fixture for both URI forms" do
    fixture =
      "priv/schemas/draft-07/schema.json"
      |> File.read!()
      |> JSONSchex.JSON.decode!()

    for uri <- ["http://json-schema.org/draft-07/schema", "http://json-schema.org/draft-07/schema#"] do
      assert {:ok, ^fixture} = JSONSchex.Draft7.Schemas.fetch(uri)
      assert is_map(JSONSchex.Draft7.Schemas.compiled_defs(uri))
    end

    assert :error == JSONSchex.Draft7.Schemas.fetch("https://example.com/unknown")
    assert nil == JSONSchex.Draft7.Schemas.compiled_defs("https://example.com/unknown")
  end

  test "Draft 7 tuple items apply additionalItems after the prefix" do
    schema = %{
      "items" => [%{"type" => "integer"}],
      "additionalItems" => false
    }

    {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7")

    assert :ok == JSONSchex.validate(compiled, [1])
    assert {:error, [extra_item]} = JSONSchex.validate(compiled, [1, 2])
    assert extra_item.rule == :boolean_schema
    assert {:error, [wrong_type]} = JSONSchex.validate(compiled, ["not an integer"])
    assert wrong_type.rule == :type
  end

  test "an explicit Draft 7 option ignores $ref siblings" do
    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$id" => "https://example.com/root.json",
      "definitions" => %{"integer" => %{"type" => "integer"}},
      "properties" => %{
        "value" => %{
          "$id" => "https://example.com/ignored.json",
          "$ref" => "#/definitions/integer",
          "type" => "string"
        }
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7")

    assert compiled.draft == "draft7"
    assert :ok == JSONSchex.validate(compiled, %{"value" => 1})
    assert {:error, [wrong_type]} = JSONSchex.validate(compiled, %{"value" => "one"})
    assert wrong_type.rule == :type
  end

  test "canonical Draft 7 $schema selects Draft 7 with or without a fragment" do
    for uri <- ["http://json-schema.org/draft-07/schema", "http://json-schema.org/draft-07/schema#"] do
      schema = %{"$schema" => uri, "prefixItems" => [false]}

      {:ok, inferred} = JSONSchex.compile(schema)
      {:ok, explicit} = JSONSchex.compile(schema, draft: "draft7")

      assert inferred.draft == "draft7"
      assert explicit.draft == "draft7"
      assert :ok == JSONSchex.validate(inferred, [1])
    end
  end

  test "canonical Draft 2020-12 $schema selects Draft 2020-12" do
    schema = %{"$schema" => "https://json-schema.org/draft/2020-12/schema", "prefixItems" => [false]}

    for opts <- [[], [draft: "draft2020_12"]] do
      {:ok, compiled} = JSONSchex.compile(schema, opts)
      assert compiled.draft == "draft2020_12"
      assert {:error, [_]} = JSONSchex.validate(compiled, [1])
    end
  end

  test "a recognized $schema conflicting with :draft returns a useful error" do
    for {uri, requested, declared} <- [
          {"http://json-schema.org/draft-07/schema#", "draft2020_12", "draft7"},
          {"https://json-schema.org/draft/2020-12/schema", "draft7", "draft2020_12"}
        ] do
      assert {:error, error} = JSONSchex.compile(%{"$schema" => uri}, draft: requested)
      assert error.rule == :draft_conflict
      assert error.path == ["$schema"]
      assert error.value == uri
      assert error.context.contrast == declared
      assert error.context.input == requested
      assert JSONSchex.format_error(error) =~ "selects #{inspect(declared)}, but :draft is #{inspect(requested)}"
    end
  end

  test "absent or unrecognized $schema uses the requested draft or the 2020-12 default" do
    for schema <- [%{"prefixItems" => [false]}, %{"$schema" => "https://example.com/custom", "prefixItems" => [false]}] do
      {:ok, default} = JSONSchex.compile(schema)
      {:ok, draft7} = JSONSchex.compile(schema, draft: "draft7")

      assert default.draft == "draft2020_12"
      assert {:error, [_]} = JSONSchex.validate(default, [1])
      assert draft7.draft == "draft7"
      assert :ok == JSONSchex.validate(draft7, [1])
    end
  end

  test "a boolean schema honors :draft and rejects unsupported draft values" do
    assert {:ok, %{draft: "draft2020_12"}} = JSONSchex.compile(true)
    assert {:ok, %{draft: "draft7"}} = JSONSchex.compile(true, draft: "draft7")

    for invalid <- [:draft7, :draft2020_12, "draft6", nil] do
      assert {:error, %{rule: :invalid_draft} = error} = JSONSchex.compile(true, draft: invalid)
      assert JSONSchex.format_error(error) =~ "expected \"draft7\" or \"draft2020_12\""
    end
  end

  test "fragment compilation selects the containing document's root $schema" do
    document = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "entry" => %{"items" => [%{"type" => "integer"}], "additionalItems" => false}
    }

    {:ok, compiled} = JSONSchex.compile_fragment(document, entry: "#/entry")
    assert compiled.draft == "draft7"
    assert :ok == JSONSchex.validate(compiled, [1])
    assert {:error, [_]} = JSONSchex.validate(compiled, [1, 2])

    assert {:error, %{rule: :draft_conflict}} =
             JSONSchex.compile_fragment(document, entry: "#/entry", draft: "draft2020_12")
  end

  test "both canonical Draft 7 meta-schema URI forms work without a loader" do
    for uri <- ["http://json-schema.org/draft-07/schema", "http://json-schema.org/draft-07/schema#"] do
      schema = %{"$schema" => uri, "$ref" => uri}
      {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7")

      assert :ok == JSONSchex.validate(compiled, %{"definitions" => %{"foo" => %{"type" => "integer"}}})
      assert {:error, errors} = JSONSchex.validate(compiled, %{"definitions" => %{"foo" => %{"type" => 1}}})
      assert Enum.any?(errors, &(&1.rule == :enum))
    end
  end

  test "Draft 2020-12 keeps $ref sibling validation by default" do
    schema = %{
      "$defs" => %{"integer" => %{"type" => "integer"}},
      "properties" => %{
        "value" => %{"$ref" => "#/$defs/integer", "type" => "string"}
      }
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    assert compiled.draft == "draft2020_12"
    assert {:error, [wrong_type]} = JSONSchex.validate(compiled, %{"value" => 1})
    assert wrong_type.rule == :type
  end
end

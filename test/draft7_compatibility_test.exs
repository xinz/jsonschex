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

  test "ignored $ref siblings cannot shadow a remote resource in Draft 7" do
    parent = self()
    remote_uri = "https://example.com/remote-string"

    loader = fn ^remote_uri ->
      send(parent, {:loaded, remote_uri})
      {:ok, %{"type" => "string"}}
    end

    schema = %{
      "definitions" => %{"integer" => %{"type" => "integer"}},
      "properties" => %{
        "a" => %{
          "$ref" => "#/definitions/integer",
          "definitions" => %{
            "ignored" => %{"$id" => remote_uri, "type" => "integer"}
          }
        },
        "b" => %{"$ref" => remote_uri}
      }
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7", loader: loader)

      refute Map.has_key?(compiled.defs, remote_uri)
      assert :ok == JSONSchex.validate(compiled, %{"a" => 1, "b" => "text"})
      assert_received {:loaded, ^remote_uri}
      assert {:error, [%{path: ["b"], rule: :type}]} =
               JSONSchex.validate(compiled, %{"a" => 1, "b" => 2})
      assert_received {:loaded, ^remote_uri}

      control = compile_schema!(schema, mode, draft: "draft2020_12")
      assert Map.has_key?(control.defs, remote_uri)
      assert :ok == JSONSchex.validate(control, %{"a" => 1, "b" => 2})
    end
  end

  test "a root Draft 7 $ref ignores its sibling $id during scope registration" do
    uri = "https://example.com/remote-root"
    loader = fn ^uri -> {:ok, %{"type" => "string"}} end
    schema = %{"$id" => uri, "$ref" => uri}

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7", loader: loader)
      refute Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, "text")
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, 1)
    end
  end

  test "Draft 7 items does not skip elements because of prefixItems" do
    schema = %{"items" => false, "prefixItems" => [true]}

    assert {:ok, draft7} = JSONSchex.compile(schema, draft: "draft7")
    assert {:error, [%{rule: :boolean_schema}]} = JSONSchex.validate(draft7, [1])
    assert :ok == JSONSchex.validate(draft7, [])

    assert {:ok, draft2020} = JSONSchex.compile(schema, draft: "draft2020_12")
    assert :ok == JSONSchex.validate(draft2020, [1])
    assert {:error, [%{rule: :boolean_schema}]} = JSONSchex.validate(draft2020, [1, 2])
  end

  test "Draft 7 contains ignores minContains and maxContains" do
    for bounds <- [
          %{"minContains" => 0},
          %{"minContains" => 2},
          %{"minContains" => "annotation"},
          %{"maxContains" => 0},
          %{"maxContains" => false}
        ] do
      schema = Map.put(bounds, "contains", true)
      assert {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7")
      assert {:error, [%{rule: :contains}]} = JSONSchex.validate(compiled, [])
      assert :ok == JSONSchex.validate(compiled, [1])
    end

    assert {:ok, min_zero} =
             JSONSchex.compile(%{"contains" => true, "minContains" => 0})
    assert :ok == JSONSchex.validate(min_zero, [])

    assert {:ok, max_zero} =
             JSONSchex.compile(%{"contains" => true, "maxContains" => 0})
    assert {:error, [%{rule: :contains}]} = JSONSchex.validate(max_zero, [1])
  end

  test "Draft 7 ignores unreferenced $defs annotations" do
    annotations = [
      "annotation",
      %{"invalid" => %{"type" => 42}},
      %{"resource" => %{"$id" => "https://example.com/annotation", "type" => "integer"}}
    ]

    for mode <- ["schema", "document"], annotation <- annotations do
      schema = %{"type" => "integer", "$defs" => annotation}
      compiled = compile_schema!(schema, mode, draft: "draft7")

      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
      refute Map.has_key?(compiled.defs, "https://example.com/annotation")
      refute Map.has_key?(compiled.defs, "#/$defs/resource")
    end
  end

  test "Draft 7 can explicitly reference a schema within an unknown keyword" do
    schema = %{
      "properties" => %{"value" => %{"$ref" => "#/$defs/integer"}},
      "$defs" => %{"integer" => %{"type" => "integer"}}
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert :ok == JSONSchex.validate(compiled, %{"value" => 1})
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"value" => "1"})
    end
  end

  test "a property named $defs is still traversed as a schema" do
    uri = "https://example.com/property-schema"
    schema = %{"properties" => %{"$defs" => %{"$id" => uri, "type" => "integer"}}}

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, %{"$defs" => 1})
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"$defs" => "1"})
    end
  end

  test "a component named $defs is still discovered in a containing document" do
    uri = "https://example.com/component-schema"
    document = %{
      "components" => %{
        "schemas" => %{"$defs" => %{"$id" => uri, "type" => "integer"}}
      },
      "entry" => %{"$ref" => uri}
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document, entry: "#/entry", draft: "draft7")
    assert Map.has_key?(compiled.defs, uri)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
  end

  test "Draft 7 registers resources declared by tuple additionalItems" do
    uri = "https://example.com/extra"
    schema = %{
      "items" => [true],
      "additionalItems" => %{"$id" => uri, "type" => "integer"},
      "allOf" => [%{"$ref" => uri}]
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end

    ignored = %{"items" => true, "additionalItems" => %{"$id" => uri, "type" => "integer"}}
    assert {:ok, draft2020} = JSONSchex.compile(ignored)
    refute Map.has_key?(draft2020.defs, uri)
    assert :ok == JSONSchex.validate(draft2020, [1, "text"])

    for mode <- ["schema", "document"] do
      non_tuple = compile_schema!(ignored, mode, draft: "draft7")
      refute Map.has_key?(non_tuple.defs, uri)
      assert :ok == JSONSchex.validate(non_tuple, [1, "text"])
    end
  end

  test "unknown contentSchema does not disable Draft 7 content assertions" do
    for {keywords, invalid, rule} <- [
          {%{"contentEncoding" => "base64"}, "%", :contentEncoding},
          {%{"contentMediaType" => "application/json"}, "not-json", :contentMediaType},
          {%{"contentEncoding" => "base64", "contentMediaType" => "application/json"},
           Base.encode64("not-json"), :contentMediaType}
        ] do
      schema = Map.put(keywords, "contentSchema", false)
      assert {:ok, annotations} = JSONSchex.compile(schema, draft: "draft7")
      assert :ok == JSONSchex.validate(annotations, invalid)

      assert {:ok, assertions} =
               JSONSchex.compile(schema, draft: "draft7", content_assertion: true)
      assert {:error, [%{rule: ^rule}]} = JSONSchex.validate(assertions, invalid)
    end

    schema = %{"contentMediaType" => "application/json", "contentSchema" => false}
    assert {:ok, draft7} = JSONSchex.compile(schema, draft: "draft7", content_assertion: true)
    assert :ok == JSONSchex.validate(draft7, "{}")

    assert {:ok, draft2020} = JSONSchex.compile(schema, content_assertion: true)
    assert {:error, [_ | _]} = JSONSchex.validate(draft2020, "{}")
  end

  test "Draft 7 annotations from newer drafts cannot register resources" do
    uri = "https://example.com/remote-string"
    child = %{"$id" => uri, "type" => "integer"}
    loader = fn ^uri -> {:ok, %{"type" => "string"}} end

    for {keyword, annotation} <- [
          {"$defs", %{"x" => child}},
          {"prefixItems", [child]},
          {"dependentSchemas", %{"x" => child}},
          {"contentSchema", child},
          {"unevaluatedProperties", child},
          {"unevaluatedItems", child}
        ], mode <- ["schema", "document"] do
      schema = %{keyword => annotation, "properties" => %{"value" => %{"$ref" => uri}}}
      compiled = compile_schema!(schema, mode, draft: "draft7", loader: loader)
      refute Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, %{"value" => "text"})
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"value" => 1})
    end
  end

  test "Draft 7 does not register newer anchor or dynamic-reference annotations" do
    uri = "https://example.com/root"
    schema = %{
      "$id" => uri,
      "$anchor" => "ignored",
      "$dynamicAnchor" => "also-ignored",
      "$dynamicRef" => "#/definitions/unused",
      "definitions" => %{"unused" => %{"const" => "unused"}},
      "type" => "integer"
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      refute Map.has_key?(compiled.defs, uri <> "#ignored")
      refute Map.has_key?(compiled.defs, uri <> "#also-ignored")
      refute Map.has_key?(compiled.defs, "#/definitions/unused")
      assert :ok == JSONSchex.validate(compiled, 1)
    end
  end

  test "properties named after newer keywords remain discoverable in Draft 7" do
    uri = "https://example.com/property"

    for name <- ["prefixItems", "dependentSchemas", "contentSchema", "$anchor"],
        mode <- ["schema", "document"] do
      schema = %{"properties" => %{name => %{"$id" => uri, "type" => "integer"}}}
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, %{name => 1})
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{name => "1"})
    end
  end

  test "eager Draft 7 pointer inheritance ignores the root $ref sibling $id" do
    parent = self()
    expected_uri = "https://right.example/leaf.json"
    loader = fn uri ->
      send(parent, {:loaded, uri})
      {:ok, %{"const" => uri}}
    end

    schema = %{
      "$id" => "https://wrong.example/",
      "$ref" => "#/definitions/x",
      "definitions" => %{"x" => %{"$ref" => "leaf.json"}}
    }

    assert {:ok, compiled} =
             JSONSchex.compile(schema,
               draft: "draft7",
               base_uri: "https://right.example/root.json",
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, expected_uri)
    assert_received {:loaded, ^expected_uri}
    refute_received {:loaded, "https://wrong.example/leaf.json"}
  end

  test "JIT Draft 7 pointer inheritance ignores ancestor $ref sibling $ids" do
    parent = self()
    remote_uri = "https://right.example/remote.json"
    expected_uri = "https://right.example/leaf.json"
    remote = %{
      "definitions" => %{
        "holder" => %{
          "$ref" => "#/definitions/ok",
          "$id" => "https://wrong.example/",
          "definitions" => %{"x" => %{"$ref" => "leaf.json"}}
        },
        "ok" => true
      }
    }

    loader = fn uri ->
      send(parent, {:loaded, uri})
      if uri == remote_uri, do: {:ok, remote}, else: {:ok, %{"const" => uri}}
    end

    schema = %{"$ref" => remote_uri <> "#/definitions/holder/definitions/x"}
    assert {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7", loader: loader)
    assert :ok == JSONSchex.validate(compiled, expected_uri)
    assert_received {:loaded, ^remote_uri}
    assert_received {:loaded, ^expected_uri}
    refute_received {:loaded, "https://wrong.example/leaf.json"}
  end

  defp compile_schema!(schema, mode, opts) do
    result =
      case mode do
        "schema" -> JSONSchex.compile(schema, opts)
        "document" -> JSONSchex.compile_fragment(schema, Keyword.put(opts, :entry, "#"))
      end

    assert {:ok, compiled} = result
    compiled
  end
end

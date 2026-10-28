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

    assert [%{name: :items, params: %{draft: "draft7"}}] = compiled.rules
    assert :ok == JSONSchex.validate(compiled, [1])
    assert {:error, [extra_item]} = JSONSchex.validate(compiled, [1, 2])
    assert extra_item.rule == :boolean_schema
    assert {:error, [wrong_type]} = JSONSchex.validate(compiled, ["not an integer"])
    assert wrong_type.rule == :type
  end

  test "tuple items and additionalItems compilation errors identify their own keyword" do
    for {schema, path} <- [
          {%{"items" => [true], "additionalItems" => %{"type" => 42}},
           ["additionalItems", "type"]},
          {%{"items" => [true, %{"type" => 42}], "additionalItems" => true},
           ["items", "type"]},
          {%{"items" => [%{"type" => 42}], "additionalItems" => %{"type" => 43}},
           ["items", "type"]},
          {%{"items" => [true], "additionalItems" => %{"not" => %{"type" => 42}}},
           ["additionalItems", "not", "type"]}
        ], mode <- ["schema", "document"] do
      result =
        case mode do
          "schema" -> JSONSchex.compile(schema, draft: "draft7")
          "document" -> JSONSchex.compile_fragment(schema, entry: "#", draft: "draft7")
        end

      assert {:error, error} = result
      assert error.path == path
      assert error.rule == :invalid_keyword_value
      assert error.value == 42
    end
  end

  test "schema-form items retains its single-schema rule shape in both drafts" do
    for draft <- ["draft7", "draft2020_12"] do
      assert {:ok, compiled} =
               JSONSchex.compile(%{"items" => %{"type" => "integer"}}, draft: draft)
      assert [%{name: :items, params: %{start_index: 0, schema: _}}] = compiled.rules
      assert :ok == JSONSchex.validate(compiled, [1])
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, ["1"])
    end
  end

  test "the compilation cache indexes both tuple items and additionalItems schemas" do
    prefix_uri = "https://example.com/prefix"
    additional_uri = "https://example.com/additional"
    prefix = %{"$id" => prefix_uri, "type" => "integer"}
    additional = %{"$id" => additional_uri, "type" => "string"}
    schema = %{"items" => [prefix], "additionalItems" => additional}

    assert {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7")
    assert [%{name: :items, params: %{draft: "draft7"}}] = compiled.rules

    # Remove the global registry so cache discovery must traverse the items rule.
    cache = JSONSchex.Compiler.Cache.build(%{compiled | defs: %{}})
    assert {:ok, %{raw: ^prefix}} =
             JSONSchex.Compiler.Cache.fetch_scope(cache, prefix_uri, prefix, prefix_uri)
    assert {:ok, %{raw: ^additional}} =
             JSONSchex.Compiler.Cache.fetch_scope(cache, additional_uri, additional, additional_uri)

    assert :ok == JSONSchex.validate(compiled, [1, "extra"])
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, [1, 2])
  end

  test "tupleItems is an unknown schema keyword, not a public tuple applicator" do
    refute JSONSchex.Draft7.Dialect.keyword?("tupleItems")

    for draft <- ["draft7", "draft2020_12"] do
      assert {:ok, compiled} = JSONSchex.compile(%{"tupleItems" => [false]}, draft: draft)
      assert compiled.rules == []
      assert :ok == JSONSchex.validate(compiled, [1])
    end
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

  test "document component names are not interpreted as Draft 7 keywords" do
    uri = "https://example.com/parameter-schema"

    for draft <- ["draft7", "draft2020_12"],
        name <- ["prefixItems", "$defs", "contentSchema", "additionalItems", "$ref", "$id",
                 "properties", "patternProperties", "definitions", "dependencies"],
        container <- ["schemas", "parameters", "arbitrary-components"],
        shape <- [:schema, :parameter] do
      resource = %{"$id" => uri, "type" => "integer"}
      component =
        case shape do
          :schema -> resource
          :parameter -> %{"name" => "filter", "in" => "query", "schema" => resource}
        end

      document = %{
        "components" => %{container => %{name => component}},
        "entry" => %{"$ref" => uri}
      }

      assert {:ok, compiled} =
               JSONSchex.compile_fragment(document, entry: "#/entry", draft: draft)
      assert Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, 42)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "42")
    end
  end

  test "document discovery preserves keyword-like names under arbitrary wrappers and lists" do
    uri = "https://example.com/wrapped-schema"
    document = %{
      "wrappers" => [
        %{"prefixItems" => %{
          "additionalItems" => %{"$ref" => %{"$id" => uri, "type" => "integer"}}
        }}
      ],
      "entry" => %{"$ref" => uri}
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document, entry: "#/entry", draft: "draft7")
    assert Map.has_key?(compiled.defs, uri)
    assert :ok == JSONSchex.validate(compiled, 42)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "42")
  end

  test "selected annotation-only schemas still prune ignored discovery subtrees" do
    uri = "https://example.com/ignored-resource"
    annotation = %{"$id" => uri, "$ref" => "#/missing"}

    for keyword <- ["prefixItems", "$defs", "contentSchema", "additionalItems"],
        entry <- ["#", "#/selected~1schema~0", "https://example.com/document#/selected~1schema~0"] do
      schema = %{keyword => annotation}
      document = if entry == "#", do: schema, else: %{"selected/schema~" => schema}

      assert {:ok, compiled} =
               JSONSchex.compile_fragment(document, entry: entry, draft: "draft7")
      refute Map.has_key?(compiled.defs, uri)
      refute Map.has_key?(compiled.defs, "#/missing")
      assert :ok == JSONSchex.validate(compiled, 42)
    end
  end

  test "explicit fragment selection takes precedence over a schema-map container role" do
    schema = %{"$defs" => %{"$id" => "https://example.com/ignored", "type" => 42}}
    document = %{"type" => "object", "properties" => schema}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document, entry: "#/properties", draft: "draft7")
    refute Map.has_key?(compiled.defs, "https://example.com/ignored")
    assert :ok == JSONSchex.validate(compiled, 42)
  end

  test "selected schemas beneath ignored annotations discover only their own resources" do
    uri = "https://example.com/selected-resource"
    ignored_uri = "https://example.com/ignored-sibling"
    selected = %{
      "properties" => %{"value" => %{"$id" => uri, "type" => "integer"}},
      "allOf" => [%{"$ref" => uri}]
    }
    document = %{
      "type" => "object",
      "$defs" => %{
        "selected" => selected,
        "ignored" => %{"$id" => ignored_uri, "type" => 42}
      }
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document, entry: "#/$defs/selected", draft: "draft7")
    assert Map.has_key?(compiled.defs, uri)
    refute Map.has_key?(compiled.defs, ignored_uri)
    assert :ok == JSONSchex.validate(compiled, 42)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "42")
  end

  test "selected schema paths match array indices without normalizing numeric map keys" do
    schema = %{"$defs" => %{"$id" => "https://example.com/ignored", "type" => 42}}

    for entry <- ["#/entries/0", "#/entries/%30", "#/entries/00", "#/entries/-1", "#/00"] do
      document = if entry == "#/00", do: %{"00" => schema, "0" => false}, else: %{"entries" => [schema]}

      assert {:ok, compiled} =
               JSONSchex.compile_fragment(document, entry: entry, draft: "draft7")
      refute Map.has_key?(compiled.defs, "https://example.com/ignored")
      assert :ok == JSONSchex.validate(compiled, 42)
    end
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

  test "explicit Draft 7 pointer targets discover nested resources without activating ignored siblings" do
    uri = "https://example.com/embedded-integer"
    ignored_uri = "https://example.com/ignored"
    target = %{
      "definitions" => %{"integer" => %{"$id" => uri, "type" => "integer"}},
      "allOf" => [%{"$ref" => uri}]
    }
    ignored = %{"$id" => ignored_uri, "type" => 42, "$defs" => %{"invalid" => %{"type" => 42}}}
    schemas = [
      %{"$ref" => "#/definitions/selected", "definitions" => %{"selected" => target, "ignored" => ignored}},
      %{"allOf" => [%{"$ref" => "#/$defs/selected~1part~0"}],
        "$defs" => %{"selected/part~" => target, "ignored" => ignored}},
      %{"$id" => "https://example.com/root",
        "allOf" => [%{"$ref" => "https://example.com/root#/$defs/selected"}],
        "$defs" => %{"selected" => target, "ignored" => ignored}}
    ]

    for schema <- schemas, mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      refute Map.has_key?(compiled.defs, ignored_uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 discovery follows transitive pointers and still ignores reached ref siblings" do
    uri = "https://example.com/transitive-integer"
    ignored_uri = "https://example.com/ignored-ref-sibling"
    schema = %{
      "$ref" => "#/definitions/first",
      "definitions" => %{
        "first" => %{
          "$ref" => "#/definitions/second",
          "$id" => "https://wrong.example/",
          "definitions" => %{"ignored" => %{"$id" => ignored_uri, "type" => 42}}
        },
        "second" => %{
          "definitions" => %{"integer" => %{"$id" => uri, "type" => "integer"}},
          "allOf" => [%{"$ref" => uri}]
        }
      }
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      refute Map.has_key?(compiled.defs, ignored_uri)
      refute Map.has_key?(compiled.defs, "https://wrong.example/")
      refute Map.has_key?(compiled.defs, "#/definitions/second")
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 referenced resource discovery applies retrieval and ancestor IDs exactly once" do
    uri = "https://example.com/base/nested/target/integer"
    schema = %{
      "$id" => "root.json",
      "allOf" => [%{"$ref" => "#/$defs/holder/definitions/target"}],
      "$defs" => %{
        "holder" => %{
          "$id" => "nested/",
          "definitions" => %{
            "target" => %{
              "$id" => "target/",
              "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}},
              "allOf" => [%{"$ref" => "integer"}]
            }
          }
        }
      }
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7", base_uri: "https://example.com/base/input.json")
      assert Map.has_key?(compiled.defs, uri)
      refute Map.has_key?(compiled.defs, "https://example.com/base/nested/target/target/integer")
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 pointer discovery resolves each local pointer against its owning resource" do
    uri = "https://example.com/nested/integer"
    decoy_uri = "https://example.com/outer-decoy"
    schema = %{
      "$id" => "https://example.com/root",
      "definitions" => %{
        "holder" => %{
          "$id" => "nested/",
          "allOf" => [%{"$ref" => "#/$defs/selected"}],
          "$defs" => %{
            "selected" => %{
              "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}}
            }
          }
        }
      },
      "$defs" => %{
        "selected" => %{"definitions" => %{"decoy" => %{"$id" => decoy_uri, "type" => 42}}}
      }
    }

    # Identical pointer text in two resource owners must not share a visited entry.
    other = Map.put(schema["definitions"]["holder"], "$id", "other/")
    schema = put_in(schema, ["definitions", "other"], other)

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      assert Map.has_key?(compiled.defs, "https://example.com/other/integer")
      refute Map.has_key?(compiled.defs, decoy_uri)
    end
  end

  test "Draft 7 resource discovery terminates for self and mutually recursive pointers" do
    uri = "https://example.com/cyclic-integer"
    for ref <- ["#", "#/definitions/first"], mode <- ["schema", "document"] do
      schema = %{
        "$ref" => "#/definitions/first",
        "definitions" => %{
          "first" => %{"allOf" => [%{"$ref" => "#/definitions/second"}]},
          "second" => %{
            "allOf" => [%{"$ref" => ref}],
            "definitions" => %{"integer" => %{"$id" => uri, "type" => "integer"}}
          }
        }
      }

      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
    end
  end

  test "Draft 7 fragment pointer discovery keeps the containing document as its initial resource" do
    uri = "https://example.com/fragment-integer"
    document = %{
      "type" => "object",
      "entry" => %{"$ref" => "#/$defs/selected"},
      "$defs" => %{
        "selected" => %{
          "definitions" => %{"integer" => %{"$id" => uri, "type" => "integer"}},
          "allOf" => [%{"$ref" => uri}]
        },
        "ignored" => %{"$id" => "https://example.com/ignored", "type" => 42}
      }
    }

    assert {:ok, compiled} = JSONSchex.compile_fragment(document, entry: "#/entry", draft: "draft7")
    assert Map.has_key?(compiled.defs, uri)
    refute Map.has_key?(compiled.defs, "https://example.com/ignored")
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
  end

  test "Draft 7 fragment-only IDs do not replace the enclosing pointer resource" do
    poison_uri = "https://example.com/fragment-decoy"
    poison = %{"definitions" => %{"bad" => %{"$id" => poison_uri, "type" => 42}}}
    schema = %{
      "$id" => "https://example.com/root",
      "$defs" => %{"pick" => true},
      "definitions" => %{
        "anchored" => %{
          "$id" => "#anchor",
          "allOf" => [%{"$ref" => "#/$defs/pick"}],
          "$defs" => %{"pick" => poison}
        }
      }
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, "https://example.com/root#anchor")
      refute Map.has_key?(compiled.defs, poison_uri)
    end
  end

  test "Draft 7 discovery retains the resource before fragment IDs along a pointer route" do
    uri = "https://example.com/nested/integer"
    schema = %{
      "$ref" => "#/definitions/nested/definitions/anchored",
      "definitions" => %{
        "nested" => %{
          "$id" => "https://example.com/nested/",
          "$defs" => %{
            "pick" => %{"definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}}}
          },
          "definitions" => %{
            "anchored" => %{
              "$id" => "#anchor",
              "allOf" => [%{"$ref" => "#/$defs/pick"}],
              "$defs" => %{"pick" => %{"$id" => "https://example.com/fragment-decoy", "type" => 42}}
            }
          }
        }
      }
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, uri)
      refute Map.has_key?(compiled.defs, "https://example.com/fragment-decoy")
    end
  end

  test "Draft 7 selected-entry discovery carries owners across ignored resource ancestors" do
    poison_uri = "https://example.com/outer-fragment-decoy"
    document = %{
      "type" => "object",
      "$defs" => %{
        "holder" => %{
          "$id" => "https://example.com/nested",
          "entry" => %{"$ref" => "#/$defs/pick"},
          "$defs" => %{"pick" => true}
        },
        "pick" => %{"definitions" => %{"bad" => %{"$id" => poison_uri, "type" => 42}}}
      }
    }

    {scopes, refs} = JSONSchex.ScopeScanner.scan_all(document, nil,
      draft: "draft7", schema_path: ["$defs", "holder", "entry"])
    refute Map.has_key?(scopes, poison_uri)
    assert refs == MapSet.new(["#/$defs/pick"])
    assert {:ok, compiled} = JSONSchex.compile_fragment(document,
      entry: "#/$defs/holder/entry", draft: "draft7")
    refute Map.has_key?(compiled.defs, poison_uri)
  end

  test "Selected fragment compilation agrees with inherited discovery base" do
    resource_uri = "https://example.com/nested/integer"
    document = %{
      "type" => "object",
      "$defs" => %{
        "holder" => %{
          "$id" => "https://example.com/nested/",
          "entry" => %{
            "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}},
            "allOf" => [%{"$ref" => "integer"}]
          }
        }
      }
    }

    # $defs is intentionally unknown in Draft 7; :entry explicitly selects a schema
    # from this document data. Ancestor-ID inheritance is a fragment API contract,
    # not automatic evaluation of $defs as a schema keyword.
    assert {:ok, compiled} = JSONSchex.compile_fragment(document,
      entry: "#/$defs/holder/entry",
      base_uri: "https://example.com/base/root.json",
      draft: "draft7")

    # Discovery already uses the ancestor ID; entry validation must use that same base.
    assert Map.has_key?(compiled.defs, resource_uri)
    refute Map.has_key?(compiled.defs, "https://example.com/base/integer")
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
             JSONSchex.validate(compiled, "1")
  end

  test "Discovery follows pointers into another registered resource" do
    for ref <- ["https://example.com/b#/$defs/selected", "b#/$defs/selected"] do
      {schema, resource_uri, integer_uri, ignored_uri} = registered_resource_pointer_schema(ref)
      {scopes, refs} = JSONSchex.ScopeScanner.scan(schema, draft: "draft7")

      # B is already known; following its pointer must not require an external loader.
      assert Map.has_key?(scopes, resource_uri)
      refute Map.has_key?(scopes, ignored_uri)
      assert refs == MapSet.new()
      assert Map.has_key?(scopes, integer_uri)
    end
  end

  test "Schema validation follows a pointer into a registered resource" do
    for ref <- ["https://example.com/b#/$defs/selected", "b#/$defs/selected"] do
      {schema, resource_uri, integer_uri, ignored_uri} = registered_resource_pointer_schema(ref)
      compiled = compile_schema!(schema, "schema", draft: "draft7")

      assert Map.has_key?(compiled.defs, resource_uri)
      refute Map.has_key?(compiled.defs, ignored_uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
      assert Map.has_key?(compiled.defs, integer_uri)
    end
  end

  test "Fragment validation follows a pointer into a registered resource" do
    for ref <- ["https://example.com/b#/$defs/selected", "b#/$defs/selected"] do
      {schema, resource_uri, integer_uri, ignored_uri} = registered_resource_pointer_schema(ref)
      compiled = compile_schema!(schema, "document", draft: "draft7")

      assert Map.has_key?(compiled.defs, resource_uri)
      refute Map.has_key?(compiled.defs, ignored_uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
      assert Map.has_key?(compiled.defs, integer_uri)
    end
  end

  test "Registered-resource pointer fixtures validate in Draft 2020-12" do
    # Here $defs is a recognized keyword, so discovery may visit both entries.
    # Excluding the unselected sibling is asserted only in the Draft 7 cases.
    for ref <- ["https://example.com/b#/$defs/selected", "b#/$defs/selected"],
        mode <- ["schema", "document"] do
      {schema, resource_uri, integer_uri, _ignored_uri} = registered_resource_pointer_schema(ref)
      compiled = compile_schema!(schema, mode, draft: "draft2020_12")

      assert Map.has_key?(compiled.defs, resource_uri)
      assert Map.has_key?(compiled.defs, integer_uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 selected fragment applies ancestor and entry IDs once through escaped array paths" do
    entry_uri = "https://example.com/base/nested/entry/"
    resource_uri = entry_uri <> "integer"
    document = %{
      "$id" => "root/",
      "$defs" => %{
        "holders" => [%{
          "$id" => "../nested/",
          "entry/with~tokens" => %{
            "$id" => "entry/",
            "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}},
            "allOf" => [%{"$ref" => "integer"}]
          }
        }]
      }
    }

    for index <- ["0", "00", "-1"] do
      assert {:ok, compiled} = JSONSchex.compile_fragment(document,
        entry: "#/$defs/holders/" <> index <> "/entry~1with~0tokens",
        base_uri: "https://example.com/base/document.json", draft: "draft7")
      assert compiled.source_id == entry_uri
      assert Map.has_key?(compiled.defs, resource_uri)
      refute Map.has_key?(compiled.defs, entry_uri <> "entry/integer")
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 inherited bases preserve decoded tokens from both pointer representations" do
    root_uri = "https://example.com/root/"
    entry = %{
      "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}},
      "allOf" => [%{"$ref" => "integer"}]
    }
    document = %{
      "$id" => root_uri,
      "containers" => %{
        "literal%2Fkey" => %{"$id" => "literal/", "entry" => entry},
        "literal~1key" => %{"$id" => "tilde/", "entry" => entry},
        "slash/key~" => %{"$id" => "escaped/", "entry" => entry},
        "space key" => %{"$id" => "space/", "entry" => entry},
        "unicode-雪" => %{"$id" => "unicode/", "entry" => entry}
      }
    }

    # Percent escapes are literal in JSON-string pointers and decoded once in URI
    # fragments. Decoded ~1 sequences must stay literal during ancestor traversal.
    # Both selection and ancestor traversal must reach the same holder.
    for {pointer, suffix} <- [
          {"/containers/literal%2Fkey/entry", "literal/"},
          {"#/containers/literal%252Fkey/entry", "literal/"},
          {"https://example.com/document#/containers/literal%252Fkey/entry", "literal/"},
          {"/containers/literal~01key/entry", "tilde/"},
          {"#/containers/literal~01key/entry", "tilde/"},
          {"/containers/slash~1key~0/entry", "escaped/"},
          {"#/containers/slash~1key~0/entry", "escaped/"},
          {"#/containers/slash%7E1key%7E0/entry", "escaped/"},
          {"/containers/space key/entry", "space/"},
          {"#/containers/space%20key/entry", "space/"},
          {"https://example.com/document#/containers/space%20key/entry", "space/"},
          {"/containers/unicode-雪/entry", "unicode/"},
          {"#/containers/unicode-%E9%9B%AA/entry", "unicode/"}
        ] do
      assert {:ok, compiled} = JSONSchex.compile_fragment(document, entry: pointer, draft: "draft7")
      assert compiled.source_id == root_uri <> suffix
      assert Map.has_key?(compiled.defs, root_uri <> suffix <> "integer")
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 inherited entry bases ignore ref sibling IDs and preserve ancestor registrations" do
    root_uri = "https://example.com/root/"
    document = %{
      "$id" => root_uri,
      "$defs" => %{
        "holder" => %{
          "$ref" => "#/unused",
          "$id" => "https://wrong.example/",
          "entry" => %{
            "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}},
            "allOf" => [%{"$ref" => "integer"}]
          }
        }
      }
    }

    assert {:ok, compiled} = JSONSchex.compile_fragment(document,
      entry: "#/$defs/holder/entry", draft: "draft7")
    assert compiled.source_id == root_uri
    assert Map.has_key?(compiled.defs, root_uri <> "integer")
    refute Map.has_key?(compiled.defs, "https://wrong.example/")
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")

    # Sharing an inherited source URI does not make the entry the resource root.
    registered_root = Map.fetch!(compiled.defs, root_uri)
    assert registered_root.raw === document
    assert :ok == JSONSchex.validate(registered_root, "not an integer")
  end

  test "Draft 7 selected fragments resolve absolute pointers against their inherited resource" do
    resource_uri = "https://example.com/resource"
    resource = %{
      "$id" => resource_uri,
      "definitions" => %{"value" => %{"type" => "integer"}},
      "entry" => %{"$ref" => resource_uri <> "#/definitions/value"}
    }
    loader = fn uri -> flunk("Unexpected external load: #{uri}") end

    # $defs is an unknown annotation in Draft 7. Explicit selection must retain
    # its ancestor resource even when ordinary discovery does not register it.
    for keyword <- ["definitions", "$defs"],
        base_uri <- [nil, "https://example.com/document.json"] do
      document = %{
        "type" => "object",
        "definitions" => %{"value" => %{"type" => "string"}}
      }
      document = Map.update(document, keyword, %{"resource" => resource},
        &Map.put(&1, "resource", resource))

      assert {:ok, compiled} = JSONSchex.compile_fragment(document,
        entry: "#/" <> keyword <> "/resource/entry", base_uri: base_uri,
        draft: "draft7", loader: loader)

      # No eager local alias should hide which raw root JIT pointer lookup uses.
      refute Map.has_key?(compiled.defs, "#/definitions/value")
      assert compiled.source_id == resource_uri
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
      assert compiled.raw === resource
    end
  end

  test "Draft 7 selected fragment pointer roots preserve relative and fragment-only ID scopes" do
    resource_uri = "https://example.com/base/resource/"
    entry = %{"$ref" => resource_uri <> "#/definitions/value"}

    # Fragment-only IDs name a location within the resource. A $ref sibling ID
    # is ignored entirely; neither should replace the resource's pointer root.
    for {metadata, source_id} <- [
          {%{}, resource_uri},
          {%{"$id" => "#named"}, resource_uri <> "#named"},
          {%{"$ref" => "#/unused", "$id" => "https://wrong.example/"}, resource_uri}
        ] do
      holder = Map.put(metadata, "entry", entry)
      resource = %{
        "$id" => "../resource/",
        "definitions" => %{"value" => %{"type" => "integer"}},
        "holders" => [holder]
      }
      document = %{
        "$id" => "root/",
        "definitions" => %{
          "value" => %{"type" => "string"},
          "resource" => resource
        }
      }

      assert {:ok, compiled} = JSONSchex.compile_fragment(document,
        entry: "#/definitions/resource/holders/00/entry",
        base_uri: "https://example.com/base/document.json", draft: "draft7")

      refute Map.has_key?(compiled.defs, "#/definitions/value")
      assert compiled.source_id == source_id
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
      assert compiled.raw === resource
    end
  end

  test "Draft 7 fragment-only entry scopes retain their resource without an absolute retrieval base" do
    for resource_id <- ["resource/", "resource.json"] do
      document = %{
        "$id" => resource_id,
        "type" => "integer",
        "holders" => [%{"$id" => "#named", "entry" => %{"$ref" => ""}}]
      }

      assert {:ok, compiled} = JSONSchex.compile_fragment(document,
        entry: "#/holders/0/entry", draft: "draft7")

      # URI resolution can fall back to the fragment when the base is relative;
      # that fallback must not turn the holder into a new pointer resource.
      assert compiled.raw === document
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 selected entry IDs establish their own pointer resource" do
    entry_uri = "https://example.com/resource/entry/"
    entry = %{
      "$id" => "entry/",
      "definitions" => %{"value" => %{"type" => "integer"}},
      "allOf" => [%{"$ref" => entry_uri <> "#/definitions/value"}]
    }
    document = %{
      "definitions" => %{
        "value" => %{"type" => "string"},
        "resource" => %{"$id" => "https://example.com/resource/", "entry" => entry}
      }
    }

    assert {:ok, compiled} = JSONSchex.compile_fragment(document,
      entry: "#/definitions/resource/entry", draft: "draft7")

    refute Map.has_key?(compiled.defs, "#/definitions/value")
    assert compiled.source_id == entry_uri
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
             JSONSchex.validate(compiled, "1")
    assert compiled.raw === entry
  end

  test "Draft 7 selected fragments without a new resource retain the document pointer root" do
    document_uri = "https://example.com/document"
    document = %{
      "$id" => document_uri,
      "definitions" => %{"value" => %{"type" => "integer"}},
      "entry" => %{"$ref" => document_uri <> "#/definitions/value"}
    }

    assert {:ok, compiled} = JSONSchex.compile_fragment(document,
      entry: "#/entry", draft: "draft7")

    assert compiled.source_id == document_uri
    assert compiled.raw === document
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
  end

  test "Draft 7 cross-resource discovery applies relative resource and target IDs once" do
    resource_uri = "https://example.com/b/"
    target_uri = resource_uri <> "selected/"
    integer_uri = target_uri <> "integer"
    ignored_uri = "https://example.com/cross-resource-decoy"
    schema = %{
      "$id" => "https://example.com/a",
      "definitions" => %{
        "b" => %{
          "$id" => "b/",
          "$defs" => %{
            "selected" => %{
              "$id" => "selected/",
              "definitions" => %{"integer" => %{"$id" => "integer", "type" => "integer"}},
              "allOf" => [%{"$ref" => "integer"}]
            },
            "ignored" => %{"$id" => ignored_uri, "type" => 42}
          }
        }
      },
      "allOf" => [%{"$ref" => "b/#/$defs/selected"}]
    }

    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, resource_uri)
      assert Map.has_key?(compiled.defs, target_uri)
      assert Map.has_key?(compiled.defs, integer_uri)
      refute Map.has_key?(compiled.defs, "https://example.com/b/b/selected/integer")
      refute Map.has_key?(compiled.defs, ignored_uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 discovery retries pointers after their resource is discovered without external loading" do
    {initial, resource_uri, integer_uri, ignored_uri} =
      registered_resource_pointer_schema("https://example.com/b#/$defs/selected")
    resource = put_in(initial["definitions"]["b"], ["$defs", "ignored", "type"], 42)
    schema = %{
      "$id" => "https://example.com/a",
      "allOf" => [
        %{"$ref" => "#/$defs/activate"},
        %{"$ref" => "b#/$defs/selected"}
      ],
      "$defs" => %{"activate" => %{"definitions" => %{"b" => resource}}}
    }
    loader = fn uri -> flunk("Unexpected external load: #{uri}") end

    # References are queued in reverse traversal order: B is attempted before activate.
    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7", loader: loader)
      assert Map.has_key?(compiled.defs, resource_uri)
      assert Map.has_key?(compiled.defs, integer_uri)
      refute Map.has_key?(compiled.defs, ignored_uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 7 discovery terminates cycles between pointers in registered resources" do
    {schema, resource_uri, integer_uri, ignored_uri} =
      registered_resource_pointer_schema("https://example.com/b#/$defs/selected")
    schema = put_in(schema, ["definitions", "b", "$defs", "selected", "allOf"],
      [%{"$ref" => "https://example.com/a#/$defs/cycle"}])
    schema = Map.put(schema, "$defs", %{
      "cycle" => %{"$ref" => "https://example.com/b#/$defs/selected"}
    })

    # Assert discovery/compilation only, not validation of an unconditional ref cycle.
    for mode <- ["schema", "document"] do
      compiled = compile_schema!(schema, mode, draft: "draft7")
      assert Map.has_key?(compiled.defs, resource_uri)
      assert Map.has_key?(compiled.defs, integer_uri)
      refute Map.has_key?(compiled.defs, ignored_uri)
    end
  end

  defp registered_resource_pointer_schema(ref) do
    resource_uri = "https://example.com/b"
    integer_uri = "https://example.com/integer"
    ignored_uri = "https://example.com/ignored-resource-sibling"
    schema = %{
      "$id" => "https://example.com/a",
      "definitions" => %{
        "b" => %{
          "$id" => resource_uri,
          # In Draft 7 this unknown keyword must not trigger eager traversal. The
          # explicit URI pointer selects "selected" only, leaving "ignored" inactive.
          # Native definitions would conceal the discovery gap exercised here.
          "$defs" => %{
            "selected" => %{
              "definitions" => %{"integer" => %{"$id" => integer_uri, "type" => "integer"}},
              # An absolute child reference isolates discovery from JIT local-root issues.
              "allOf" => [%{"$ref" => integer_uri}]
            },
            "ignored" => %{"$id" => ignored_uri, "type" => "null"}
          }
        }
      },
      "allOf" => [%{"$ref" => ref}]
    }

    {schema, resource_uri, integer_uri, ignored_uri}
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

defmodule JSONSchex.Test.SchemaTraversal do
  use ExUnit.Case, async: true

  doctest JSONSchex.ScopeScanner

  alias JSONSchex.{SchemaTraversal, ScopeScanner}

  test "scanner dispatch defaults to Draft 2020-12 and preserves draft-specific ref semantics" do
    uri = "https://example.test/root"
    child_uri = "https://example.test/child"
    child = %{"$id" => child_uri, "type" => "integer"}
    schema = %{
      "$id" => uri,
      "$anchor" => "static",
      "$dynamicAnchor" => "dynamic",
      "$ref" => "#/definitions/child",
      "$dynamicRef" => "#dynamic",
      "definitions" => %{"child" => child}
    }
    expected = {
      %{uri => schema, uri <> "#static" => schema, uri <> "#dynamic" => schema, child_uri => child},
      MapSet.new(["#/definitions/child", "#dynamic"])
    }

    assert ScopeScanner.scan(schema) == expected
    assert ScopeScanner.scan(schema, draft: "draft2020_12") == expected
    assert ScopeScanner.scan(schema, draft: "draft7") == {%{child_uri => child}, MapSet.new(["#/definitions/child"])}

    document = %{"entry" => schema}
    assert ScopeScanner.scan_all(document) == expected
    assert ScopeScanner.scan_all(document, nil, draft: "draft2020_12", schema_path: ["entry"]) == expected
    # The pointer belongs to the containing document, which has no root definitions.
    assert ScopeScanner.scan_all(document, nil, draft: "draft7", schema_path: ["entry"]) ==
             {%{}, MapSet.new(["#/definitions/child"])}
  end

  test "both draft scanners retain duplicate-identity precedence and raw registry entries" do
    uri = "https://example.test/repeated"
    properties = Map.new(1..40, fn index -> {"property-#{index}", %{"$id" => uri, "const" => index}} end)
    schema = %{"properties" => properties}
    expected = properties |> Map.values() |> List.last()
    expected_document = Enum.reduce(properties, nil, fn {_name, child}, _previous -> child end)

    for draft <- ["draft7", "draft2020_12"] do
      assert ScopeScanner.scan(schema, draft: draft) == {%{uri => expected}, MapSet.new()}
      assert ScopeScanner.scan_all(schema, nil, draft: draft) == {%{uri => expected_document}, MapSet.new()}
    end
  end

  test "document scanning remains broader than schema scanning and resolves the document base" do
    base_uri = "https://example.test/document.json"
    uri = "https://example.test/child"
    child = %{"$id" => "child", "type" => "integer"}
    document = %{"extension" => [child]}

    for draft <- ["draft7", "draft2020_12"] do
      assert ScopeScanner.scan(document, draft: draft) == {%{}, MapSet.new()}
      assert ScopeScanner.scan_all(document, base_uri, draft: draft) == {%{uri => child}, MapSet.new()}
    end
  end

  test "both draft scanners honor the initial base before relative root and nested IDs" do
    base_uri = "https://example.test/base/document.json"
    root_uri = "https://example.test/base/schemas/"
    child_uri = root_uri <> "integer.json"
    child = %{"$id" => "integer.json", "type" => "integer"}
    schema = %{"$id" => "schemas/", "definitions" => %{"integer" => child}}
    expected = {%{root_uri => schema, child_uri => child}, MapSet.new()}

    for draft <- ["draft7", "draft2020_12"] do
      assert ScopeScanner.scan(schema, draft: draft, base_uri: base_uri) == expected
      assert ScopeScanner.scan_all(schema, base_uri, draft: draft) == expected
      assert ScopeScanner.scan(schema, draft: draft) ==
               ScopeScanner.scan(schema, draft: draft, base_uri: nil)
    end
  end

  test "both drafts compile relative embedded resources against the retrieval base" do
    base_uri = "https://example.test/base/document.json"

    for draft <- ["draft7", "draft2020_12"], root_id <- [nil, "schemas/"] do
      uri = if root_id, do: "https://example.test/base/schemas/integer.json", else: "https://example.test/base/integer.json"
      schema = %{
        "definitions" => %{"integer" => %{"$id" => "integer.json", "type" => "integer"}},
        "allOf" => [%{"$ref" => uri}]
      }
      schema = if root_id, do: Map.put(schema, "$id", root_id), else: schema

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: draft, base_uri: base_uri)
      assert Map.has_key?(compiled.defs, uri)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "1")
    end
  end

  test "Draft 2020-12 anchors use the retrieval base without a root ID" do
    base_uri = "https://example.test/base/document.json"
    schema = %{"$anchor" => "static", "$dynamicAnchor" => "dynamic", "$dynamicRef" => "#dynamic"}
    expected = {
      %{base_uri <> "#static" => schema, base_uri <> "#dynamic" => schema},
      MapSet.new(["#dynamic"])
    }

    assert ScopeScanner.scan(schema, draft: "draft2020_12", base_uri: base_uri) == expected
    assert ScopeScanner.scan(schema, draft: "draft7", base_uri: base_uri) == {%{}, MapSet.new()}
  end

  test "Draft 7 never registers newer anchors or collects dynamic refs from document metadata" do
    base_uri = "https://example.test/document.json"
    metadata = %{"$anchor" => "static", "$dynamicAnchor" => "dynamic", "$dynamicRef" => "#/target"}
    document = %{"metadata" => metadata}
    expected = {
      %{base_uri <> "#static" => metadata, base_uri <> "#dynamic" => metadata},
      MapSet.new(["#/target"])
    }

    assert ScopeScanner.scan_all(document, base_uri, draft: "draft2020_12") == expected
    assert ScopeScanner.scan_all(document, base_uri, draft: "draft7") == {%{}, MapSet.new()}
    assert ScopeScanner.scan(metadata, draft: "draft7") == {%{}, MapSet.new()}
    assert ScopeScanner.scan_all(document, base_uri, draft: "draft7", schema_path: ["metadata"]) ==
             {%{}, MapSet.new()}
    assert ScopeScanner.scan_all(document, base_uri, draft: "draft2020_12", schema_path: ["metadata"]) == expected
  end

  test "Draft 7 document dynamic-ref annotations do not eagerly compile their targets" do
    document = %{
      "metadata" => %{"$anchor" => "ignored", "$dynamicAnchor" => "also-ignored", "$dynamicRef" => "#/unused"},
      "unused" => %{"type" => 42},
      "entry" => %{"type" => "integer"}
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document, entry: "#/entry", draft: "draft7")
    refute Map.has_key?(compiled.defs, "#ignored")
    refute Map.has_key?(compiled.defs, "#also-ignored")
    refute Map.has_key?(compiled.defs, "#/unused")
    assert :ok == JSONSchex.validate(compiled, 42)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "42")
  end

  test "Draft 7 still registers fragment IDs and collects ordinary refs" do
    uri = "https://example.test/root"
    child = %{"$id" => "#integer", "$anchor" => "ignored", "type" => "integer"}
    schema = %{
      "$id" => uri,
      "definitions" => %{"integer" => child},
      "properties" => %{"value" => %{"$ref" => "#integer"}}
    }
    expected = {%{uri => schema, uri <> "#integer" => child}, MapSet.new(["#integer"])}

    assert ScopeScanner.scan(schema, draft: "draft7") == expected
    assert ScopeScanner.scan_all(schema, nil, draft: "draft7") == expected
  end

  test "Draft 7 document scanning prunes both resources and refs inside actual schema annotations" do
    child = %{"$id" => "https://example.test/ignored", "$ref" => "#/missing"}

    for keyword <- ["$defs", "prefixItems", "contentSchema", "additionalItems",
                    "$anchor", "$dynamicAnchor", "$dynamicRef"],
        schema <- [%{"type" => "integer", keyword => child},
                   %{"const" => 42, keyword => child},
                   %{"default" => %{}, keyword => child},
                   %{"examples" => [], keyword => child},
                   %{"properties" => %{"value" => %{keyword => child}}}] do
      document = %{"arbitrary" => [schema]}
      {registry, refs} = ScopeScanner.scan_all(document, nil, draft: "draft7")

      refute Map.has_key?(registry, "https://example.test/ignored")
      refute MapSet.member?(refs, "#/missing")
    end
  end

  test "Draft 7 schema-map keys are names rather than reference or identity keywords" do
    child = %{"$id" => "https://example.test/named", "type" => "integer"}

    for keyword <- ["properties", "patternProperties", "definitions", "dependencies"],
        name <- ["$ref", "$id", "$defs", "prefixItems", "$anchor", "$dynamicAnchor", "$dynamicRef"] do
      document = %{"arbitrary" => %{keyword => %{name => child}}}
      {registry, refs} = ScopeScanner.scan_all(document, nil, draft: "draft7")

      assert registry == %{"https://example.test/named" => child}
      assert refs == MapSet.new()
    end
  end

  test "newer keyword names remain ordinary names in arbitrary Draft 7 document containers" do
    uri = "https://example.test/named"
    child = %{"$id" => uri, "type" => "integer"}

    for name <- ["$anchor", "$dynamicAnchor", "$dynamicRef"] do
      document = %{"arbitrary" => %{name => child}}
      assert ScopeScanner.scan_all(document, nil, draft: "draft7") == {%{uri => child}, MapSet.new()}
    end
  end

  test "scope reduction preserves Map.values traversal and duplicate-identity precedence" do
    target_uri = "https://example.test/repeated"

    properties =
      Map.new(1..40, fn index ->
        {"property-#{index}",
         %{
           "$id" => target_uri,
           "$anchor" => "shared",
           "const" => index
         }}
      end)

    expected = properties |> Map.values() |> List.last()
    schema = %{"properties" => properties, "$ref" => target_uri}

    reduced =
      schema
      |> SchemaTraversal.reduce_scope_subschemas([],
        fn subschema, acc ->
          [subschema | acc]
        end)
      |> Enum.reverse()

    assert reduced === SchemaTraversal.scope_subschemas(schema)

    {registry, _refs} = ScopeScanner.scan(schema)
    assert Map.fetch!(registry, target_uri) === expected
    assert Map.fetch!(registry, target_uri <> "#shared") === expected

    assert {:ok, compiled} = JSONSchex.compile(schema)
    assert Map.fetch!(compiled.defs, target_uri).raw === expected
  end
end

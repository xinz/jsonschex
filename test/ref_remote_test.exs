defmodule JSONSchex.Test.RefRemote do
  use ExUnit.Case

  test "remote HTTP ref with different $id" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "http://localhost:1234/different-id-ref-string.json"
    }

    assert {:ok, c} = JSONSchex.compile(schema, loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert {:error, _e} = JSONSchex.validate(c, 1)
  end

  test "a Draft 7 schema rejects a remote Draft 2020-12 declaration" do
    remote_uri = "https://example.com/remote-schema.json"
    parent = self()

    loader = fn
      ^remote_uri ->
        send(parent, {:loaded, remote_uri})
        {:ok, %{"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "integer"}}
    end

    schema = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "$ref" => remote_uri
    }

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: loader)
    assert compiled.draft == "draft7"

    assert {:error, [%{rule: :ref, context: %{contrast: "load_remote", error_detail: detail}}]} =
             JSONSchex.validate(compiled, 1)

    assert_received {:loaded, ^remote_uri}
    assert detail.contrast == "compile_remote"
    assert detail.error_detail.rule == :draft_conflict
    assert detail.error_detail.value == "https://json-schema.org/draft/2020-12/schema"
    assert detail.error_detail.context.input == "draft7"
  end

  test "root ref in remote ref" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/object",
      "type" => "object",
      "properties" => %{
          "name" => %{"$ref" => "name-defs.json#/$defs/orNull"}
      }
    }
    assert {:ok, c} = JSONSchex.compile(schema, loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert :ok == JSONSchex.validate(c, %{"name" => "foo"})
    assert :ok == JSONSchex.validate(c, %{"name" => nil})
    assert {:error, _} = JSONSchex.validate(c, 1)
    assert {:error, _} = JSONSchex.validate(c, %{"name" => %{"foo" => "bar"}})
  end

  test "base URI change - change folder in subschema" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/scope_change_defs2.json",
      "type" => "object",
      "properties" => %{
          "list" => %{
              "$ref" => "baseUriChangeFolderInSubschema/#/$defs/bar"
          }
      },
      "$defs" => %{
        "baz"=> %{
           "$id" => "baseUriChangeFolderInSubschema/",
           "$defs" => %{
             "bar" => %{
               "type" => "array",
               "items" => %{"$ref" => "folderInteger.json"}
             }
           }
        }
      }
    }
    assert {:ok, c} = JSONSchex.compile(schema, loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert :ok == JSONSchex.validate(c, %{"list" => [1]})
    assert {:error, [e]} = JSONSchex.validate(c, %{"list" => ["1"]})
    assert e.rule == :type
  end

  test "retrieved nested refs resolve relative to their URI not $id" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/some-id",
      "properties" => %{
          "name" => %{"$ref" => "nested/foo-ref-string.json"}
      }
    }
    assert {:ok, c} = JSONSchex.compile(schema, loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert :ok == JSONSchex.validate(c, %{"name" => %{"foo" => "a"}})
    assert {:error, _e} = JSONSchex.validate(c, %{"name" => %{"foo" => 1}})
  end

  test "explicit local $ref is statically pre-compiled into defs" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "foo" => %{"type" => "string"},
        "bar" => %{"$ref" => "#/properties/foo"}
      }
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)

    assert Map.has_key?(compiled.defs, "#/properties/foo")

    assert :ok == JSONSchex.validate(compiled, %{"bar" => "hello"})
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"bar" => 123})
  end

  defp dummy_loader("http://example.com/remote.json" <> _) do
    {:ok, %{
      "type" => "object",
      "properties" => %{
        "foo" => %{"type" => "integer"}
      }
    }}
  end
  defp dummy_loader(_), do: {:error, "not found"}

  test "dynamic fallback to JIT compilation for unextracted remote references (avoids infinite loop)" do
    # The remote schema does NOT contain any internal `$ref`, so `#/properties/foo`
    # is NOT statically pre-compiled during the compilation of the remote schema.
    # Therefore, when validate_ref resolves it against the remote schema, it must fallback
    # to resolve_and_validate_jit without looping infinitely.
    schema = %{
      "$ref" => "http://example.com/remote.json#/properties/foo"
    }

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: &dummy_loader/1)

    assert :ok == JSONSchex.validate(compiled, 42)

    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "not an integer")
  end

  test "JIT pointer targets inherit ancestor $ids in both drafts" do
    parent = self()
    root_uri = "https://example.com/base/root/entry.json"
    leaf_uri = "https://example.com/base/root/nested/leaf.json"
    pointer = root_uri <> "#/$defs/parent/properties/value"

    loader = fn
      ^leaf_uri ->
        send(parent, {:loaded, leaf_uri})
        {:ok, %{"type" => "integer"}}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, {:unexpected_uri, uri}}
    end

    document = %{
      "$id" => "root/entry.json",
      "$ref" => pointer,
      "$defs" => %{
        "parent" => %{
          "$id" => "nested/",
          "properties" => %{"value" => %{"$ref" => "leaf.json"}}
        }
      }
    }

    for draft <- ["draft2020_12", "draft7"] do
      assert {:ok, compiled} =
               JSONSchex.compile_fragment(document,
                 entry: "#",
                 base_uri: "https://example.com/base/",
                 loader: loader,
                 draft: draft
               )

      refute Map.has_key?(compiled.defs, pointer)
      assert :ok == JSONSchex.validate(compiled, 42)
      assert_received {:loaded, ^leaf_uri}
      refute_received {:unexpected_load, _}
      assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "42")
      assert_received {:loaded, ^leaf_uri}
      refute_received {:unexpected_load, _}
    end
  end

  test "invalid dynamic JIT fallback returns error instead of crashing" do
    schema = %{
      "$ref" => "http://example.com/remote.json#/properties/does_not_exist"
    }

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: &dummy_loader/1)

    assert {:error, [%{rule: :ref, context: %{contrast: "ref_not_found"}}]} =
             JSONSchex.validate(compiled, 42)
  end
end

defmodule JSONSchex.Test.RefContextRegression do
  use ExUnit.Case

  for draft <- ["draft7", "draft2020_12"] do
    @draft draft

    test "remote pointer accepts its own value despite a caller-local alias (#{draft})" do
      {compiled, remote_uri} = compile_alias_collision(@draft)

      result = JSONSchex.validate(compiled, "remote")
      assert_received {:loaded, ^remote_uri}
      assert :ok == result
    end

    test "remote pointer rejects the caller-only value despite a caller-local alias (#{draft})" do
      {compiled, remote_uri} = compile_alias_collision(@draft)

      result = JSONSchex.validate(compiled, "outer")
      assert_received {:loaded, ^remote_uri}
      assert {:error, [%{rule: :const, context: %{contrast: "remote"}}]} = result
    end

    test "same-resource local pointers validate under anonymous and explicit bases (#{draft})" do
      pointer = "#/definitions/x"
      schema = %{"definitions" => %{"x" => %{"const" => "raw"}}, "$ref" => pointer}

      for base_uri <- [nil, "https://example.com/local.json"] do
        assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft, base_uri: base_uri)
        assert :ok == JSONSchex.validate(compiled, "raw")
        assert {:error, [%{rule: :const, context: %{contrast: "raw"}}]} =
                 JSONSchex.validate(compiled, "other")
      end
    end

    test "identical loaded documents resolve local pointers against their own bases (#{draft})" do
      pointer = "#/definitions/entry"
      raw = %{
        "definitions" => %{"entry" => %{"$ref" => "leaf.json"}},
        "allOf" => [%{"$ref" => pointer}]
      }
      caller_uri = "https://example.com/caller/root.json"
      resource_uri = "https://example.com/remote/root.json"
      caller_leaf = "https://example.com/caller/leaf.json"
      remote_leaf = "https://example.com/remote/leaf.json"
      parent = self()

      loader = fn
        ^caller_leaf ->
          # A caller-owned alias reused by the loaded document would loop here.
          refute_received {:loaded, ^caller_leaf}
          send(parent, {:loaded, caller_leaf})
          {:ok, %{document: raw, base_uri: resource_uri}}

        ^remote_leaf ->
          send(parent, {:loaded, remote_leaf})
          {:ok, %{"const" => "remote"}}

        uri ->
          flunk("Unexpected external load: #{uri}")
      end

      assert {:ok, compiled} = JSONSchex.compile(raw,
        draft: @draft, base_uri: caller_uri, loader: loader)
      assert :ok == JSONSchex.validate(compiled, "remote")
      assert_received {:loaded, ^caller_leaf}
      assert_received {:loaded, ^remote_leaf}

      assert {:error, [%{rule: :const, context: %{contrast: "remote"}}]} =
               JSONSchex.validate(compiled, "caller")
      assert_received {:loaded, ^caller_leaf}
      assert_received {:loaded, ^remote_leaf}
    end

    test "loaded snapshots at the caller's URI validate against their own definitions (#{draft})" do
      root_uri = "https://example.com/shared.json"
      remote_uri = "https://example.com/snapshot.json"
      pointer = "#/definitions/x"
      remote = %{
        "$id" => root_uri,
        "definitions" => %{"x" => %{"const" => "remote"}},
        "allOf" => [%{"$ref" => pointer}]
      }
      raw = %{
        "$id" => root_uri,
        "definitions" => %{"x" => %{"const" => "caller"}},
        "allOf" => [%{"$ref" => remote_uri}],
        "properties" => %{"unused" => %{"$ref" => pointer}}
      }
      loader = fn ^remote_uri -> {:ok, remote} end

      assert {:ok, compiled} = JSONSchex.compile(raw, draft: @draft, loader: loader)
      assert :ok == JSONSchex.validate(compiled, "remote")
      assert {:error, [%{rule: :const, context: %{contrast: "remote"}}]} =
               JSONSchex.validate(compiled, "caller")
    end

    test "remote aliases support boolean targets and targets with their own ID (#{draft})" do
      for target <- [true, false, %{"$id" => "target.json", "const" => "remote"}] do
        {compiled, remote_uri} = compile_alias_collision(@draft, target)
        value = if target == false, do: "outer", else: "remote"
        result = JSONSchex.validate(compiled, value)
        assert_received {:loaded, ^remote_uri}

        if target == false do
          assert {:error, [%{rule: :boolean_schema}]} = result
        else
          assert :ok == result
        end
      end
    end

    test "anonymous callers and loader overrides preserve escaped remote aliases (#{draft})" do
      keywords = if @draft == "draft7", do: ["definitions"], else: ["definitions", "$defs"]
      remote_uri = "https://example.com/retrieved.json"

      for keyword <- keywords do
        pointer = "#/" <> keyword <> "/a~1b~0c"
        remote = %{
          "$id" => "canonical.json",
          keyword => %{"a/b~c" => %{"const" => "remote"}},
          "properties" => %{"unused" => %{"$ref" => pointer}}
        }
        loader = fn ^remote_uri ->
          {:ok, %{document: remote, base_uri: "https://example.com/overridden/base.json"}}
        end
        schema = %{
          keyword => %{"a/b~c" => %{"const" => "outer"}},
          "allOf" => [%{"$ref" => remote_uri <> pointer}],
          "properties" => %{"unused" => %{"$ref" => pointer}}
        }

        assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft, loader: loader)
        assert Map.has_key?(compiled.defs, pointer)
        assert :ok == JSONSchex.validate(compiled, "remote")
        assert {:error, [%{rule: :const, context: %{contrast: "remote"}}]} =
                 JSONSchex.validate(compiled, "outer")
      end
    end

    test "embedded resource pointers do not reuse the containing document's alias (#{draft})" do
      pointer = "#/definitions/x"
      schema = %{
        "$id" => "https://example.com/root",
        "definitions" => %{"x" => %{"const" => "outer"}},
        "properties" => %{
          "unused" => %{"$ref" => pointer},
          "nested" => %{
            "$id" => "nested/",
            "definitions" => %{"x" => %{"const" => "inner"}},
            "properties" => %{"value" => %{"$ref" => pointer}}
          }
        }
      }

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft)
      assert Map.has_key?(compiled.defs, pointer)
      assert :ok == JSONSchex.validate(compiled, %{"nested" => %{"value" => "inner"}})
      assert {:error, [%{rule: :const, context: %{contrast: "inner"}}]} =
               JSONSchex.validate(compiled, %{"nested" => %{"value" => "outer"}})
    end

    test "remote traversal can return to the caller's own definitions (#{draft})" do
      root_uri = "https://example.com/root"
      remote_uri = "https://example.com/remote"
      pointer = "#/definitions/x"
      remote = %{
        "definitions" => %{
          "x" => %{"const" => "remote"},
          "entry" => %{"$ref" => root_uri <> "#/definitions/entry"}
        },
        "properties" => %{"unused" => %{"$ref" => pointer}}
      }
      loader = fn ^remote_uri -> {:ok, remote} end
      schema = %{
        "$id" => root_uri,
        "definitions" => %{
          "x" => %{"const" => "outer"},
          "entry" => %{"$ref" => pointer}
        },
        "allOf" => [%{"$ref" => remote_uri <> "#/definitions/entry"}],
        "properties" => %{"unused" => %{"$ref" => pointer}}
      }

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft, loader: loader)
      assert :ok == JSONSchex.validate(compiled, "outer")
      assert {:error, [%{rule: :const, context: %{contrast: "outer"}}]} =
               JSONSchex.validate(compiled, "remote")
    end

    test "non-root resource re-entry resolves local pointers in its own document (#{draft})" do
      caller_uri = "https://example.com/caller.json"
      a_uri = "https://example.com/a.json"
      # Exercise the canonical empty-fragment ID and its fragment-free retrieval alias.
      a_id = a_uri <> "#"
      b_uri = "https://example.com/b.json"
      pointer = "#/definitions/value"
      resource_a = %{
        "$id" => a_id,
        "definitions" => %{
          "value" => %{"const" => "remote-a"},
          "entry" => %{"$ref" => b_uri <> "#/definitions/entry"},
          "return" => %{"$ref" => pointer}
        },
        "properties" => %{"unused" => %{"$ref" => pointer}}
      }
      resource_b = %{
        "$id" => b_uri,
        "definitions" => %{"entry" => %{"$ref" => a_uri <> "#/definitions/return"}}
      }
      parent = self()
      loader = fn uri ->
        send(parent, {:loaded, uri})
        case uri do
          ^a_uri -> {:ok, resource_a}
          ^b_uri -> {:ok, resource_b}
          _ -> flunk("Unexpected external load: #{uri}")
        end
      end
      schema = %{
        "$id" => caller_uri,
        "allOf" => [%{"$ref" => a_uri <> "#/definitions/entry"}]
      }

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft, loader: loader)
      assert :ok == JSONSchex.validate(compiled, "remote-a")
      assert_received {:loaded, ^a_uri}
      assert_received {:loaded, ^b_uri}
      assert {:error, [%{rule: :const, context: %{contrast: "remote-a"}}]} =
               JSONSchex.validate(compiled, "other")
    end

    test "built-in pointer targets do not reuse caller-local aliases (#{draft})" do
      {keyword, uri} =
        if @draft == "draft7" do
          {"definitions", "http://json-schema.org/draft-07/schema"}
        else
          {"$defs", "https://json-schema.org/draft/2020-12/meta/validation"}
        end
      pointer = "#/" <> keyword <> "/nonNegativeInteger"
      schema = %{
        "$id" => "https://example.com/root",
        keyword => %{"nonNegativeInteger" => %{"const" => "outer"}},
        "allOf" => [%{"$ref" => uri <> pointer}],
        "properties" => %{"unused" => %{"$ref" => pointer}}
      }
      loader = fn uri -> flunk("Unexpected external load: #{uri}") end

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft, loader: loader)
      assert Map.has_key?(compiled.defs, pointer)
      assert :ok == JSONSchex.validate(compiled, 0)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "outer")
    end

    test "anonymous local anchors retain the enclosing pointer owner (#{draft})" do
      anchor = if @draft == "draft7", do: %{"$id" => "#named"}, else: %{"$anchor" => "named"}
      named = Map.put(anchor, "allOf", [%{"$ref" => "#/definitions/x"}])
      schema = %{
        "definitions" => %{"x" => %{"const" => "outer"}, "named" => named},
        "allOf" => [%{"$ref" => "#named"}]
      }

      for cached? <- [true, false] do
        assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft)
        compiled = if cached?, do: compiled, else: %{compiled | local_refs: %{}}
        assert :ok == JSONSchex.validate(compiled, "outer")
        assert {:error, [%{rule: :const, context: %{contrast: "outer"}}]} =
                 JSONSchex.validate(compiled, "inner")
      end
    end

    test "JIT local pointer retains its embedded resource root (#{draft})" do
      remote_uri = "https://example.com/remote.json"
      remote = %{
        "definitions" => %{
          "parent" => %{
            "$id" => "nested/",
            "definitions" => %{"value" => %{"type" => "integer"}},
            "properties" => %{
              "entry" => %{"$ref" => "#/definitions/value"}
            }
          }
        }
      }

      loader = fn ^remote_uri -> {:ok, remote} end
      schema = %{
        "$ref" => remote_uri <> "#/definitions/parent/properties/entry"
      }

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft, loader: loader)

      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
    end
  end

  test "returning to the root preserves the dialect of eagerly compiled pointers" do
    root_uri = "https://example.com/root.json"
    remote_uri = "https://example.com/remote.json"
    dialect_uri = "https://example.com/core-and-applicator"
    dialect = %{
      "$vocabulary" => %{
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://json-schema.org/draft/2020-12/vocab/applicator" => true
      }
    }
    remote = %{
      "$id" => remote_uri,
      "properties" => %{
        "value" => %{"const" => "remote"},
        "next" => %{"$ref" => root_uri}
      }
    }
    loader = fn
      ^dialect_uri -> {:ok, dialect}
      ^remote_uri -> {:ok, remote}
      uri -> flunk("Unexpected external load: #{uri}")
    end
    schema = %{
      "$id" => root_uri,
      "$schema" => dialect_uri,
      "definitions" => %{"value" => %{"const" => "ignored"}},
      "properties" => %{
        "value" => %{"$ref" => "#/definitions/value"},
        "next" => %{"$ref" => remote_uri}
      }
    }
    data = %{
      "value" => "caller",
      "next" => %{"value" => "remote", "next" => %{"value" => "caller"}}
    }

    assert {:ok, compiled} = JSONSchex.compile(schema, draft: "draft2020_12", loader: loader)
    assert :ok == JSONSchex.validate(compiled, %{"value" => "caller"})
    # Root pointers must retain their dialect; the remote resource still asserts const.
    assert :ok == JSONSchex.validate(compiled, data)
    assert {:error, [%{rule: :const, context: %{contrast: "remote"}}]} =
             JSONSchex.validate(compiled, put_in(data, ["next", "value"], "caller"))
  end

  test "canonical resource recovery preserves finalized pointer aliases" do
    remote_uri = "https://example.com/retrieved.json"
    remote = %{
      "$id" => "https://example.com/canonical.json",
      "$defs" => %{
        "a/b" => %{"const" => "decoy"},
        "a" => %{"b" => %{"const" => "correct"}}
      },
      "allOf" => [%{"$ref" => "#/$defs/a/b"}]
    }
    loader = fn ^remote_uri -> {:ok, remote} end

    assert {:ok, compiled} = JSONSchex.compile(%{"$ref" => remote_uri}, loader: loader)
    assert :ok == JSONSchex.validate(compiled, "correct")
    assert {:error, [%{rule: :const, context: %{contrast: "correct"}}]} =
             JSONSchex.validate(compiled, "decoy")
  end

  test "embedded resource definition caches use escaped pointer keys" do
    resource = %{
      "$id" => "nested/",
      "$defs" => %{
        "a/b" => %{"const" => "decoy"},
        "a%2Fb" => %{"const" => "literal-percent"},
        "a#b" => %{"const" => "hash"},
        "a" => %{"b" => %{"const" => "correct"}}
      },
      "properties" => %{
        "path" => %{"$ref" => "#/$defs/a/b"},
        "key" => %{"$ref" => "#/$defs/a~1b"},
        "encoded_path" => %{"$ref" => "#/$defs/a%2Fb"},
        "percent_key" => %{"$ref" => "#/$defs/a%252Fb"},
        "hash_key" => %{"$ref" => "#/$defs/a%23b"}
      }
    }
    schema = %{
      "$id" => "https://example.com/root",
      "properties" => %{"nested" => resource}
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(compiled, %{"nested" => %{
      "path" => "correct", "key" => "decoy", "encoded_path" => "correct",
      "percent_key" => "literal-percent", "hash_key" => "hash"
    }})
    assert {:error, [%{rule: :const, context: %{contrast: "correct"}}]} =
             JSONSchex.validate(compiled, %{"nested" => %{"path" => "decoy"}})
  end

  test "selected Draft 7 resource does not inherit containing-document aliases" do
    pointer = "#/definitions/x"
    resource = %{
      "$id" => "nested/",
      "definitions" => %{"x" => %{"const" => "inner"}},
      "entry" => %{"$ref" => pointer}
    }
    document = %{
      "$id" => "https://example.com/root",
      "definitions" => %{"x" => %{"const" => "outer"}, "holder" => resource}
    }

    assert {:ok, compiled} = JSONSchex.compile_fragment(document,
      entry: "#/definitions/holder/entry", draft: "draft7")
    assert Map.has_key?(compiled.defs, pointer)
    assert compiled.raw === resource
    assert :ok == JSONSchex.validate(compiled, "inner")
    assert {:error, [%{rule: :const, context: %{contrast: "inner"}}]} =
             JSONSchex.validate(compiled, "outer")
  end

  test "Draft 7 structural fragment IDs retain the enclosing pointer root and cache" do
    for root_id <- [nil, "resource/", "resource.json", "https://example.com/root"],
        cached? <- [true, false] do
      schema = %{
        "definitions" => %{"x" => %{"const" => "outer"}},
        "properties" => %{
          "value" => %{"$id" => "#named", "allOf" => [%{"$ref" => "#/definitions/x"}]}
        }
      }
      schema = if root_id, do: Map.put(schema, "$id", root_id), else: schema

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: "draft7")
      compiled = if cached?, do: compiled, else: %{compiled | local_refs: %{}}
      assert :ok == JSONSchex.validate(compiled, %{"value" => "outer"})
      assert {:error, [%{rule: :const, context: %{contrast: "outer"}}]} =
               JSONSchex.validate(compiled, %{"value" => "inner"})
    end
  end

  test "relative resource re-entry does not preserve a different caller's pointer root" do
    caller = %{
      "$id" => "caller.json",
      "allOf" => [%{"$ref" => "remote.json"}],
      "definitions" => %{
        "entry" => %{"$ref" => "remote.json#/definitions/target"},
        "value" => %{"const" => "caller"}
      }
    }
    remote = %{
      "$id" => "#remote",
      "allOf" => [%{"$ref" => "caller.json#/definitions/entry"}],
      "definitions" => %{
        "target" => %{"$ref" => "#/definitions/value"},
        "value" => %{"const" => "remote"}
      }
    }
    loader = fn "remote.json" -> {:ok, remote} end

    assert {:ok, compiled} = JSONSchex.compile(caller, draft: "draft7", loader: loader)
    assert :ok == JSONSchex.validate(compiled, "remote")
    assert {:error, [%{rule: :const, context: %{contrast: "remote"}}]} =
             JSONSchex.validate(compiled, "caller")
  end

  test "loaded fragment-only IDs do not conflate distinct relative resources" do
    caller = %{
      "$id" => "#caller",
      "allOf" => [%{"$ref" => "remote.json"}],
      "definitions" => %{
        "entry" => %{"$ref" => "#/definitions/value"},
        "value" => %{"const" => "caller"}
      }
    }
    remote = %{
      "$id" => "#remote",
      "allOf" => [%{"$ref" => "caller.json#/definitions/entry"}],
      "definitions" => %{"value" => %{"const" => "remote"}}
    }
    loader = fn
      "caller.json" -> {:ok, caller}
      "remote.json" -> {:ok, remote}
    end

    assert {:ok, compiled} = JSONSchex.compile(%{"$ref" => "caller.json"}, draft: "draft7", loader: loader)
    assert :ok == JSONSchex.validate(compiled, "caller")
    assert {:error, [%{rule: :const, context: %{contrast: "caller"}}]} =
             JSONSchex.validate(compiled, "remote")
  end

  test "selected fragment's local definitions are not aliases for its containing document" do
    document = %{
      "schema" => %{
        "$defs" => %{"x" => %{"const" => "entry-only"}},
        "$ref" => "#/$defs/x"
      }
    }

    assert {:ok, compiled} = JSONSchex.compile_fragment(document, entry: "#/schema")
    assert Map.has_key?(compiled.defs, "#/$defs/x")
    assert {:error, [%{rule: :ref, context: %{contrast: "ref_not_found"}}]} =
             JSONSchex.validate(compiled, "entry-only")
  end


  defp compile_alias_collision(draft, target \\ %{"const" => "remote"}) do
    remote_uri = "https://example.com/remote"
    remote = %{"definitions" => %{"x" => target}}
    parent = self()
    loader = fn ^remote_uri ->
      send(parent, {:loaded, remote_uri})
      {:ok, remote}
    end

    schema = %{
      "$id" => "https://example.com/root",
      "definitions" => %{"x" => %{"const" => "outer"}},
      "allOf" => [%{"$ref" => remote_uri <> "#/definitions/x"}],
      # Eagerly register the caller's alias without evaluating this property on strings.
      "properties" => %{"unused" => %{"$ref" => "#/definitions/x"}}
    }

    assert {:ok, compiled} = JSONSchex.compile(schema, draft: draft, loader: loader)
    assert Map.has_key?(compiled.defs, "#/definitions/x")
    refute_received {:loaded, _}
    {compiled, remote_uri}
  end
end

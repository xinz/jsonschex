defmodule JSONSchex.Test.CompileFragment do
  use ExUnit.Case

  defmodule CompileTimeFragmentSchema do
    require JSONSchex.Schema

    @schema JSONSchex.Schema.compile_fragment!(
              %{
                "components" => %{
                  "schemas" => %{
                    "Name" => %{"type" => "string"}
                  }
                },
                "schema" => %{"$ref" => "#/components/schemas/Name"}
              },
              entry: "#/schema"
            )

    def schema, do: @schema
  end

  test "compile-time fragment macro embeds the compiled schema" do
    assert :ok == JSONSchex.validate(CompileTimeFragmentSchema.schema(), "Ada")
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(CompileTimeFragmentSchema.schema(), 123)
  end

  @request_body_pointer "#/paths/~1users/post/requestBody/content/application~1json/schema"
  @base_uri "/api/openapi.yaml"

  test "compiles an OpenAPI schema fragment with a local component ref" do
    document = %{
      "openapi" => "3.1.0",
      "paths" => %{
        "/users" => %{
          "post" => %{
            "requestBody" => %{
              "content" => %{
                "application/json" => %{
                  "schema" => %{"$ref" => "#/components/schemas/UserInput"}
                }
              }
            }
          }
        }
      },
      "components" => %{
        "schemas" => %{
          "UserInput" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "manager" => %{"$ref" => "#/components/schemas/UserSummary"}
            }
          },
          "UserSummary" => %{
            "type" => "object",
            "required" => ["id"],
            "properties" => %{"id" => %{"type" => "integer"}}
          }
        }
      }
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: @request_body_pointer,
               base_uri: @base_uri
             )

    assert :ok == JSONSchex.validate(compiled, %{"name" => "Ada", "manager" => %{"id" => 1}})
    assert {:error, [%{rule: :required}]} = JSONSchex.validate(compiled, %{"manager" => %{"id" => 1}})
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"name" => "Ada", "manager" => %{"id" => "1"}})
  end

  test "accepts root entry aliases" do
    document = %{"type" => "string"}

    assert {:ok, empty_entry} = JSONSchex.compile_fragment(document, entry: "")
    assert {:ok, hash_entry} = JSONSchex.compile_fragment(document, entry: "#")

    assert :ok == JSONSchex.validate(empty_entry, "Ada")
    assert :ok == JSONSchex.validate(hash_entry, "Ada")
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(empty_entry, 123)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(hash_entry, 123)
  end

  test "accepts slash-prefixed entry pointers" do
    document = %{"schemas" => %{"Name" => %{"type" => "string"}}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "/schemas/Name",
               base_uri: @base_uri
             )

    assert :ok == JSONSchex.validate(compiled, "Ada")
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, 123)
  end

  test "accepts slash-prefixed entry pointers without base_uri" do
    document = %{"schemas" => %{"Name" => %{"type" => "string"}}}

    assert {:ok, compiled} = JSONSchex.compile_fragment(document, entry: "/schemas/Name")

    assert :ok == JSONSchex.validate(compiled, "Ada")
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, 123)
  end

  test "accepts absolute URI entries" do
    document = %{"schemas" => %{"Id" => %{"type" => "integer"}}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "https://example.com/openapi.yaml#/schemas/Id"
             )

    assert :ok == JSONSchex.validate(compiled, 123)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "123")
  end

  test "accepts entry as an entrypoint" do
    document = %{"components" => %{"schemas" => %{"Id" => %{"type" => "integer"}}}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: @base_uri <> "#/components/schemas/Id"
             )

    assert :ok == JSONSchex.validate(compiled, 123)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "123")
  end

  test "uses entry base when base_uri is omitted" do
    parent = self()

    loader = fn
      "/api/schemas/user.yaml" ->
        send(parent, {:loaded, "/api/schemas/user.yaml"})
        {:ok, %{"type" => "integer"}}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/user.yaml"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: @base_uri <> "#/schema",
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, 123)
    assert_received {:loaded, "/api/schemas/user.yaml"}
  end

  test "resolves anchors from the containing document" do
    document = %{
      "schema" => %{"$ref" => "#user-name"},
      "components" => %{
        "schemas" => %{
          "UserName" => %{
            "$anchor" => "user-name",
            "type" => "string",
            "minLength" => 1
          }
        }
      }
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri
             )

    assert :ok == JSONSchex.validate(compiled, "Ada")
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, 42)
  end

  test "loads relative external file refs from a slash-prefixed entry against the base path" do
    parent = self()

    loader = fn
      "/api/schemas/user.yaml" ->
        send(parent, {:loaded, "/api/schemas/user.yaml"})

        {:ok,
         %{
           "type" => "object",
           "required" => ["id"],
           "properties" => %{"id" => %{"type" => "integer"}}
         }}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/user.yaml"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"id" => 1})
    assert_received {:loaded, "/api/schemas/user.yaml"}
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"id" => "1"})
  end

  test "loads relative external file refs with fragments" do
    loader = fn
      "/api/schemas/common.yaml" ->
        {:ok,
         %{
           "$defs" => %{
             "User" => %{
               "type" => "object",
               "required" => ["name"],
               "properties" => %{"name" => %{"type" => "string"}}
             }
           }
         }}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/common.yaml#/$defs/User"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"name" => "Ada"})
    assert {:error, [%{rule: :required}]} = JSONSchex.validate(compiled, %{})
  end

  test "loader wrapper uses atom base_uri as the loaded resource base URI" do
    parent = self()

    loader = fn
      "/api/schemas/wrapped.json" ->
        {:ok,
         %{
           document: %{
             "type" => "object",
             "properties" => %{"child" => %{"$ref" => "child.json"}}
           },
           base_uri: "/actual/schemas/wrapped.json"
         }}

      "/actual/schemas/child.json" ->
        send(parent, {:loaded, "/actual/schemas/child.json"})
        {:ok, %{"type" => "integer"}}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/wrapped.json"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"child" => 1})
    assert_received {:loaded, "/actual/schemas/child.json"}
  end

  test "loader wrapper ignores string base_uri metadata" do
    parent = self()

    loader = fn
      "/api/schemas/wrapped.json" ->
        {:ok,
         %{
           "base_uri" => "/actual/schemas/wrapped.json",
           document: %{
             "type" => "object",
             "properties" => %{"child" => %{"$ref" => "child.json"}}
           }
         }}

      "/api/schemas/child.json" ->
        send(parent, {:loaded, "/api/schemas/child.json"})
        {:ok, %{"type" => "integer"}}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/wrapped.json"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"child" => 1})
    assert_received {:loaded, "/api/schemas/child.json"}
  end

  test "validates recursive local refs from a fragment" do
    document = %{
      "schema" => %{"$ref" => "#/components/schemas/Node"},
      "components" => %{
        "schemas" => %{
          "Node" => %{
            "type" => "object",
            "required" => ["value"],
            "properties" => %{
              "value" => %{"type" => "integer"},
              "next" => %{"anyOf" => [%{"$ref" => "#/components/schemas/Node"}, %{"type" => "null"}]}
            }
          }
        }
      }
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri
             )

    assert :ok == JSONSchex.validate(compiled, %{"value" => 1, "next" => %{"value" => 2, "next" => nil}})
    assert {:error, errors} = JSONSchex.validate(compiled, %{"value" => 1, "next" => %{"value" => "2"}})
    assert Enum.any?(List.flatten(errors), &match?(%{rule: :type}, &1))
  end

  test "validates recursive external refs from a fragment" do
    loader = fn
      "/api/schemas/node.yaml" ->
        {:ok,
         %{
           "type" => "object",
           "required" => ["value"],
           "properties" => %{
             "value" => %{"type" => "integer"},
             "next" => %{"anyOf" => [%{"$ref" => "#"}, %{"type" => "null"}]}
           }
         }}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/node.yaml"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"value" => 1, "next" => %{"value" => 2, "next" => nil}})
    assert {:error, errors} = JSONSchex.validate(compiled, %{"value" => 1, "next" => %{"value" => "2"}})
    assert Enum.any?(List.flatten(errors), &match?(%{rule: :type}, &1))
  end

  test "nested $id changes the base URI for relative refs" do
    parent = self()

    loader = fn
      "/api/schemas/child.json" ->
        send(parent, {:loaded, "/api/schemas/child.json"})
        {:ok, %{"type" => "integer"}}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{
      "schema" => %{"$ref" => "#/components/schemas/Parent"},
      "components" => %{
        "schemas" => %{
          "Parent" => %{
            "$id" => "schemas/parent.json",
            "type" => "object",
            "properties" => %{"child" => %{"$ref" => "child.json"}}
          }
        }
      }
    }

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"child" => 1})
    assert_received {:loaded, "/api/schemas/child.json"}
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"child" => "1"})
  end

  test "bundles an entry beneath a nested id using its inherited resource base" do
    parent = self()

    document = %{
      "container" => %{
        "$id" => "schemas/container.json",
        "schema" => %{"$ref" => "child.json"}
      }
    }

    loader = fn
      "/api/schemas/child.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{"type" => "integer"}}

      uri ->
        {:error, {:unexpected_uri, uri}}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/container/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert_received {:loaded, "/api/schemas/child.json"}
    assert bundled["$id"] == "/api/schemas/container.json"

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 123)
    assert {:error, _} = JSONSchex.validate(compiled, "123")
  end

  test "preserves the nested resource root for local refs from the entry" do
    document = %{
      "container" => %{
        "$id" => "schemas/container.json",
        "$defs" => %{"Value" => %{"type" => "integer"}},
        "schema" => %{"$ref" => "#/$defs/Value"}
      }
    }

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/container/schema",
               base_uri: @base_uri
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 123)
    assert {:error, _} = JSONSchex.validate(compiled, "123")
  end

  test "retains containing-document context outside a nested entry resource" do
    document = %{
      "components" => %{
        "schemas" => %{"Value" => %{"type" => "integer"}}
      },
      "container" => %{
        "$id" => "schemas/container.json",
        "schema" => %{"$ref" => "/api/openapi.yaml#/components/schemas/Value"}
      }
    }

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/container/schema",
               base_uri: @base_uri
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 123)
    assert {:error, _} = JSONSchex.validate(compiled, "123")
  end

  test "bundles a local fragment into a standalone schema" do
    document = %{
      "schema" => %{"$ref" => "#/components/schemas/User"},
      "components" => %{
        "schemas" => %{
          "User" => %{
            "type" => "object",
            "required" => ["name"],
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      }
    }

    assert {:ok, bundle} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri
             )

    assert {:ok, compiled} = JSONSchex.compile(bundle)
    assert :ok == JSONSchex.validate(compiled, %{"name" => "Ada"})
    assert {:error, [%{rule: :required}]} = JSONSchex.validate(compiled, %{})
  end

  test "bundles an external fragment into a standalone schema" do
    loader = fn
      "/api/schemas/common.yaml" ->
        {:ok,
         %{
           "$defs" => %{
             "User" => %{
               "type" => "object",
               "required" => ["name"],
               "properties" => %{"name" => %{"type" => "string"}}
             }
           }
         }}

      other ->
        {:error, {:unexpected_uri, other}}
    end

    document = %{"schema" => %{"$ref" => "./schemas/common.yaml#/$defs/User"}}

    assert {:ok, bundle} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundle)
    assert :ok == JSONSchex.validate(compiled, %{"name" => "Ada"})
    assert {:error, [%{rule: :required}]} = JSONSchex.validate(compiled, %{})
  end

  test "does not load an external ref unreachable from the selected entry" do
    document = %{
      "schema" => %{"type" => "string"},
      "components" => %{
        "schemas" => %{
          "Unused" => %{"$ref" => "./missing.yaml"}
        }
      }
    }

    test_pid = self()

    loader = fn uri ->
      send(test_pid, {:loaded, uri})
      {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    refute_received {:loaded, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, "ok")
    assert {:error, _} = JSONSchex.validate(compiled, 123)
  end

  test "does not follow refs in inactive definitions, examples, or extension data" do
    document = %{
      "schema" => %{
        "type" => "string",
        "$defs" => %{
          "Unused" => %{"$ref" => "./missing-definition.yaml"}
        },
        "examples" => [%{"$ref" => "./missing-example.yaml"}],
        "x-metadata" => %{"$ref" => "./missing-extension.yaml"}
      }
    }

    test_pid = self()

    loader = fn uri ->
      send(test_pid, {:loaded, uri})
      {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    refute_received {:loaded, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, "ok")
    assert {:error, _} = JSONSchex.validate(compiled, 123)
  end

  test "loads refs under every supported active schema-bearing keyword" do
    parent = self()

    ref_for = fn name -> %{"$ref" => "/api/#{name}.json"} end

    cases = [
      {"additional-properties", %{"additionalProperties" => ref_for.("additional-properties")}},
      {"contains", %{"contains" => ref_for.("contains")}},
      {"content-schema", %{"contentSchema" => ref_for.("content-schema")}},
      {"items", %{"items" => ref_for.("items")}},
      {"not", %{"not" => ref_for.("not")}},
      {"property-names", %{"propertyNames" => ref_for.("property-names")}},
      {"unevaluated-items", %{"unevaluatedItems" => ref_for.("unevaluated-items")}},
      {"unevaluated-properties", %{
        "unevaluatedProperties" => ref_for.("unevaluated-properties")
      }},
      {"dependent-schemas", %{"dependentSchemas" => %{"value" => ref_for.("dependent-schemas")}}},
      {"pattern-properties", %{"patternProperties" => %{".*" => ref_for.("pattern-properties")}}},
      {"properties", %{"properties" => %{"value" => ref_for.("properties")}}},
      {"all-of", %{"allOf" => [ref_for.("all-of")]}},
      {"any-of", %{"anyOf" => [ref_for.("any-of")]}},
      {"one-of", %{"oneOf" => [ref_for.("one-of")]}},
      {"prefix-items", %{"prefixItems" => [ref_for.("prefix-items")]}},
      {"if", %{"if" => ref_for.("if")}},
      {"then", %{"if" => true, "then" => ref_for.("then")}},
      {"else", %{"if" => true, "else" => ref_for.("else")}},
      {"dependencies", %{"dependencies" => %{"value" => ref_for.("dependencies")}}}
    ]

    Enum.each(cases, fn {name, schema} ->
      expected_uri = "/api/#{name}.json"

      loader = fn
        ^expected_uri ->
          send(parent, {:loaded, expected_uri})
          {:ok, true}

        uri ->
          {:error, {:unexpected_uri, uri}}
      end

      assert {:ok, bundled} =
               JSONSchex.bundle_fragment(%{"schema" => schema},
                 entry: "#/schema",
                 base_uri: "/api/root.json",
                 loader: loader
               )

      assert_received {:loaded, ^expected_uri}
      assert {:ok, _compiled} = JSONSchex.compile(bundled)
    end)
  end

  test "does not let an unreachable example id hijack a reachable external resource" do
    parent = self()

    document = %{
      "schema" => %{"$ref" => "/api/target.json"},
      "x-example" => %{
        "$id" => "/api/target.json",
        "$ref" => "/api/missing.json"
      }
    }

    loader = fn
      "/api/target.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{"type" => "integer"}}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    assert_received {:loaded, "/api/target.json"}
    refute_received {:unexpected_load, "/api/missing.json"}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "rejects ambiguous fallback anchors without loading extension refs" do
    parent = self()

    document = %{
      "schema" => %{"$ref" => "#target"},
      "components" => %{
        "schemas" => %{
          "Target" => %{
            "$anchor" => "target",
            "type" => "integer"
          }
        }
      },
      "a-examples" => [
        %{
          "$anchor" => "target",
          "$ref" => "/api/missing-example.json"
        }
      ],
      "x-extension" => %{
        "$dynamicAnchor" => "target",
        "$ref" => "/api/missing-extension.json"
      }
    }

    loader = fn uri ->
      send(parent, {:unexpected_load, uri})
      {:error, :unexpected_load}
    end

    assert {:error, error} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    refute_received {:unexpected_load, _uri}
    assert error.context.contrast == "ambiguous_anchor"
    assert error.context.input == "/api/root.json#target"
    assert error.context.error_detail == {:candidate_count, 3}
  end

  test "indexes id resources in inactive conditional schema locations" do
    parent = self()

    document = %{
      "schema" => %{
        "$ref" => "/api/hidden.json",
        "then" => %{
          "$id" => "/api/hidden.json",
          "type" => "integer"
        }
      }
    }

    loader = fn uri ->
      send(parent, {:unexpected_load, uri})
      {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    refute_received {:unexpected_load, _uri}
    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "deduplicates static and dynamic fallback anchors at one location" do
    document = %{
      "schema" => %{"$ref" => "#target"},
      "components" => %{
        "schemas" => %{
          "Target" => %{
            "$anchor" => "target",
            "$dynamicAnchor" => "target",
            "type" => "integer"
          }
        }
      }
    }

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json"
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "loads an external resource reachable from the selected entry" do
    document = %{
      "schema" => %{"$ref" => "./schemas/user.yaml"},
      "components" => %{
        "schemas" => %{
          "Unused" => %{"$ref" => "./missing.yaml"}
        }
      }
    }

    user_schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }

    test_pid = self()

    loader = fn
      "/api/schemas/user.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{document: user_schema, base_uri: uri}}

      uri ->
        send(test_pid, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert_received {:loaded, "/api/schemas/user.yaml"}
    refute_received {:unexpected_load, "/api/missing.yaml"}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"name" => "Ada"})
    assert {:error, _} = JSONSchex.validate(compiled, %{})
  end

  test "follows reachable anchors and dynamic anchors without scanning unrelated anchors" do
    document = %{
      "schema" => %{
        "allOf" => [
          %{"$ref" => "#selected"},
          %{"$dynamicRef" => "#dynamic-selected"}
        ]
      },
      "components" => %{
        "schemas" => %{
          "Selected" => %{
            "$anchor" => "selected",
            "properties" => %{"id" => %{"$ref" => "./id.yaml"}}
          },
          "DynamicSelected" => %{
            "$dynamicAnchor" => "dynamic-selected",
            "properties" => %{"name" => %{"$ref" => "./name.yaml"}}
          },
          "Unused" => %{
            "$anchor" => "unused",
            "$ref" => "./missing.yaml"
          }
        }
      }
    }

    test_pid = self()

    loader = fn
      "/api/id.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{"type" => "integer"}}

      "/api/name.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{"type" => "string"}}

      uri ->
        send(test_pid, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert_received {:loaded, "/api/id.yaml"}
    assert_received {:loaded, "/api/name.yaml"}
    refute_received {:unexpected_load, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"id" => 1, "name" => "Ada"})
    assert {:error, errors} = JSONSchex.validate(compiled, %{"id" => "1", "name" => 2})
    assert Enum.count(List.flatten(errors), &match?(%{rule: :type}, &1)) == 2
  end

  test "follows local-to-external refs transitively from an external fragment and preserves recursion" do
    document = %{
      "schema" => %{"$ref" => "#/components/schemas/Node"},
      "components" => %{
        "schemas" => %{
          "Node" => %{"$ref" => "./schemas/common.yaml#/$defs/Node"},
          "Unused" => %{"$ref" => "./missing-root.yaml"}
        }
      }
    }

    common = %{
      "$defs" => %{
        "Node" => %{
          "type" => "object",
          "required" => ["value"],
          "properties" => %{
            "value" => %{"$ref" => "./value.yaml"},
            "next" => %{
              "anyOf" => [
                %{"$ref" => "#/$defs/Node"},
                %{"type" => "null"}
              ]
            }
          }
        },
        "Unused" => %{"$ref" => "./missing-external.yaml"}
      }
    }

    test_pid = self()

    loader = fn
      "/api/schemas/common.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{document: common, base_uri: "/actual/schemas/common.yaml"}}

      "/actual/schemas/value.yaml" = uri ->
        send(test_pid, {:loaded, uri})
        {:ok, %{"type" => "integer"}}

      uri ->
        send(test_pid, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert_received {:loaded, "/api/schemas/common.yaml"}
    assert_received {:loaded, "/actual/schemas/value.yaml"}
    refute_received {:unexpected_load, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)

    assert :ok ==
             JSONSchex.validate(compiled, %{
               "value" => 1,
               "next" => nil
             })

    assert :ok ==
             JSONSchex.validate(compiled, %{
               "value" => 1,
               "next" => %{"value" => 2, "next" => nil}
             })

    assert {:error, errors} =
             JSONSchex.validate(compiled, %{
               "value" => 1,
               "next" => %{"value" => "2", "next" => nil}
             })

    assert Enum.any?(List.flatten(errors), &match?(%{rule: :type}, &1))
  end

  test "rewrites transitive loader aliases inside mounted external resources" do
    loader = fn
      "/api/a.json" ->
        {:ok,
         %{
           document: %{
             "type" => "object",
             "properties" => %{"x" => %{"$ref" => "child.json"}}
           },
           base_uri: "/mirror/a.json"
         }}

      "/mirror/child.json" ->
        {:ok,
         %{
           document: %{"type" => "integer"},
           base_uri: "/actual/child.json"
         }}
    end

    document = %{"schema" => %{"$ref" => "/api/a.json"}}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"x" => 1})
    assert {:error, _} = JSONSchex.validate(compiled, %{"x" => "1"})
  end

  test "mounts reachable external boolean schemas as standalone resources" do
    loader = fn
      "/api/denied.json" -> {:ok, false}
    end

    document = %{"schema" => %{"$ref" => "/api/denied.json"}}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert {:error, _} = JSONSchex.validate(compiled, "anything")
  end

  test "resolves loaded root ids against the loader effective base" do
    loader = fn
      "/api/a.json" ->
        {:ok,
         %{
           document: %{
             "$id" => "canonical.json",
             "type" => "integer"
           },
           base_uri: "/mirror/a.json"
         }}
    end

    document = %{"schema" => %{"$ref" => "/api/a.json"}}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    assert bundled["$ref"] == "/mirror/canonical.json"
    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "loads requested, effective, and canonical refs to one resource only once" do
    parent = self()

    document = %{
      "schema" => %{
        "allOf" => [
          %{"$ref" => "/api/a.json"},
          %{"$ref" => "/mirror/a.json"},
          %{"$ref" => "/mirror/canonical.json"}
        ]
      }
    }

    loader = fn
      "/api/a.json" = uri ->
        send(parent, {:loaded, uri})

        {:ok,
         %{
           document: %{"$id" => "canonical.json", "type" => "integer"},
           base_uri: "/mirror/a.json"
         }}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    assert_received {:loaded, "/api/a.json"}
    refute_received {:unexpected_load, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "preserves recursive dynamic refs in a reachable external resource" do
    external = %{
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{
        "next" => %{"$dynamicRef" => "#node"}
      }
    }

    loader = fn
      "/api/ext.json" ->
        {:ok, %{document: external, base_uri: "/api/ext.json"}}
    end

    document = %{"schema" => %{"$ref" => "/api/ext.json#node"}}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"next" => %{}})
    assert {:error, _} = JSONSchex.validate(compiled, true)
  end

  test "loads refs reachable through a dynamic-scope override" do
    parent = self()

    external = %{
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{
        "next" => %{"$dynamicRef" => "#node"}
      }
    }

    document = %{
      "schema" => %{
        "$id" => "/api/root-schema.json",
        "$defs" => %{
          "override" => %{
            "$dynamicAnchor" => "node",
            "type" => "object",
            "properties" => %{
              "x" => %{"$ref" => "/api/value.json"}
            }
          }
        },
        "$ref" => "/api/ext.json#node"
      }
    }

    loader = fn
      "/api/ext.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{document: external, base_uri: uri}}

      "/api/value.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{"type" => "integer"}}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, {:unexpected_uri, uri}}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/openapi.json",
               loader: loader
             )

    assert_received {:loaded, "/api/ext.json"}
    assert_received {:loaded, "/api/value.json"}
    refute_received {:unexpected_load, _uri}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"next" => %{"x" => 1}})

    assert {:error, errors} =
             JSONSchex.validate(compiled, %{"next" => %{"x" => "not-an-integer"}})

    assert Enum.any?(List.flatten(errors), &match?(%{path: ["x", "next"], rule: :type}, &1))
  end

  test "does not leak dynamic scope across sibling reference branches" do
    parent = self()

    first_branch = %{
      "$defs" => %{
        "inactive" => %{
          "$dynamicAnchor" => "node",
          "$ref" => "/api/missing.json"
        }
      },
      "type" => "object"
    }

    second_branch = %{
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{
        "next" => %{"$dynamicRef" => "#node"}
      }
    }

    document = %{
      "schema" => %{
        "allOf" => [
          %{"$ref" => "/api/a.json"},
          %{"$ref" => "/api/b.json#node"}
        ]
      }
    }

    loader = fn
      "/api/a.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, first_branch}

      "/api/b.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, second_branch}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/openapi.json",
               loader: loader
             )

    assert_received {:loaded, "/api/a.json"}
    assert_received {:loaded, "/api/b.json"}
    refute_received {:unexpected_load, "/api/missing.json"}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"next" => %{}})
  end

  test "follows only the winning dynamic anchor in ordered scope" do
    parent = self()

    first_external = %{
      "$defs" => %{
        "shadowed" => %{
          "$dynamicAnchor" => "node",
          "$ref" => "/api/missing.json"
        }
      },
      "$ref" => "/api/b.json#node"
    }

    recursive_external = %{
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{
        "next" => %{"$dynamicRef" => "#node"}
      }
    }

    document = %{
      "schema" => %{
        "$id" => "/api/root-schema.json",
        "$dynamicAnchor" => "node",
        "$ref" => "/api/a.json"
      }
    }

    loader = fn
      "/api/a.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, first_external}

      "/api/b.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, recursive_external}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/openapi.json",
               loader: loader
             )

    assert_received {:loaded, "/api/a.json"}
    assert_received {:loaded, "/api/b.json"}
    refute_received {:unexpected_load, "/api/missing.json"}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, %{"next" => %{}})
  end

  test "does not traverse a dynamic static target shadowed by the winning anchor" do
    parent = self()

    document = %{
      "schema" => %{
        "$id" => "/api/root-schema.json",
        "$defs" => %{
          "override" => %{
            "$dynamicAnchor" => "node",
            "type" => "integer"
          }
        },
        "$dynamicRef" => "/api/static.json#node"
      }
    }

    static_target = %{
      "$dynamicAnchor" => "node",
      "$ref" => "/api/missing.json"
    }

    loader = fn
      "/api/static.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, static_target}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/openapi.json",
               loader: loader
             )

    assert_received {:loaded, "/api/static.json"}
    refute_received {:unexpected_load, "/api/missing.json"}

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "does not overwrite user definitions with generated bundle resources" do
    document = %{
      "schema" => %{
        "$defs" => %{"jsonschex_anchor_1" => false},
        "allOf" => [
          %{"$ref" => "#selected"},
          %{"$ref" => "#/$defs/jsonschex_anchor_1"}
        ]
      },
      "components" => %{
        "schemas" => %{
          "Selected" => %{"$anchor" => "selected", "type" => "integer"}
        }
      }
    }

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json"
             )

    assert bundled["$defs"]["jsonschex_anchor_1"] == false
    assert Map.has_key?(bundled["$defs"], "jsonschex_anchor_1_2")

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert {:error, _} = JSONSchex.validate(compiled, 1)
  end

  test "returns a structured error when generated resources require a map at $defs" do
    parent = self()

    document = %{
      "schema" => %{
        "$defs" => "invalid",
        "$ref" => "/api/value.json"
      }
    }

    loader = fn uri ->
      send(parent, {:unexpected_load, uri})
      {:ok, %{"type" => "integer"}}
    end

    assert {:error, error} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: "/api/root.json",
               loader: loader
             )

    refute_received {:unexpected_load, _uri}
    assert error.context.contrast == "invalid_defs"
    assert error.context.input == "invalid"
  end

  test "renames every generated definition category deterministically on collision" do
    document = %{
      "container" => %{
        "$id" => "/api/container.json",
        "$defs" => %{
          "jsonschex_context_document" => true,
          "jsonschex_external_1" => true,
          "jsonschex_external_1_2" => true,
          "UserOwned" => %{"type" => "string"}
        },
        "schema" => %{"$ref" => "/api/value.json"}
      }
    }

    loader = fn
      "/api/value.json" -> {:ok, %{"type" => "integer"}}
    end

    opts = [entry: "#/container/schema", base_uri: "/api/root.json", loader: loader]

    assert {:ok, first_bundle} = JSONSchex.bundle_fragment(document, opts)
    assert {:ok, second_bundle} = JSONSchex.bundle_fragment(document, opts)
    assert first_bundle == second_bundle

    defs = first_bundle["$defs"]
    assert defs["jsonschex_context_document"] == true
    assert Map.has_key?(defs, "jsonschex_context_document_2")
    assert defs["jsonschex_external_1"] == true
    assert defs["jsonschex_external_1_2"] == true
    assert Map.has_key?(defs, "jsonschex_external_1_3")
    assert defs["UserOwned"] == %{"type" => "string"}

    assert {:ok, compiled} = JSONSchex.compile(first_bundle)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "returns an error when bundling external refs without a loader" do
    document = %{"schema" => %{"$ref" => "./schemas/missing.yaml"}}

    assert {:error, error} =
             JSONSchex.bundle_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri
             )

    assert error.context.contrast == "load_remote"
    assert error.context.error_detail == :no_loader
  end

  test "returns a validation diagnostic when a local ref is missing" do
    document = %{"schema" => %{"$ref" => "#/components/schemas/Missing"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri
             )

    assert {:error, [%{rule: :ref, context: %{contrast: "ref_not_found", input: "#/components/schemas/Missing"}}]} =
             JSONSchex.validate(compiled, %{})
  end

  test "returns a validation diagnostic when an external resource is missing" do
    loader = fn "/api/schemas/missing.yaml" -> {:error, :not_found} end
    document = %{"schema" => %{"$ref" => "./schemas/missing.yaml"}}

    assert {:ok, compiled} =
             JSONSchex.compile_fragment(document,
               entry: "#/schema",
               base_uri: @base_uri,
               loader: loader
             )

    assert {:error, [%{rule: :ref, context: %{contrast: "load_remote", input: "/api/schemas/missing.yaml", error_detail: :not_found}}]} =
             JSONSchex.validate(compiled, %{})
  end

  test "formats compile_fragment missing entry errors" do
    assert {:error, error} = JSONSchex.compile_fragment(%{}, [])

    assert JSONSchex.format_error(error) ==
             ~s|Failed to compile schema fragment (missing_entry): detail: "Expected :entry option"|
  end

  test "formats compile_fragment invalid entry errors" do
    assert {:error, error} = JSONSchex.compile_fragment(%{}, entry: "not-a-pointer")

    assert JSONSchex.format_error(error) ==
             ~s|Failed to compile schema fragment (invalid_entry): input: "not-a-pointer", detail: "Entry must be a JSON Pointer or URI reference string with a fragment"|
  end

  test "formats compile_fragment entry-not-found errors" do
    assert {:error, error} = JSONSchex.compile_fragment(%{}, entry: "#/missing")

    assert JSONSchex.format_error(error) ==
             ~s|Failed to compile schema fragment (entry_not_found): input: "#/missing", detail: "not found"|
  end

  test "formats compile_fragment invalid entry schema errors" do
    assert {:error, error} = JSONSchex.compile_fragment(%{"schema" => "not a schema"}, entry: "#/schema")

    assert JSONSchex.format_error(error) ==
             ~s|Failed to compile schema fragment (invalid_entry_schema): input: "#/schema", detail: "The entrypoint must resolve to a JSON Schema map or boolean"|
  end

  test "formats compile_fragment invalid document errors" do
    assert {:error, error} = JSONSchex.compile_fragment("not a document", entry: "#/schema")

    assert JSONSchex.format_error(error) ==
             ~s|Failed to compile schema fragment (invalid_document): detail: "JSONSchex.compile_fragment/2 expects the document to be a map or boolean"|
  end

  test "formats bundle_fragment invalid document errors" do
    assert {:error, error} = JSONSchex.bundle_fragment("not a document", entry: "#/schema")

    assert JSONSchex.format_error(error) ==
             ~s|Failed to compile schema fragment (invalid_document): detail: "JSONSchex.bundle_fragment/2 expects the document to be a map or boolean"|
  end
end

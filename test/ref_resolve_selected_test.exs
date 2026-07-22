defmodule JSONSchex.Test.RefResolveSelected do
  use ExUnit.Case

  alias JSONSchex.Ref

  defp select_all_refs(_path, %{"$ref" => _}), do: true
  defp select_all_refs(_path, _node), do: false

  test "selected local ref is replaced" do
    document = %{
      "a" => %{"$ref" => "#/defs/A"},
      "defs" => %{"A" => %{"value" => 1}}
    }

    assert {:ok, resolved} = Ref.resolve_selected(document, select: &select_all_refs/2)

    assert resolved == %{
             "a" => %{"value" => 1},
             "defs" => %{"A" => %{"value" => 1}}
           }
  end

  test "unselected local ref is preserved while its sibling values are traversed" do
    document = %{
      "a" => %{
        "$ref" => "#/defs/A",
        "nested" => %{"$ref" => "#/defs/B"}
      },
      "defs" => %{
        "A" => %{"value" => 1},
        "B" => %{"value" => 2}
      }
    }

    select = fn
      ["a"], %{"$ref" => _} -> false
      _path, %{"$ref" => _} -> true
      _path, _node -> false
    end

    assert {:ok, resolved} = Ref.resolve_selected(document, select: select)

    assert resolved == %{
             "a" => %{
               "$ref" => "#/defs/A",
               "nested" => %{"value" => 2}
             },
             "defs" => %{
               "A" => %{"value" => 1},
               "B" => %{"value" => 2}
             }
           }
  end

  test "selector is invoked for descendant refs beneath an unselected ref" do
    parent = self()

    document = %{
      "schema" => %{
        "$ref" => "#/defs/A",
        "allOf" => [%{"$ref" => "#/defs/B"}]
      },
      "defs" => %{
        "A" => %{"type" => "integer"},
        "B" => %{"minimum" => 1}
      }
    }

    select = fn path, %{"$ref" => _} ->
      send(parent, {:selected_path, path})
      false
    end

    assert {:ok, ^document} = Ref.resolve_selected(document, select: select)
    assert_received {:selected_path, ["schema"]}
    assert_received {:selected_path, ["schema", "allOf", 0]}
  end

  test "external ref uses loader" do
    parent = self()

    loader = fn
      "/api/common.yaml" ->
        send(parent, {:loaded, "/api/common.yaml"})

        {:ok,
         %{
           "components" => %{
             "parameters" => %{
               "UserId" => %{"name" => "id", "in" => "path"}
             }
           }
         }}
    end

    document = %{"parameter" => %{"$ref" => "./common.yaml#/components/parameters/UserId"}}

    assert {:ok, resolved} =
             Ref.resolve_selected(document,
               base_uri: "/api/root.yaml",
               loader: loader,
               select: &select_all_refs/2
             )

    assert_received {:loaded, "/api/common.yaml"}
    assert resolved["parameter"] == %{"name" => "id", "in" => "path"}
  end

  test "external nested ref uses loaded base_uri" do
    parent = self()

    loader = fn
      "/api/paths/users.yaml" ->
        send(parent, {:loaded, "/api/paths/users.yaml"})

        {:ok,
         %{
           document: %{
             "UserPath" => %{
               "post" => %{
                 "requestBody" => %{"$ref" => "../common.yaml#/components/requestBodies/CreateUser"}
               }
             }
           },
           base_uri: "/api/paths/users.yaml"
         }}

      "/api/common.yaml" ->
        send(parent, {:loaded, "/api/common.yaml"})

        {:ok,
         %{
           "components" => %{
             "requestBodies" => %{
               "CreateUser" => %{"description" => "create user"}
             }
           }
         }}
    end

    document = %{"path" => %{"$ref" => "./paths/users.yaml#/UserPath"}}

    assert {:ok, resolved} =
             Ref.resolve_selected(document,
               base_uri: "/api/root.yaml",
               loader: loader,
               select: &select_all_refs/2
             )

    assert_received {:loaded, "/api/paths/users.yaml"}
    assert_received {:loaded, "/api/common.yaml"}
    assert resolved["path"]["post"]["requestBody"] == %{"description" => "create user"}
  end

  test "selected non-string ref returns invalid ref value error" do
    document = %{"a" => %{"$ref" => 123}}

    assert {:error, %Ref.Error{} = error} = Ref.resolve_selected(document, select: &select_all_refs/2)

    assert error.kind == :invalid_ref_value
    assert error.path == ["a"]
    assert error.ref == 123
  end

  test "unselected non-string ref is preserved" do
    document = %{"a" => %{"$ref" => 123}}

    assert {:ok, ^document} = Ref.resolve_selected(document, select: fn _path, _node -> false end)
  end

  test "selected relative external ref without base_uri returns missing base URI error" do
    document = %{"a" => %{"$ref" => "./common.yaml#/A"}}

    assert {:error, %Ref.Error{} = error} = Ref.resolve_selected(document, select: &select_all_refs/2)

    assert error.kind == :missing_base_uri
    assert error.path == ["a"]
    assert error.ref == "./common.yaml#/A"
  end

  test "selected external ref without loader returns missing loader error" do
    document = %{"a" => %{"$ref" => "./common.yaml#/A"}}

    assert {:error, %Ref.Error{} = error} =
             Ref.resolve_selected(document,
               base_uri: "/api/root.yaml",
               select: &select_all_refs/2
             )

    assert error.kind == :missing_loader
    assert error.uri == "/api/common.yaml#/A"
  end

  test "missing target returns missing target error" do
    document = %{"a" => %{"$ref" => "#/missing"}}

    assert {:error, %Ref.Error{} = error} = Ref.resolve_selected(document, select: &select_all_refs/2)

    assert error.kind == :missing_target
    assert error.path == ["a"]
    assert error.uri == "#/missing"
  end

  test "loader error returns missing external document error" do
    loader = fn "/api/common.yaml" -> {:error, :not_found} end
    document = %{"a" => %{"$ref" => "./common.yaml#/A"}}

    assert {:error, %Ref.Error{} = error} =
             Ref.resolve_selected(document,
               base_uri: "/api/root.yaml",
               loader: loader,
               select: &select_all_refs/2
             )

    assert error.kind == :missing_external_document
    assert error.reason == :not_found
  end

  test "invalid loader response returns invalid loader response error" do
    loader = fn "/api/common.yaml" -> {:ok, "not a document"} end
    document = %{"a" => %{"$ref" => "./common.yaml#/A"}}

    assert {:error, %Ref.Error{} = error} =
             Ref.resolve_selected(document,
               base_uri: "/api/root.yaml",
               loader: loader,
               select: &select_all_refs/2
             )

    assert error.kind == :invalid_loader_response
    assert error.reason == {:ok, "not a document"}
  end

  test "cycle errors" do
    document = %{
      "a" => %{"$ref" => "#/b"},
      "b" => %{"$ref" => "#/a"}
    }

    assert {:error, %Ref.Error{} = error} = Ref.resolve_selected(document, select: &select_all_refs/2)

    assert error.kind == :cycle_detected
    assert error.uri in ["#/b", "#/a"]

    document = %{
      "a" => %{"$ref" => "#/c"},
      "b" => %{"$ref" => "#/c"},
      "c" => %{"$ref" => "#/b"},
    }

    assert {:error, %Ref.Error{} = error} = Ref.resolve_selected(document, select: &select_all_refs/2)
    assert error.uri in ["#/c", "#/a"]
  end

  test "selected external target preserves base for nested local unselected refs" do
    root = %{
      "paths" => %{
        "/users/{id}" => %{
          "get" => %{
            "parameters" => [
              %{"$ref" => "./common.yaml#/components/parameters/UserId"}
            ]
          }
        }
      }
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "required" => true,
            "schema" => %{"$ref" => "#/components/schemas/UserId"}
          }
        },
        "schemas" => %{
          "UserId" => %{"type" => "integer"}
        }
      }
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["paths", "/users/{id}", "get", "parameters", 0], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema = get_in(resolved, ["paths", "/users/{id}", "get", "parameters", Access.at(0), "schema"])

    assert schema == %{"$ref" => "/api/common.yaml#/components/schemas/UserId"}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "/paths/~1users~1{id}/get/parameters/0/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, 123) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, "not-an-integer")
  end

  test "selected external target preserves base for nested relative unselected refs" do
    root = %{
      "paths" => %{
        "/profiles" => %{
          "post" => %{
            "requestBody" => %{"$ref" => "./common.yaml#/components/requestBodies/ProfileBody"}
          }
        }
      }
    }

    common = %{
      "components" => %{
        "requestBodies" => %{
          "ProfileBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => %{"$ref" => "./schemas/profile.yaml"}
              }
            }
          }
        }
      }
    }

    profile = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
      "/api/schemas/profile.yaml" -> {:ok, %{document: profile, base_uri: "/api/schemas/profile.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["paths", "/profiles", "post", "requestBody"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema =
      get_in(resolved, [
        "paths",
        "/profiles",
        "post",
        "requestBody",
        "content",
        "application/json",
        "schema"
      ])

    assert schema == %{"$ref" => "/api/schemas/profile.yaml"}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "#/paths/~1profiles/post/requestBody/content/application~1json/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, %{"name" => "Ada"}) == :ok
    assert {:error, _} = JSONSchex.validate(compiled, %{})
  end

  test "unselected nested refs remain refs after selected external target is inlined" do
    root = %{
      "parameter" => %{"$ref" => "./common.yaml#/components/parameters/UserId"}
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "schema" => %{"$ref" => "#/components/schemas/UserId"}
          }
        },
        "schemas" => %{
          "UserId" => %{"type" => "integer"}
        }
      }
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema = get_in(resolved, ["parameter", "schema"])

    assert %{"$ref" => ref} = schema
    assert ref == "/api/common.yaml#/components/schemas/UserId"
    refute Map.has_key?(schema, "type")
  end

  test "nested unselected refs are rebased against loader wrapper base_uri" do
    root = %{
      "parameter" => %{"$ref" => "https://example.test/common#/components/parameters/UserId"}
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "UserId" => %{
            "name" => "id",
            "in" => "path",
            "schema" => %{
              "$ref" => "./schemas/user-id.yaml",
              "allOf" => [%{"$ref" => "./schemas/constraints.yaml"}]
            }
          }
        }
      }
    }

    loader = fn
      "https://example.test/common" ->
        {:ok, %{document: common, base_uri: "file:///mirror/common.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    schema = get_in(resolved, ["parameter", "schema"])

    assert schema == %{
             "$ref" => "file:///mirror/schemas/user-id.yaml",
             "allOf" => [%{"$ref" => "file:///mirror/schemas/constraints.yaml"}]
           }
  end

  test "unselected refs beneath ref siblings are deeply rebased" do
    root = %{
      "parameter" => %{"$ref" => "./common.yaml#/parameter"}
    }

    common = %{
      "parameter" => %{
        "name" => "id",
        "in" => "query",
        "schema" => %{
          "$ref" => "./schemas/base.yaml",
          "allOf" => [
            %{
              "properties" => %{
                "value" => %{"$ref" => "./schemas/constraints.yaml"}
              }
            }
          ]
        }
      }
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert get_in(resolved, ["parameter", "schema"]) == %{
             "$ref" => "/api/schemas/base.yaml",
             "allOf" => [
               %{
                 "properties" => %{
                   "value" => %{"$ref" => "/api/schemas/constraints.yaml"}
                 }
               }
             ]
           }
  end

  test "selected external fragments inherit ids along their pointer path" do
    root = %{
      "parameter" => %{"$ref" => "/api/common.json#/container/parameter"}
    }

    common = %{
      "container" => %{
        "$id" => "nested/container.json",
        "parameter" => %{
          "schema" => %{"$ref" => "child.json"}
        }
      }
    }

    loader = fn
      "/api/common.json" ->
        {:ok, %{document: common, base_uri: "/mirror/common.json"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/root.json",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert resolved == %{
             "parameter" => %{
               "schema" => %{"$ref" => "/mirror/nested/child.json"}
             }
           }
  end

  test "selected local refs do not apply their resource root id twice" do
    root = %{
      "parameter" => %{"$ref" => "/api/common.json#/container/parameter"}
    }

    common = %{
      "container" => %{
        "$id" => "nested/container.json",
        "$defs" => %{
          "V" => %{"schema" => %{"$ref" => "child.json"}}
        },
        "parameter" => %{
          "inner" => %{"$ref" => "#/$defs/V"}
        }
      }
    }

    loader = fn
      "/api/common.json" ->
        {:ok, %{document: common, base_uri: "/mirror/common.json"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/root.json",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 ["parameter", "inner"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert resolved == %{
             "parameter" => %{
               "inner" => %{
                 "schema" => %{"$ref" => "/mirror/nested/child.json"}
               }
             }
           }
  end

  test "loaded canonical ids share the selected-ref cache" do
    parent = self()

    root = %{
      "first" => %{"$ref" => "/api/a.json#/value"},
      "second" => %{"$ref" => "/mirror/canonical.json#/value"}
    }

    external = %{
      "$id" => "canonical.json",
      "value" => %{"type" => "integer"}
    }

    loader = fn
      "/api/a.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{document: external, base_uri: "/mirror/a.json"}}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/root.json",
               loader: loader,
               select: &select_all_refs/2
             )

    assert_received {:loaded, "/api/a.json"}
    refute_received {:unexpected_load, _uri}
    assert resolved["first"] == %{"type" => "integer"}
    assert resolved["second"] == %{"type" => "integer"}
  end

  test "deep rebasing honors nested id resource boundaries" do
    root = %{
      "parameter" => %{"$ref" => "./common.yaml#/parameter"}
    }

    common = %{
      "parameter" => %{
        "name" => "id",
        "schema" => %{
          "$id" => "nested/schema.json",
          "$ref" => "base.json",
          "allOf" => [%{"$ref" => "constraints.json"}]
        }
      }
    }

    loader = fn
      "/api/common.yaml" -> {:ok, %{document: common, base_uri: "/api/common.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert get_in(resolved, ["parameter", "schema"]) == %{
             "$id" => "nested/schema.json",
             "$ref" => "/api/nested/base.json",
             "allOf" => [%{"$ref" => "/api/nested/constraints.json"}]
           }
  end

  test "deeply rebased unselected refs are not loaded" do
    parent = self()

    root = %{
      "parameter" => %{"$ref" => "./common.yaml#/parameter"}
    }

    common = %{
      "parameter" => %{
        "name" => "id",
        "schema" => %{
          "$ref" => "./schemas/base.yaml",
          "allOf" => [%{"$ref" => "./schemas/constraints.yaml"}]
        }
      }
    }

    loader = fn
      "/api/common.yaml" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{document: common, base_uri: uri}}

      uri ->
        send(parent, {:unexpected_load, uri})
        {:error, :unexpected_load}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert_received {:loaded, "/api/common.yaml"}
    refute_received {:unexpected_load, _uri}

    assert get_in(resolved, ["parameter", "schema"]) == %{
             "$ref" => "/api/schemas/base.yaml",
             "allOf" => [%{"$ref" => "/api/schemas/constraints.yaml"}]
           }
  end

  test "bundled external fragments compile nested relative refs against the external base" do
    root = %{
      "parameter" => %{"$ref" => "./components/common.yaml#/components/parameters/User"}
    }

    common = %{
      "components" => %{
        "parameters" => %{
          "User" => %{
            "schema" => %{"$ref" => "#/components/schemas/User"}
          }
        },
        "schemas" => %{
          "User" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"$ref" => "./defs.yaml#/UserId"}
            }
          }
        }
      }
    }

    defs = %{"UserId" => %{"type" => "integer"}}

    loader = fn
      "/api/components/common.yaml" ->
        {:ok, %{document: common, base_uri: "/api/components/common.yaml"}}

      "/api/components/defs.yaml" ->
        {:ok, %{document: defs, base_uri: "/api/components/defs.yaml"}}
    end

    assert {:ok, resolved} =
             Ref.resolve_selected(root,
               base_uri: "/api/openapi.yaml",
               loader: loader,
               select: fn
                 ["parameter"], %{"$ref" => _} -> true
                 _path, _node -> false
               end
             )

    assert get_in(resolved, ["parameter", "schema"]) ==
             %{"$ref" => "/api/components/common.yaml#/components/schemas/User"}

    assert {:ok, bundled} =
             JSONSchex.bundle_fragment(resolved,
               entry: "#/parameter/schema",
               base_uri: "/api/openapi.yaml",
               loader: loader
             )

    assert {:ok, compiled} = JSONSchex.compile(bundled)
    assert JSONSchex.validate(compiled, %{"id" => 123}) == :ok
    assert {:error, [%{rule: :type, path: ["id"]}]} = JSONSchex.validate(compiled, %{"id" => "x"})

    assert {:ok, compiled_fragment} = JSONSchex.compile_fragment(bundled, entry: "#/parameter/schema")
    assert JSONSchex.validate(compiled_fragment, %{"id" => 123}) == :ok
    assert {:error, [%{rule: :type, path: ["id"]}]} = JSONSchex.validate(compiled_fragment, %{"id" => "x"})
  end
end

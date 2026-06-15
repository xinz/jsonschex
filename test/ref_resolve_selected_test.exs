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

  test "unselected local ref is preserved and not traversed" do
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

    assert {:ok, ^document} = Ref.resolve_selected(document, select: select)
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
            "schema" => %{"$ref" => "./schemas/user-id.yaml"}
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

    assert schema == %{"$ref" => "file:///mirror/schemas/user-id.yaml"}
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

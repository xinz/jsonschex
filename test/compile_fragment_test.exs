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

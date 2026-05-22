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
end

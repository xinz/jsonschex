defmodule JSONSchex.Test.ResourceContext do
  use ExUnit.Case, async: true

  alias JSONSchex.ResourceContext

  test "decodes escaped pointer tokens" do
    target = %{"type" => "integer"}
    document = %{"a/b" => %{"m~n" => target}}

    assert {:ok, context} =
             ResourceContext.resolve(document, "/api/root.json", "/a~1b/m~0n")

    assert context.target == target
    assert context.resource == document
    assert context.resource_base == "/api/root.json"
    assert context.inherited_base == "/api/root.json"
  end

  test "tracks arrays and multiple nested id resource boundaries" do
    target_resource = %{
      "$id" => "child.json",
      "value" => %{"type" => "integer"}
    }

    parent_resource = %{
      "$id" => "nested/",
      "children" => [target_resource]
    }

    document = %{"items" => [parent_resource]}

    assert {:ok, context} =
             ResourceContext.resolve(
               document,
               "/api/root.json",
               "/items/0/children/0/value"
             )

    assert context.target == %{"type" => "integer"}
    assert context.resource == target_resource
    assert context.resource_base == "/api/nested/"
    assert context.inherited_base == "/api/nested/child.json"

    assert context.resources == [
             {parent_resource, "/api/root.json"},
             {target_resource, "/api/nested/"}
           ]
  end

  test "returns a target that is itself a resource root" do
    target = %{"$id" => "nested/target.json", "type" => "integer"}
    document = %{"schemas" => [target]}

    assert {:ok, context} =
             ResourceContext.resolve(document, "/api/root.json", "/schemas/0")

    assert context.target == target
    assert context.resource == target
    assert context.resource_base == "/api/root.json"
    assert context.inherited_base == "/api/root.json"
    assert context.resources == [{target, "/api/root.json"}]
  end

  test "rejects missing map keys and invalid array indexes" do
    document = %{"items" => [%{"type" => "integer"}]}

    assert :error == ResourceContext.resolve(document, "/api/root.json", "/missing")
    assert :error == ResourceContext.resolve(document, "/api/root.json", "/items/not-an-index")
    assert :error == ResourceContext.resolve(document, "/api/root.json", "/items/2")
  end
end

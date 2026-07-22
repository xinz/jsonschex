defmodule JSONSchex.Test.Anchor do
  use ExUnit.Case

  test "Location-independent identifier" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "#foo",
      "$defs" => %{
          "A" => %{
              "$anchor" => "foo",
              "type" => "integer"
          }
      }
    }

    {:ok, c} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(c, 1)
    assert {:error, [error]} = JSONSchex.validate(c, "1")
    assert error.rule == :type
    assert JSONSchex.format_error(error) =~ "Expected type integer, got string"
  end

  test "anchor targets resolve relative refs from their containing URI resource" do
    parent = self()

    schema = %{
      "$id" => "https://example.test/root.json",
      "$ref" => "#target",
      "$defs" => %{
        "Target" => %{
          "$anchor" => "target",
          "$ref" => "schemas/value.json"
        }
      }
    }

    loader = fn
      "https://example.test/schemas/value.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{"type" => "integer"}}
    end

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: loader)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert_received {:loaded, "https://example.test/schemas/value.json"}
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "anchor targets resolve relative refs from their containing filesystem resource" do
    parent = self()

    schema = %{
      "$id" => "/api/root.json",
      "$ref" => "#target",
      "$defs" => %{
        "Target" => %{
          "$anchor" => "target",
          "$ref" => "schemas/value.json"
        }
      }
    }

    loader = fn
      "/api/schemas/value.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{"type" => "integer"}}
    end

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: loader)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert_received {:loaded, "/api/schemas/value.json"}
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "anchors inside an id resource retain that resource base" do
    parent = self()

    schema = %{
      "$id" => "https://example.test/root.json",
      "$ref" => "resources/target.json#target",
      "$defs" => %{
        "TargetResource" => %{
          "$id" => "resources/target.json",
          "$anchor" => "target",
          "$ref" => "value.json"
        }
      }
    }

    loader = fn
      "https://example.test/resources/value.json" = uri ->
        send(parent, {:loaded, uri})
        {:ok, %{"type" => "integer"}}
    end

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: loader)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert_received {:loaded, "https://example.test/resources/value.json"}
    assert {:error, _} = JSONSchex.validate(compiled, "1")
  end

  test "dynamic anchor targets retain their resource base for recursive refs" do
    schema = %{
      "$id" => "https://example.test/node.json",
      "$ref" => "#node",
      "$defs" => %{
        "Node" => %{
          "$dynamicAnchor" => "node",
          "type" => "object",
          "properties" => %{
            "next" => %{"$dynamicRef" => "#node"}
          }
        }
      }
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(compiled, %{"next" => %{}})
    assert {:error, _} = JSONSchex.validate(compiled, %{"next" => "invalid"})
  end

end

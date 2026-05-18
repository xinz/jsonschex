defmodule JSONSchex.Test.RefInternalRegression do
  use ExUnit.Case, async: true

  alias JSONSchex.ScopeScanner

  test "compiler still precompiles explicit local pointer refs when the root has an $id" do
    schema = %{
      "$id" => "https://example.com/root.json",
      "type" => "object",
      "properties" => %{
        "foo" => %{"type" => "string"},
        "bar" => %{"$ref" => "#/properties/foo"}
      }
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)

    assert Map.has_key?(compiled.defs, "#/properties/foo")
    assert compiled.defs["#/properties/foo"].raw == %{"type" => "string"}

    assert :ok == JSONSchex.validate(compiled, %{"bar" => "hello"})
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"bar" => 123})
  end

  test "scope scanning reaches contentSchema so nested ids participate in ref resolution" do
    schema = %{
      "$id" => "https://example.com/root.json",
      "type" => "string",
      "contentMediaType" => "application/json",
      "contentSchema" => %{
        "$ref" => "inner",
        "allOf" => [
          %{
            "$id" => "inner",
            "type" => "integer"
          }
        ]
      }
    }

    {registry, _refs} = ScopeScanner.scan(schema)
    assert Map.has_key?(registry, "https://example.com/inner")

    assert {:ok, compiled} = JSONSchex.compile(schema, content_assertion: true)
    assert Map.has_key?(compiled.defs, "https://example.com/inner")

    assert :ok == JSONSchex.validate(compiled, "1")
    assert {:error, errors} = JSONSchex.validate(compiled, ~S("1"))
    assert Enum.any?(errors, &(&1.rule == :type))
  end

  test "validator JIT fallback still resolves local pointer fragments inside loaded schemas with a different root $id" do
    loader = fn
      "http://example.com/remote.json" ->
        {:ok,
         %{
           "$id" => "http://example.com/actual/loaded.json",
           "type" => "object",
           "properties" => %{
             "foo" => %{"type" => "integer"}
           }
         }}

      _ ->
        {:error, :enoent}
    end

    schema = %{
      "$ref" => "http://example.com/remote.json#/properties/foo"
    }

    assert {:ok, compiled} = JSONSchex.compile(schema, loader: loader)

    assert :ok == JSONSchex.validate(compiled, 42)
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, "not an integer")
  end

  test "runtime validation loads path-like external refs through loader using document URI without fragment" do
    parent = self()

    loader = fn
      "specs/schemas/common.json" ->
        send(parent, {:loaded, "specs/schemas/common.json"})

        {:ok,
         %{
           "$defs" => %{
             "id" => %{"type" => "integer"}
           }
         }}

      other ->
        send(parent, {:unexpected_load, other})
        {:error, :enoent}
    end

    schema = %{
      "type" => "object",
      "properties" => %{
        "id" => %{"$ref" => "schemas/common.json#/$defs/id"}
      }
    }

    assert {:ok, compiled} =
             JSONSchex.compile(schema,
               base_uri: "specs/root.json",
               loader: loader
             )

    assert :ok == JSONSchex.validate(compiled, %{"id" => 1})
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"id" => "1"})

    assert_received {:loaded, "specs/schemas/common.json"}
    refute_received {:unexpected_load, _}
  end
end

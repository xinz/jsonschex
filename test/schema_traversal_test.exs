defmodule JSONSchex.Test.SchemaTraversal do
  use ExUnit.Case, async: true

  alias JSONSchex.{SchemaTraversal, ScopeScanner}

  test "scope reduction preserves Map.values traversal and duplicate-identity precedence" do
    target_uri = "https://example.test/repeated"

    properties =
      Map.new(1..40, fn index ->
        {"property-#{index}",
         %{
           "$id" => target_uri,
           "$anchor" => "shared",
           "const" => index
         }}
      end)

    expected = properties |> Map.values() |> List.last()
    schema = %{"properties" => properties, "$ref" => target_uri}

    reduced =
      schema
      |> SchemaTraversal.reduce_scope_subschemas([],
        fn subschema, acc ->
          [subschema | acc]
        end)
      |> Enum.reverse()

    assert reduced === SchemaTraversal.scope_subschemas(schema)

    {registry, _refs} = ScopeScanner.scan(schema)
    assert Map.fetch!(registry, target_uri) === expected
    assert Map.fetch!(registry, target_uri <> "#shared") === expected

    assert {:ok, compiled} = JSONSchex.compile(schema)
    assert Map.fetch!(compiled.defs, target_uri).raw === expected
  end
end

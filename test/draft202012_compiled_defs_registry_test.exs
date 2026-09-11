defmodule JSONSchex.Test.Draft202012CompiledDefsRegistryTest do
  use ExUnit.Case, async: true

  alias JSONSchex.{Compiler, ScopeScanner}
  alias JSONSchex.Draft202012.Schemas
  alias JSONSchex.Types.Schema

  @base_uri "https://json-schema.org/draft/2020-12"
  @schema_uri @base_uri <> "/schema"
  @family_uris [
    @schema_uri,
    @base_uri <> "/meta/core",
    @base_uri <> "/meta/applicator",
    @base_uri <> "/meta/unevaluated",
    @base_uri <> "/meta/validation",
    @base_uri <> "/meta/meta-data",
    @base_uri <> "/meta/format-annotation",
    @base_uri <> "/meta/format-assertion",
    @base_uri <> "/meta/content"
  ]

  test "compiled family registry retains every canonical resource and dynamic meta anchor" do
    registries = Enum.map(@family_uris, &Schemas.compiled_defs/1)
    [registry | remaining_registries] = registries

    assert map_size(registry) == 26
    assert Enum.all?(remaining_registries, &(&1 === registry))

    for uri <- @family_uris do
      assert {:ok, raw_schema} = Schemas.fetch(uri)
      assert %Schema{} = resource = Map.fetch!(registry, uri)
      assert resource.source_id == uri
      assert resource.raw === raw_schema
      assert Map.fetch!(registry, uri <> "#meta") === resource
    end
  end

  test "compiled defs already contain every identity found by a second scope scan" do
    for uri <- @family_uris do
      assert {:ok, raw_schema} = Schemas.fetch(uri)
      assert {:ok, compiled_schema} = Compiler.compile(raw_schema, base_uri: uri)
      {scanned_defs, _refs} = ScopeScanner.scan(raw_schema)

      compiler_registry =
        %{}
        |> Map.put(uri, compiled_schema)
        |> Map.merge(compiled_schema.defs || %{})

      registry_with_second_scan =
        Enum.reduce(scanned_defs, compiler_registry, fn {scanned_uri, _raw_schema}, acc ->
          Map.put_new(acc, scanned_uri, compiled_schema)
        end)

      assert registry_with_second_scan === compiler_registry
    end
  end

  test "combined family registry retains each local definition target" do
    registry = Schemas.compiled_defs(@schema_uri)

    expected_sources = %{
      "#/$defs/anchorString" => @base_uri <> "/meta/core",
      "#/$defs/nonNegativeInteger" => @base_uri <> "/meta/validation",
      "#/$defs/nonNegativeIntegerDefault0" => @base_uri <> "/meta/validation",
      "#/$defs/schemaArray" => @base_uri <> "/meta/applicator",
      "#/$defs/simpleTypes" => @base_uri <> "/meta/validation",
      "#/$defs/stringArray" => @base_uri <> "/meta/validation",
      "#/$defs/uriReferenceString" => @base_uri <> "/meta/core",
      "#/$defs/uriString" => @base_uri <> "/meta/core"
    }

    for {pointer, source_id} <- expected_sources do
      assert %Schema{source_id: ^source_id} = Map.fetch!(registry, pointer)
    end
  end

  test "built-in local refs and dynamic meta anchors remain valid without a loader" do
    validation_uri = @base_uri <> "/meta/validation"

    assert {:ok, local_ref_schema} =
             JSONSchex.compile(%{
               "$schema" => @schema_uri,
               "$ref" => validation_uri <> "#/$defs/nonNegativeInteger"
             })

    assert :ok == JSONSchex.validate(local_ref_schema, 0)
    assert {:error, [%{rule: :minimum, value: -1}]} = JSONSchex.validate(local_ref_schema, -1)

    assert {:ok, dynamic_ref_schema} =
             JSONSchex.compile(%{
               "$schema" => @schema_uri,
               "$dynamicRef" => validation_uri <> "#meta"
             })

    assert :ok == JSONSchex.validate(dynamic_ref_schema, %{"minLength" => 0})

    assert {:error, [%{rule: :minimum, value: -1}]} =
             JSONSchex.validate(dynamic_ref_schema, %{"minLength" => -1})
  end
end

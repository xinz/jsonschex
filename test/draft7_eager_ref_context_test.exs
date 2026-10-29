defmodule JSONSchex.Test.Draft7EagerRefContext do
  use ExUnit.Case

  @resource_uri "https://example.com/nested/"

  for mode <- [:schema, :fragment] do
    test "Draft 7 eager pointer targets retain their resource root in #{mode} compilation" do
      pointer = "#/definitions/holder/entry"
      resource = %{
        "$id" => "nested/",
        "definitions" => %{"value" => %{"type" => "integer"}},
        "entry" => %{"$ref" => @resource_uri <> "#/definitions/value"}
      }
      compiled = compile_pointer!(resource, pointer, unquote(mode))

      assert Map.has_key?(compiled.defs, pointer)
      refute Map.has_key?(compiled.defs, "#/definitions/value")
      assert compiled.defs[pointer].source_id == @resource_uri
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
      assert compiled.defs[pointer].raw === resource
    end

    test "Draft 7 eager fragment-ID targets keep the enclosing pointer root in #{mode} compilation" do
      pointer = "#/definitions/holder/definitions/named/entry"
      resource = %{
        "$id" => "nested/",
        "definitions" => %{
          "value" => %{"type" => "integer"},
          "named" => %{
            "$id" => "#named",
            "entry" => %{"$ref" => "#/definitions/value"}
          }
        }
      }
      compiled = compile_pointer!(resource, pointer, unquote(mode))

      # Discovery-only references must not become eager root-document aliases.
      # The compiled outer pointer has to retain the actual resource root itself.
      refute Map.has_key?(compiled.defs, "#/definitions/value")
      assert compiled.defs[pointer].source_id == @resource_uri <> "#named"
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
      assert compiled.defs[pointer].raw === resource
    end

    test "Draft 7 eager entry-owned resources apply their ID once in #{mode} compilation" do
      pointer = "#/definitions/holder/entry"
      entry_uri = @resource_uri <> "entry/"
      entry = %{
        "$id" => "entry/",
        "definitions" => %{"value" => %{"type" => "integer"}},
        "allOf" => [%{"$ref" => entry_uri <> "#/definitions/value"}]
      }
      resource = %{"$id" => "nested/", "entry" => entry}
      compiled = compile_pointer!(resource, pointer, unquote(mode))

      assert compiled.defs[pointer].source_id == entry_uri
      assert compiled.defs[pointer].raw === entry
      refute Map.has_key?(compiled.defs, entry_uri <> "entry/")
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, [%{rule: :type, context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, "1")
    end
  end

  defp compile_pointer!(resource, pointer, mode) do
    document = %{
      "$id" => "https://example.com/root",
      "definitions" => %{"holder" => resource},
      "allOf" => [%{"$ref" => pointer}]
    }
    loader = fn uri -> flunk("Unexpected external load: #{uri}") end

    result =
      case mode do
        :schema -> JSONSchex.compile(document, draft: "draft7", loader: loader)
        :fragment -> JSONSchex.compile_fragment(document, entry: "#", draft: "draft7", loader: loader)
      end

    assert {:ok, compiled} = result
    compiled
  end
end

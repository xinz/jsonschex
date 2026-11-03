defmodule JSONSchex.Test.CachedReference do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Schema, ValidationContext}
  alias JSONSchex.Validator
  alias JSONSchex.Validator.Reference

  @caller "https://example.test/caller.json"
  @remote "https://example.test/remote.json"

  for draft <- ["draft7", "draft2020_12"] do
    @draft draft

    test "cached resources and absolute anchors retain their pointer owner and annotations (#{draft})" do
      entry = %{"properties" => %{"value" => %{"$ref" => "#/definitions/Value"}}}
      anchored =
        if @draft == "draft7",
          do: Map.put(entry, "$id", "#entry"),
          else: Map.put(entry, "$anchor", "entry")

      resource = Map.merge(entry, %{
        "$id" => "remote.json",
        "definitions" => %{"Value" => %{"type" => "integer"}, "entry" => anchored}
      })
      raw = %{
        "$id" => @caller,
        "definitions" => %{"Value" => %{"const" => "caller"}, "resource" => resource}
      }
      loader = fn uri -> flunk("Cached reference unexpectedly loaded #{uri}") end
      assert {:ok, root} = JSONSchex.compile(raw, draft: @draft, loader: loader)
      evaluated = MapSet.new(["previous"])
      context = {["entry"], evaluated, context(root)}

      for uri <- [@remote, @remote <> "#entry"] do
        assert %Schema{} = Map.fetch!(root.defs, uri)
        assert {:ok, annotations} = Reference.validate_ref(%{"value" => 7}, uri, uri, context)
        assert annotations == MapSet.put(evaluated, "value")
        assert Reference.validate_ref(%{"value" => 7}, uri, context) === {:ok, annotations}

        assert {:error, _} = result = Reference.validate_ref(%{"value" => "caller"}, uri, uri, context)
        assert result === Reference.validate_ref(%{"value" => "caller"}, uri, context)
      end
    end

    test "fragment-only cached pointers do not use the shared registry (#{draft})" do
      assert {:ok, wrong} = JSONSchex.compile(false, draft: @draft)

      for pointer <- ["#/definitions/Value", "#%2Fdefinitions%2FValue"] do
        raw = %{"definitions" => %{"Value" => %{"const" => "local"}}, "$ref" => "#/definitions/Value"}
        assert {:ok, root} = JSONSchex.compile(raw, draft: @draft)
        target = Map.fetch!(root.local_refs, "#/definitions/Value")
        # Eager compilation may leave the encoded spelling for JIT; this tests a cache hit.
        root = %{root |
          defs: Map.put(root.defs, pointer, wrong),
          local_refs: Map.put(root.local_refs, pointer, target)
        }
        evaluated = MapSet.new(["previous"])
        context = {[], evaluated, context(root)}

        assert {:ok, ^evaluated} = Reference.validate_ref("local", pointer, pointer, context)
        assert {:error, _} = Reference.validate_ref("other", pointer, pointer, context)
      end
    end

    test "missing or non-schema cache entries fall back to the original reference (#{draft})" do
      parent = self()
      loader = fn
        @remote ->
          send(parent, :loaded_remote)
          {:ok, %{"const" => "loaded"}}
        uri ->
          flunk("Fallback loaded the cached key instead of the original reference: #{uri}")
      end
      assert {:ok, original} = JSONSchex.compile(%{},
        draft: @draft, base_uri: @caller, loader: loader)
      evaluated = MapSet.new(["previous"])

      for stale_key <- ["https://example.test/stale.json", ""],
          cached <- [:missing, nil, false, %{}] do
        root = if cached == :missing, do: original,
          else: %{original | defs: Map.put(original.defs, stale_key, cached)}
        context = {[], evaluated, context(root)}

        assert {:ok, ^evaluated} = Reference.validate_ref("loaded", "remote.json", stale_key, context)
        assert_received :loaded_remote
      end
    end

    test "cached boolean targets preserve incoming annotations and validation errors (#{draft})" do
      assert {:ok, root} = JSONSchex.compile(%{}, draft: @draft)
      evaluated = MapSet.new(["previous"])

      for boolean <- [true, false] do
        assert {:ok, target} = JSONSchex.compile(boolean, draft: @draft)
        root = %{root | defs: Map.put(root.defs, @remote, target)}
        validation_context = context(root)
        context = {[], evaluated, validation_context}
        result = Reference.validate_ref("anything", "remote.json", @remote, context)

        assert result === Validator.validate_entry(target, "anything", [], validation_context, evaluated)
        if boolean do
          assert {:ok, ^evaluated} = result
        else
          assert {:error, [_]} = result
        end
      end
    end
  end

  defp context(root) do
    %ValidationContext{
      root_schema: root,
      source_id: root.source_id,
      raw: root.raw,
      local_refs: root.local_refs,
      scope_stack: if(root.source_id, do: [root.source_id], else: [])
    }
  end
end

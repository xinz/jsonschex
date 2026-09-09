defmodule JSONSchex.Test.CompilerReuse do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Error, Schema}
  alias JSONSchex.URIUtil

  @root "https://example.test/root.json"
  @custom "https://example.test/custom-dialect"
  @core "https://json-schema.org/draft/2020-12/vocab/core"
  @unknown "https://example.test/unknown-vocabulary"

  test "schema-bearing rule slots retain resource identities without treating literal data as schemas" do
    leaf = %{
      "$id" => "nested/value.json",
      "$anchor" => "static",
      "$dynamicAnchor" => "dynamic",
      "type" => "integer",
      "minimum" => 2
    }

    single_slots = ~w(additionalProperties contains contentSchema items not propertyNames unevaluatedItems unevaluatedProperties)
    map_slots = ~w(properties patternProperties dependentSchemas $defs definitions)
    list_slots = ~w(allOf anyOf oneOf prefixItems)
    containers =
      Enum.map(single_slots, &%{&1 => leaf}) ++
        Enum.map(map_slots, &%{&1 => %{"value" => leaf}}) ++
        Enum.map(list_slots, &%{&1 => [leaf]}) ++
        [
          %{"if" => leaf, "then" => true, "else" => false},
          %{"if" => true, "then" => leaf},
          %{"if" => false, "else" => leaf},
          %{"dependencies" => %{"value" => leaf, "other" => ["required"]}},
          %{"then" => leaf}
        ]

    # Legacy definitions and an inactive then have no initial compiled candidate.
    # Literal payloads must not become candidates or trigger keyword compilation.
    literal = %{"$id" => "https://example.test/literal", "type" => "invalid"}
    for container <- containers do
      raw = Map.merge(container, %{
        "$id" => @root,
        "enum" => [literal],
        "const" => literal,
        "x-data" => %{"nested" => literal}
      })
      assert {:ok, compiled} = JSONSchex.compile(raw,
        format_assertion: true, content_assertion: true)

      for suffix <- ["", "#static", "#dynamic"] do
        registered = Map.fetch!(compiled.defs, "https://example.test/nested/value.json" <> suffix)
        assert registered.raw === leaf
        assert registered.source_id == "https://example.test/nested/value.json"
        assert registered.format_assertion
        assert registered.content_assertion
        assert :ok == JSONSchex.validate(registered, 2)
        assert {:error, [%{rule: :minimum}]} = JSONSchex.validate(registered, 1)
      end

      refute Map.has_key?(compiled.defs, literal["$id"])
      assert rule(compiled, :const).params === literal
      assert rule(compiled, :enum).params === [literal]
    end
  end

  test "scope registration preserves scanner bases rather than a structurally compiled candidate base" do
    child = %{"$id" => "child.json", "$anchor" => "target", "$ref" => "leaf.json"}
    raw = %{"properties" => %{"child" => child}}
    assert {:ok, compiled} = JSONSchex.compile(raw, base_uri: "/api/document.json")
    structural = property(compiled, "child")
    assert structural.source_id == "/api/child.json"
    assert rule(structural, :ref).params.resolved_uri == "/api/leaf.json"

    # Ordinary scan/1 starts at nil even when node compilation has a base_uri.
    for key <- ["child.json", "child.json#target"] do
      registered = Map.fetch!(compiled.defs, key)
      assert registered.raw === child
      assert registered.source_id == "child.json"
      assert rule(registered, :ref).params.resolved_uri == "leaf.json"
    end

    document = %{"container" => %{"$id" => "nested/container.json", "schema" => raw}}
    assert {:ok, fragment} = JSONSchex.compile_fragment(document,
      entry: "#/container/schema", base_uri: "/api/document.json")
    assert fragment.raw === document
    assert property(fragment, "child").source_id == "/api/child.json"
    registered = Map.fetch!(fragment.defs, "/api/nested/child.json#target")
    assert registered.raw === child
    assert registered.source_id == "/api/nested/child.json"
    assert rule(registered, :ref).params.resolved_uri == "/api/nested/leaf.json"
  end

  test "explicit defs pointers use the initial base even when their raw schema matches a local definition" do
    for id <- [nil, "value.json", "https://example.test/absolute/value.json"] do
      target = %{"$ref" => "leaf.json"}
      target = if id, do: Map.put(target, "$id", id), else: target
      raw = %{
        "$id" => "nested/root.json",
        "$ref" => "#/$defs/Value",
        "$defs" => %{"Value" => target}
      }
      assert {:ok, compiled} = JSONSchex.compile(raw, base_uri: "/api/document.json")
      resolved = Map.fetch!(compiled.defs, "#/$defs/Value")
      expected_base = URIUtil.resolve("/api/document.json", id)
      assert resolved.raw === target
      assert resolved.source_id == expected_base
      assert rule(resolved, :ref).params.resolved_uri == URIUtil.resolve(expected_base, "leaf.json")
    end
  end

  test "fragment pointers resolve against the document before reusing conflicting entry defs or booleans" do
    local = %{"minimum" => 1}
    entry = %{
      "$anchor" => "entry",
      "$ref" => "#/$defs/Value",
      "$defs" => %{"Value" => local}
    }

    for target <- [%{"minimum" => 1.0}, %{"type" => "string"}, true, false, :missing] do
      document = %{"schema" => entry}
      document = if target == :missing, do: document,
        else: Map.put(document, "$defs", %{"Value" => target})
      assert {:ok, compiled} = JSONSchex.compile_fragment(document,
        entry: "#/schema", base_uri: "/api/document.json")
      assert compiled.raw === document

      # The scope entry retains the selected schema's original raw and local defs,
      # not the containing document or the subsequently merged runtime definitions.
      anchored = Map.fetch!(compiled.defs, "/api/document.json#entry")
      assert anchored.raw === entry
      assert anchored.defs["#/$defs/Value"].raw === local

      resolved = Map.fetch!(compiled.defs, "#/$defs/Value")
      expected = if target == :missing, do: local, else: target
      assert resolved.raw === expected
      if is_boolean(expected) do
        assert resolved.source_id == nil
        assert (JSONSchex.validate(resolved, "anything") == :ok) == expected
      else
        assert {:ok, independently_compiled} = JSONSchex.compile(expected, base_uri: "/api/document.json")
        assert resolved.rules === independently_compiled.rules
      end
    end
  end

  test "only exact initial defs keys are candidates and unsuccessful pointer batches retain existing defs" do
    local = %{"type" => "integer"}
    other = %{"type" => "string"}
    for resolved? <- [true, false] do
      defs = %{"a/b" => local}
      defs = if resolved?, do: Map.put(defs, "a", %{"b" => other}), else: defs
      raw = %{
        "$defs" => defs,
        "allOf" => [%{"$ref" => "#/$defs/a/b"}, %{"$ref" => "#/$defs/a~1b"}]
      }
      assert {:ok, compiled} = JSONSchex.compile(raw)
      assert compiled.defs["#/$defs/a~1b"].raw === local
      expected = if resolved?, do: other, else: local
      assert compiled.defs["#/$defs/a/b"].raw === expected
      assert :ok == JSONSchex.validate(compiled.defs["#/$defs/a/b"], if(resolved?, do: "s", else: 1))
    end
  end

  test "duplicate identities use scanner-selected raw with strict numeric equality" do
    first = %{"$id" => "https://example.test/duplicate", "minimum" => 1}
    for minimum <- [1.0, 2] do
      selected = %{first | "minimum" => minimum}
      raw = %{
        "$defs" => %{"Initial" => first},
        "definitions" => %{"Selected" => selected},
        "$ref" => first["$id"]
      }
      # Scope scanning visits legacy definitions after $defs, but legacy
      # definitions do not provide an initially structurally compiled candidate.
      assert {:ok, compiled} = JSONSchex.compile(raw)
      assert compiled.defs["#/$defs/Initial"].raw === first
      registered = Map.fetch!(compiled.defs, first["$id"])
      assert registered.raw === selected
      assert rule(registered, :minimum).params === minimum
      assert :ok == JSONSchex.validate(compiled, minimum)
      assert {:error, [%{rule: :minimum}]} = JSONSchex.validate(compiled, 0)
    end
  end

  test "scanner-only anchor collisions reject same-base candidates without their own id" do
    for initial_keyword <- ["$anchor", "$dynamicAnchor"],
        selected_keyword <- ["$anchor", "$dynamicAnchor"],
        minimum <- [1.0, 2] do
      initial = %{initial_keyword => "shared", "minimum" => 1}
      selected = %{selected_keyword => "shared", "minimum" => minimum}
      raw = %{
        "$id" => @root,
        "$defs" => %{"Initial" => initial},
        "definitions" => %{"Selected" => selected},
        "$ref" => @root <> "#shared"
      }

      # Both nodes inherit exactly the same base, so only the raw guard can
      # reject the initial anchor candidate when the later scanner entry wins.
      # Same-keyword cases also distinguish numeric equality from strict equality.
      assert {:ok, compiled} = JSONSchex.compile(raw)
      candidate = Map.fetch!(compiled.defs, "#/$defs/Initial")
      assert candidate.raw === initial
      assert candidate.source_id === @root
      assert rule(candidate, :minimum).params === 1

      registered = Map.fetch!(compiled.defs, @root <> "#shared")
      assert registered.raw === selected
      assert registered.source_id === @root
      assert rule(registered, :minimum).params === minimum
      refute registered.rules === candidate.rules
      assert :ok == JSONSchex.validate(compiled, minimum)
      assert {:error, [%{rule: :minimum}]} = JSONSchex.validate(compiled, 0)
    end
  end

  test "matching custom vocabularies retain loader calls per scope and existing defs and root skips" do
    parent = self()
    loader = fn uri ->
      send(parent, {:loaded, uri})
      {:ok, %{}}
    end
    child = %{
      "$id" => "child.json",
      "$schema" => @custom,
      "$anchor" => "static",
      "$dynamicAnchor" => "dynamic",
      "type" => "integer"
    }
    raw = %{"$id" => @root, "$schema" => @custom, "properties" => %{"child" => child}}
    assert {:ok, compiled} = JSONSchex.compile(raw, loader: loader)
    # One root dialect load and one for each of the child's three identities.
    for _ <- 1..4, do: assert_received({:loaded, @custom})
    refute_received {:loaded, _}
    assert compiled.defs[@root].raw === raw
    assert compiled.defs[@root].defs == %{}
    assert :ok == JSONSchex.validate(compiled, %{"child" => 1})
    assert {:error, [%{rule: :type}]} = JSONSchex.validate(compiled, %{"child" => "1"})

    collision = %{"$id" => "#/$defs/Existing", "$schema" => @custom, "type" => "integer"}
    assert {:ok, skipped} = JSONSchex.compile(%{"$defs" => %{"Existing" => collision}}, loader: loader)
    assert skipped.defs["#/$defs/Existing"].raw === collision
    refute_received {:loaded, _}
  end

  test "scope candidates do not bypass dialect loader errors or required vocabulary checks" do
    parent = self()
    for mode <- [:loader_error, :metaschema_error, :inline_error] do
      child = %{"$id" => "https://example.test/child", "$schema" => @custom, "type" => "integer"}
      child = if mode == :inline_error,
        do: Map.put(child, "$vocabulary", %{@unknown => true}), else: child
      loader = fn uri ->
        send(parent, {:loaded, uri})
        case mode do
          :loader_error -> {:error, :unavailable}
          _ -> {:ok, %{"$vocabulary" => %{@unknown => true}}}
        end
      end
      assert {:error, %Error{} = error} = JSONSchex.compile(
        %{"properties" => %{"child" => child}}, loader: loader)
      if mode == :loader_error do
        assert error.context.contrast == "load_remote"
        assert error.context.input == @custom
        assert error.context.error_detail == :unavailable
      else
        assert error.rule == :unsupported_vocabulary
        assert error.path == ["$vocabulary", @unknown]
        assert error.value === true
      end
      if mode != :inline_error, do: assert_received({:loaded, @custom})
      refute_received {:loaded, _}
    end
  end

  test "a scope with a different vocabulary is recompiled rather than inheriting structural rules" do
    parent = self()
    loader = fn uri ->
      send(parent, {:loaded, uri})
      {:ok, %{"$vocabulary" => %{@core => true}}}
    end
    child = %{
      "$id" => "https://example.test/child",
      "$schema" => @custom,
      "$anchor" => "value",
      "type" => "integer"
    }
    raw = %{"properties" => %{"child" => child}, "$ref" => child["$id"]}
    assert {:ok, compiled} = JSONSchex.compile(raw, loader: loader)
    assert rule(property(compiled, "child"), :type).params == "integer"
    for key <- [child["$id"], child["$id"] <> "#value"] do
      registered = Map.fetch!(compiled.defs, key)
      assert registered.raw === child
      assert registered.rules == []
      assert :ok == JSONSchex.validate(registered, "not an integer")
    end
    assert_received {:loaded, @custom}
    assert_received {:loaded, @custom}
    refute_received {:loaded, _}
  end

  test "scope rule order matches id-deleted compilation across flatmap and HAMT boundaries" do
    counts = [0] ++ Enum.to_list(24..36) ++ [64, 128]
    changed_orders = for count <- counts do
      extras = if count == 0, do: %{}, else: Map.new(1..count, &{"x-key-#{&1}", &1})
      child = Map.merge(extras, %{
        "$id" => "https://example.test/ordered",
        "type" => "integer",
        "minimum" => 10,
        "maximum" => 20,
        "multipleOf" => 3,
        "const" => 12,
        "unevaluatedProperties" => false,
        "unevaluatedItems" => false
      })
      assert {:ok, compiled} = JSONSchex.compile(%{"$defs" => %{"Child" => child}})
      assert {:ok, expected} = JSONSchex.compile(Map.delete(child, "$id"), base_uri: child["$id"])
      registered = Map.fetch!(compiled.defs, child["$id"])
      assert registered.rules === expected.rules, "rule order changed with #{count} extension keys"
      assert JSONSchex.validate(registered, 1) === JSONSchex.validate(expected, 1)
      assert Enum.map(Enum.take(registered.rules, -2), & &1.name) ==
        [:unevaluatedProperties, :unevaluatedItems]

      # Check that this fixture actually exercises an order-changing deletion,
      # after removing the two finalizers rather than on the original raw map.
      standard = Map.drop(child, ["unevaluatedProperties", "unevaluatedItems"])
      before = standard |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == "$id"))
      after_delete = standard |> Map.delete("$id") |> Enum.map(&elem(&1, 0))
      before != after_delete
    end
    assert Enum.any?(changed_orders), "expected an id deletion to cross a map iteration-order boundary"
  end

  test "static and dynamic anchors retain recursive resource scope and the root special case" do
    node = %{
      "$id" => "nodes/node.json",
      "$anchor" => "static",
      "$dynamicAnchor" => "node",
      "type" => "object",
      "properties" => %{"next" => %{"$dynamicRef" => "#node"}}
    }
    raw = %{
      "$id" => @root,
      "$ref" => "nodes/node.json#static",
      "$defs" => %{"Node" => node}
    }
    assert {:ok, compiled} = JSONSchex.compile(raw)
    for suffix <- ["", "#static", "#node"] do
      registered = Map.fetch!(compiled.defs, "https://example.test/nodes/node.json" <> suffix)
      assert registered.raw === node
      assert registered.source_id == "https://example.test/nodes/node.json"
      assert rule(property(registered, "next"), :dynamicRef).params == "#node"
    end
    assert compiled.defs[@root].raw === raw
    assert Map.keys(compiled.defs[@root].defs) == ["#/$defs/Node"]
    assert :ok == JSONSchex.validate(compiled, %{"next" => %{"next" => %{}}})
    assert {:error, _} = JSONSchex.validate(compiled, %{"next" => %{"next" => "invalid"}})
  end

  @tag :performance
  test "properties chains with unique absolute ids scale approximately linearly in reductions" do
    small = chain(100)
    large = chain(400)

    # Construct both inputs and warm compilation outside the measured intervals.
    assert {:ok, _} = JSONSchex.compile(small)
    assert {:ok, _} = JSONSchex.compile(large)
    small_work = compile_reductions(small)
    large_work = compile_reductions(large)
    assert large_work < small_work * 6,
           "quadrupling depth used #{large_work} vs #{small_work} reductions (#{Float.round(large_work / small_work, 2)}x)"
  end

  defp rule(%Schema{rules: rules}, name), do: Enum.find(rules, &(&1.name == name))

  defp property(schema, name) do
    schema |> rule(:properties) |> Map.fetch!(:params) |> List.keyfind(name, 0) |> elem(1)
  end

  defp chain(depth) do
    Enum.reduce(depth..1//-1, %{"type" => "integer"}, fn index, child ->
      %{
        "$id" => "https://example.test/depth/#{index}",
        "properties" => %{"child" => child}
      }
    end)
  end

  defp compile_reductions(raw) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)
    result = JSONSchex.compile(raw)
    {:reductions, after_compile} = Process.info(self(), :reductions)
    assert {:ok, %Schema{}} = result
    after_compile - before
  end
end

defmodule JSONSchex.Test.BundlePerformanceRegression do
  use ExUnit.Case, async: true

  test "structural depth scales approximately linearly in reductions" do
    small = chain(100)
    large = chain(400)

    # Warm module loading before measuring process-local work, not wall-clock time.
    assert {:ok, _} = JSONSchex.bundle_fragment(small, entry: "#")
    small_work = bundle_reductions(small)
    large_work = bundle_reductions(large)

    assert large_work < small_work * 6,
           "quadrupling depth used #{large_work} vs #{small_work} reductions"
  end

  test "structural children retain inactive metadata across nested relative ids" do
    schema = %{
      "$id" => "/api/root.json",
      "properties" => %{
        "child" => %{
          "$id" => "nested/child.json",
          "$ref" => "value.json#value",
          "$defs" => %{
            "Value" => %{"$id" => "value.json", "$anchor" => "value", "type" => "integer"},
            "Unused" => %{"$ref" => "missing.json"}
          }
        }
      }
    }

    assert {:ok, bundle} = JSONSchex.bundle_fragment(schema, entry: "#")
    assert {:ok, compiled} = JSONSchex.compile(bundle)
    assert :ok == JSONSchex.validate(compiled, %{"child" => 1})
    assert {:error, _} = JSONSchex.validate(compiled, %{"child" => "1"})
  end

  test "new arbitrary pointer targets index descendants before following their refs" do
    document = %{
      "schema" => %{"$ref" => "#/x-target"},
      "x-target" => %{
        "$id" => "nested/target.json",
        "properties" => %{
          "value" => %{"$ref" => "hidden.json#value"}
        },
        "$defs" => %{
          "Hidden" => %{"$id" => "hidden.json", "$anchor" => "value", "$ref" => "leaf.json"},
          "Unused" => %{"$ref" => "missing.json"}
        }
      }
    }

    parent = self()
    loader = fn uri ->
      send(parent, {:loaded, uri})
      case uri do
        "/api/nested/leaf.json" -> {:ok, %{"type" => "integer"}}
        _ -> {:error, :unexpected_load}
      end
    end

    assert {:ok, bundle} = JSONSchex.bundle_fragment(document,
      entry: "#/schema", base_uri: "/api/document.json", loader: loader)
    assert_received {:loaded, "/api/nested/leaf.json"}
    refute_received {:loaded, _}
    assert Enum.any?(bundle["$defs"], fn {_key, value} ->
      value["$id"] == "/api/nested/leaf.json" and value["type"] == "integer"
    end)
  end

  test "entry resource metadata supplies a dynamic override to structural descendants" do
    parent = self()
    document = %{
      "container" => %{
        "$id" => "nested/container.json",
        "$defs" => %{
          "Override" => %{"$dynamicAnchor" => "node", "$ref" => "value.json"}
        },
        "schema" => %{
          "properties" => %{"child" => %{"$dynamicRef" => "static.json#node"}}
        }
      }
    }

    loader = fn uri ->
      send(parent, {:loaded, uri})
      case uri do
        "/api/nested/static.json" ->
          {:ok, %{"$dynamicAnchor" => "node", "$ref" => "missing.json"}}
        "/api/nested/value.json" ->
          {:ok, %{"type" => "integer"}}
        _ ->
          {:error, :unexpected_load}
      end
    end

    assert {:ok, bundle} = JSONSchex.bundle_fragment(document,
      entry: "#/container/schema", base_uri: "/api/document.json", loader: loader)
    assert bundle["$id"] == "/api/nested/container.json"
    assert_received {:loaded, "/api/nested/static.json"}
    assert_received {:loaded, "/api/nested/value.json"}
    refute_received {:loaded, _}
    assert {:ok, compiled} = JSONSchex.compile(bundle)
    assert :ok == JSONSchex.validate(compiled, %{"child" => 1})
    assert {:error, _} = JSONSchex.validate(compiled, %{"child" => "1"})
  end

  test "repeated fallback names scale approximately linearly in reductions" do
    small = fallback_document(500)
    large = fallback_document(2000)
    assert {:ok, _} = JSONSchex.bundle_fragment(small, entry: "#")
    small_work = bundle_reductions(small)
    large_work = bundle_reductions(large)
    assert large_work < small_work * 6,
           "quadrupling candidates used #{large_work} vs #{small_work} reductions"
  end

  test "fallback ambiguity counts distinct paths, not keywords or equal values" do
    candidate = %{"$anchor" => "same", "$dynamicAnchor" => "same", "type" => "integer"}
    document = %{
      "schema" => %{"$ref" => "#same"},
      "x-list" => [candidate, candidate],
      "x-map" => %{"0" => candidate}
    }
    assert {:error, error} = JSONSchex.bundle_fragment(document,
      entry: "#/schema", base_uri: "/api/root.json")
    assert error.context.contrast == "ambiguous_anchor"
    assert error.context.input == "/api/root.json#same"
    assert error.context.error_detail == {:candidate_count, 3}
  end

  test "a single dual-keyword fallback candidate resolves and authoritative anchors win" do
    candidate = %{"$anchor" => "same", "$dynamicAnchor" => "same", "type" => "integer"}
    document = %{"schema" => %{"$ref" => "#same"}, "x-list" => [candidate]}
    assert {:ok, bundle} = JSONSchex.bundle_fragment(document,
      entry: "#/schema", base_uri: "/api/root.json")
    assert {:ok, compiled} = JSONSchex.compile(bundle)
    assert :ok == JSONSchex.validate(compiled, 1)
    assert {:error, _} = JSONSchex.validate(compiled, "1")

    schema = %{"$ref" => "#same", "$defs" => %{"Value" => candidate}}
    document = %{document | "schema" => schema, "x-list" => [candidate, candidate]}
    assert {:ok, _} = JSONSchex.bundle_fragment(document,
      entry: "#/schema", base_uri: "/api/root.json")
  end

  test "identity aliases avoid deep rewrite work while redirects still traverse" do
    payload = List.duplicate(%{"nested" => [%{"$ref" => "/api/value.json#value"}]}, 1000)
    document = %{"$ref" => "/api/value.json", "x-payload" => payload}
    run = fn base ->
      loader = fn "/api/value.json" ->
        {:ok, %{document: %{"type" => "integer", "x-payload" => payload}, base_uri: base}}
      end
      fn -> JSONSchex.bundle_fragment(document,
        entry: "#", base_uri: "/api/root.json", loader: loader) end
    end
    identity = run.("/api/value.json")
    redirected = run.("/mirror/value.json")
    assert {:ok, _} = identity.()
    assert {:ok, _} = redirected.()
    identity_work = reductions(identity)
    redirected_work = reductions(redirected)
    assert identity_work * 2 < redirected_work,
           "identity used #{identity_work} vs redirected #{redirected_work} reductions"
  end

  test "identity and mixed aliases preserve resolution and deeply rewrite only redirects" do
    parent = self()
    payload = %{
      "$id" => "/api/nested/scope.json",
      "values" => [%{
        "$ref" => "../value.json#value",
        "$dynamicRef" => "../value.json#node",
        "stable" => %{"$ref" => "../stable.json"},
        "unknown" => %{"$ref" => "../missing.json"}
      }]
    }

    for mode <- [:identity, :redirected] do
      canonical = if mode == :identity, do: "/api/value.json", else: "/mirror/value.json"
      external = %{"type" => "integer", "x-payload" => payload}
      anchor = %{"$anchor" => "selected", "type" => "integer", "x-payload" => payload}
      document = %{
        "schema" => %{"allOf" => [
          %{"$ref" => "/api/value.json"},
          %{"$ref" => canonical},
          %{"$ref" => "/api/stable.json"},
          %{"$ref" => "#selected"}
        ]},
        "x-payload" => payload,
        "x-anchor" => anchor
      }
      loader = fn uri ->
        send(parent, {:loaded, uri})
        case uri do
          "/api/value.json" -> {:ok, %{document: external, base_uri: canonical}}
          "/api/stable.json" -> {:ok, %{"type" => "integer"}}
          _ -> {:error, :unexpected_load}
        end
      end
      assert {:ok, bundle} = JSONSchex.bundle_fragment(document,
        entry: "#/schema", base_uri: "/api/root.json", loader: loader)
      assert_received {:loaded, "/api/value.json"}
      assert_received {:loaded, "/api/stable.json"}
      refute_received {:loaded, _}
      assert hd(bundle["allOf"])["$ref"] == canonical

      expected = if mode == :identity do
        payload
      else
        put_in(payload, ["values"], [%{
          "$ref" => "/mirror/value.json#value",
          "$dynamicRef" => "/mirror/value.json#node",
          "stable" => %{"$ref" => "../stable.json"},
          "unknown" => %{"$ref" => "../missing.json"}
        }])
      end
      assert bundle["x-payload"] == expected
      assert bundle["x-anchor"]["x-payload"] == expected
      mounted = Enum.find_value(bundle["$defs"], fn {_key, value} ->
        if value["$id"] == canonical, do: value
      end)
      assert mounted["x-payload"] == expected
      reachable = Enum.find_value(bundle["$defs"], fn {key, value} ->
        if String.starts_with?(key, "jsonschex_anchor_"), do: value
      end)
      assert reachable["x-payload"] == expected
      assert {:ok, compiled} = JSONSchex.compile(bundle)
      assert :ok == JSONSchex.validate(compiled, 1)
      assert {:error, _} = JSONSchex.validate(compiled, "1")
    end
  end

  defp reductions(fun) do
    {:reductions, before_count} = Process.info(self(), :reductions)
    {:ok, _} = fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    after_count - before_count
  end

  defp fallback_document(count) do
    %{"x-candidates" => List.duplicate(%{"$anchor" => "same"}, count)}
  end

  defp chain(depth) do
    Enum.reduce(1..depth, %{"type" => "integer"}, fn _, child ->
      %{"properties" => %{"child" => child}}
    end)
  end

  defp bundle_reductions(schema) do
    {:reductions, before_count} = Process.info(self(), :reductions)
    {:ok, _} = JSONSchex.bundle_fragment(schema, entry: "#")
    {:reductions, after_count} = Process.info(self(), :reductions)
    after_count - before_count
  end
end

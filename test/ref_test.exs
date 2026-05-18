defmodule JSONSchex.Test.Ref do
  use ExUnit.Case, async: true

  doctest JSONSchex.Ref

  alias JSONSchex.Ref
  alias JSONSchex.Ref.{Cycle, Error, Location, Resolution}

  describe "scan/2" do
    test "discovers structural refs and tracks nested base URIs" do
      document = %{
        "components" => %{
          "schemas" => %{
            "Base" => %{"type" => "string"},
            "Wrapper" => %{"$ref" => "#/components/schemas/Base"}
          }
        },
        "paths" => [
          %{
            "$id" => "schemas/user.json",
            "response" => %{"$ref" => "./common.json#/$defs/error"}
          }
        ]
      }

      occurrences = Ref.scan(document, source: "https://example.com/root.json")

      assert Enum.map(occurrences, & &1.path) == [
               ["components", "schemas", "Wrapper", "$ref"],
               ["paths", 0, "response", "$ref"]
             ]

      [wrapper_ref, response_ref] = occurrences

      assert wrapper_ref.source == "https://example.com/root.json"
      assert wrapper_ref.base_uri == "https://example.com/root.json"
      assert wrapper_ref.absolute_uri == "https://example.com/root.json#/components/schemas/Base"
      assert JSONSchex.URIUtil.fragment(wrapper_ref.absolute_uri) == "/components/schemas/Base"

      assert response_ref.base_uri == "https://example.com/schemas/user.json"
      assert response_ref.absolute_uri == "https://example.com/schemas/common.json#/$defs/error"
      assert JSONSchex.URIUtil.fragment(response_ref.absolute_uri) == "/$defs/error"
    end
  end

  describe "public helpers" do
    test "classifies local and external refs" do
      assert Ref.local_ref?("#/$defs/name")
      refute Ref.local_ref?("schemas/common.json#/$defs/name")

      refute Ref.external_ref?("#/$defs/name")
      assert Ref.external_ref?("schemas/common.json#/$defs/name")
    end

    test "returns node paths, location keys, resource URIs, and indexed walk events" do
      location = %Location{
        raw_ref: "schemas/common.json#/$defs/id",
        path: ["components", "User", "$ref"],
        source: "specs/root.json",
        base_uri: "specs/root.json",
        absolute_uri: "specs/schemas/common.json#/$defs/id"
      }

      resolution = %Resolution{
        location: location,
        target_source: "specs/schemas/common.json",
        target_document: %{"$defs" => %{"id" => %{"type" => "integer"}}},
        target_value: %{"type" => "integer"},
        target_pointer: "#/$defs/id"
      }

      error = %Error{kind: :missing_target, location: location}

      cycle = %Cycle{
        location: location,
        trail: [location.absolute_uri]
      }

      key =
        {"specs/root.json", "specs/root.json", ["components", "User", "$ref"],
         "specs/schemas/common.json#/$defs/id"}

      assert Location.node_path(location) == ["components", "User"]
      assert Ref.location_key(location) == key

      assert Ref.resource_uri(location) == "specs/root.json"
      assert Ref.resource_uri(resolution) == "specs/schemas/common.json"
      assert Ref.resource_uri(error) == "specs/schemas/common.json"
      assert Ref.resource_uri(cycle) == "specs/schemas/common.json"

      assert %{resolutions: resolutions, errors: errors, cycles: cycles} =
               Ref.index_walk_events([resolution, error, cycle])

      assert resolutions[key] == resolution
      assert errors[key] == error
      assert cycles[key] == cycle
    end

    test "renders refs in original, absolute, and prefer_local modes" do
      same_resource_location = %Location{
        raw_ref: "#/$defs/name",
        path: ["schema", "$ref"],
        source: "https://example.com/root.json",
        base_uri: "https://example.com/root.json",
        absolute_uri: "https://example.com/root.json#/$defs/name"
      }

      same_resource_resolution = %Resolution{
        location: same_resource_location,
        target_source: "https://example.com/root.json",
        target_document: %{"$defs" => %{"name" => %{"type" => "string"}}},
        target_value: %{"type" => "string"},
        target_pointer: "#/$defs/name"
      }

      anchor_location = %{
        same_resource_location
        | raw_ref: "#name",
          absolute_uri: "https://example.com/root.json#name"
      }

      anchor_resolution = %Resolution{
        same_resource_resolution
        | location: anchor_location,
          target_pointer: "#/$defs/name"
      }

      cross_resource_location = %Location{
        raw_ref: "schemas/common.json#/$defs/id",
        path: ["schema", "$ref"],
        source: "specs/root.json",
        base_uri: "specs/root.json",
        absolute_uri: "specs/schemas/common.json#/$defs/id"
      }

      cross_resource_resolution = %Resolution{
        location: cross_resource_location,
        target_source: "specs/schemas/common.json",
        target_document: %{"$defs" => %{"id" => %{"type" => "integer"}}},
        target_value: %{"type" => "integer"},
        target_pointer: "#/$defs/id"
      }

      root_location = %{
        same_resource_location
        | raw_ref: "#",
          absolute_uri: "https://example.com/root.json"
      }

      root_resolution = %Resolution{
        same_resource_resolution
        | location: root_location,
          target_pointer: nil,
          target_value: %{},
          target_document: %{}
      }

      assert Ref.render_ref(same_resource_location, same_resource_resolution, mode: :original) ==
               "#/$defs/name"

      assert Ref.render_ref(same_resource_location, same_resource_resolution, mode: :absolute) ==
               "https://example.com/root.json#/$defs/name"

      assert Ref.render_ref(same_resource_location, same_resource_resolution) == "#/$defs/name"
      assert Ref.render_ref(anchor_location, anchor_resolution) == "#name"

      assert Ref.render_ref(cross_resource_location, cross_resource_resolution) ==
               "schemas/common.json#/$defs/id"

      assert Ref.render_ref(root_location, root_resolution) == "#"
    end
  end

  describe "transform/3" do
    test "expands resolved refs in post-order" do
      document = %{
        "start" => %{"$ref" => "schemas/common.json#/schema"}
      }

      parent = self()

      loader = fn
        "specs/schemas/common.json" ->
          {:ok,
           %{
             "$defs" => %{
               "name" => %{"type" => "string"}
             },
             "schema" => %{"$ref" => "#/$defs/name"}
           }}

        _ ->
          {:error, :enoent}
      end

      callback = fn location, outcome ->
        case outcome do
          {:ok, %Resolution{} = resolution} ->
            send(parent, {:ok_location, location.absolute_uri})
            {:replace, resolution.target_value}

          {:cycle, _resolution, _cycle} ->
            :keep

          {:error, error} ->
            {:error, error}
        end
      end

      assert {:ok, transformed} =
               Ref.transform(document, callback,
                 source: "specs/root.json",
                 loader: loader
               )

      assert transformed == %{"start" => %{"type" => "string"}}
      assert_received {:ok_location, "specs/schemas/common.json#/$defs/name"}
      assert_received {:ok_location, "specs/schemas/common.json#/schema"}
    end

    test "keeps unresolved input refs relative when source is omitted" do
      document = %{
        "start" => %{"$ref" => "schemas/common.json#/schema"}
      }

      parent = self()

      loader = fn
        "schemas/common.json" ->
          send(parent, {:loaded, "schemas/common.json"})

          {:ok,
           %{
             "$defs" => %{
               "name" => %{"type" => "string"}
             },
             "schema" => %{"$ref" => "#/$defs/name"}
           }}

        _ ->
          {:error, :enoent}
      end

      callback = fn location, outcome ->
        case outcome do
          {:ok, %Resolution{} = resolution} ->
            send(
              parent,
              {:ok_location, location.path, location.source, location.base_uri, location.absolute_uri}
            )

            {:replace, resolution.target_value}

          {:cycle, _resolution, _cycle} ->
            :keep

          {:error, error} ->
            {:error, error}
        end
      end

      assert {:ok, transformed} = Ref.transform(document, callback, loader: loader)

      assert transformed == %{"start" => %{"type" => "string"}}
      assert_received {:loaded, "schemas/common.json"}

      assert_received {:ok_location, ["start", "$ref"], nil, nil,
                       "schemas/common.json#/schema"}

      assert_received {:ok_location, ["schema", "$ref"], "schemas/common.json",
                       "schemas/common.json", "schemas/common.json#/$defs/name"}
    end

    test "prefers explicit base_uri over source for input document refs" do
      document = %{
        "start" => %{"$ref" => "schemas/common.json#/schema"}
      }

      parent = self()

      loader = fn
        "fixtures/schemas/common.json" ->
          send(parent, {:loaded, "fixtures/schemas/common.json"})

          {:ok,
           %{
             "$defs" => %{
               "name" => %{"type" => "string"}
             },
             "schema" => %{"$ref" => "#/$defs/name"}
           }}

        _ ->
          {:error, :enoent}
      end

      callback = fn location, outcome ->
        case outcome do
          {:ok, %Resolution{} = resolution} ->
            send(
              parent,
              {:ok_location, location.path, location.source, location.base_uri, location.absolute_uri}
            )

            {:replace, resolution.target_value}

          {:cycle, _resolution, _cycle} ->
            :keep

          {:error, error} ->
            {:error, error}
        end
      end

      assert {:ok, transformed} =
               Ref.transform(document, callback,
                 source: "specs/root.json",
                 base_uri: "fixtures/root.json",
                 loader: loader
               )

      assert transformed == %{"start" => %{"type" => "string"}}
      assert_received {:loaded, "fixtures/schemas/common.json"}

      assert_received {:ok_location, ["start", "$ref"], "specs/root.json", "fixtures/root.json",
                       "fixtures/schemas/common.json#/schema"}

      assert_received {:ok_location, ["schema", "$ref"], "fixtures/schemas/common.json",
                       "fixtures/schemas/common.json",
                       "fixtures/schemas/common.json#/$defs/name"}
    end

    test "preserves cycle edges when callback keeps cycle outcomes" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "node" => %{
            "type" => "object",
            "properties" => %{
              "next" => %{"$ref" => "#/$defs/node"}
            }
          }
        },
        "start" => %{"$ref" => "#/$defs/node"}
      }

      parent = self()

      callback = fn _location, outcome ->
        case outcome do
          {:ok, %Resolution{} = resolution} ->
            {:replace, resolution.target_value}

          {:cycle, %Resolution{} = resolution, %Cycle{} = cycle} ->
            send(parent, {:cycle, resolution.location.absolute_uri, cycle.trail})
            :keep

          {:error, error} ->
            {:error, error}
        end
      end

      assert {:ok, transformed} =
               Ref.transform(document, callback, base_uri: "https://example.com/root.json")

      assert transformed["start"]["type"] == "object"
      assert transformed["start"]["properties"]["next"] == %{"$ref" => "#/$defs/node"}

      assert_received {:cycle, "https://example.com/root.json#/$defs/node",
                       [
                         "https://example.com/root.json#/$defs/node",
                         "https://example.com/root.json#/$defs/node"
                       ]}
    end

    test "reuses cached transformed external targets across multiple locations" do
      document = %{
        "first" => %{"$ref" => "schemas/common.json#/$defs/node"},
        "second" => %{"$ref" => "schemas/common.json#/$defs/node"}
      }

      parent = self()

      loader = fn
        "specs/schemas/common.json" ->
          send(parent, {:loaded, "specs/schemas/common.json"})

          {:ok,
           %{
             "$defs" => %{
               "node" => %{"$ref" => "#/terminal"}
             },
             "terminal" => %{"type" => "integer"}
           }}

        _ ->
          {:error, :enoent}
      end

      callback = fn _location, outcome ->
        case outcome do
          {:ok, %Resolution{} = resolution} -> {:replace, resolution.target_value}
          {:cycle, _resolution, _cycle} -> :keep
          {:error, error} -> {:error, error}
        end
      end

      assert {:ok, transformed} =
               Ref.transform(document, callback,
                 source: "specs/root.json",
                 loader: loader
               )

      assert transformed == %{
               "first" => %{"type" => "integer"},
               "second" => %{"type" => "integer"}
             }

      assert_received {:loaded, "specs/schemas/common.json"}
      refute_received {:loaded, "specs/schemas/common.json"}
    end
  end

  describe "walk/2" do
    test "walks refs transitively across nested resources in depth-first order" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "entry" => %{
            "$id" => "schemas/entry.json",
            "$ref" => "leaf.json"
          },
          "leaf" => %{
            "$id" => "schemas/leaf.json",
            "$defs" => %{
              "name" => %{"type" => "string"}
            },
            "schema" => %{"$ref" => "#/$defs/name"}
          }
        },
        "start" => %{"$ref" => "#/$defs/entry"}
      }

      assert {:ok, events} =
               Ref.walk(document,
                 source: "specs/root.json",
                 base_uri: "https://example.com/root.json"
               )

      resolutions = Enum.filter(events, &match?(%Resolution{}, &1))

      assert Enum.map(resolutions, & &1.location.absolute_uri) == [
               "https://example.com/schemas/leaf.json",
               "https://example.com/schemas/leaf.json#/$defs/name",
               "https://example.com/root.json#/$defs/entry"
             ]

      assert Enum.all?(events, &(not match?(%Cycle{}, &1)))
      assert Enum.all?(events, &(not match?(%Error{}, &1)))
    end

    test "caches external documents while still emitting each resolution event" do
      document = %{
        "first" => %{"$ref" => "schemas/common.json#/$defs/node"},
        "second" => %{"$ref" => "schemas/common.json#/$defs/node"}
      }

      parent = self()

      loader = fn uri ->
        send(parent, {:loaded, uri})

        case uri do
          "specs/schemas/common.json" ->
            {:ok,
             %{
               document: %{
                 "$defs" => %{
                   "node" => %{"$ref" => "#/terminal"}
                 },
                 "terminal" => %{"type" => "string"}
               },
               source: uri
             }}

          _ ->
            {:error, :enoent}
        end
      end

      assert {:ok, events} =
               Ref.walk(document,
                 source: "specs/root.json",
                 loader: loader
               )

      resolutions = Enum.filter(events, &match?(%Resolution{}, &1))

      assert Enum.map(resolutions, & &1.location.absolute_uri) == [
               "specs/schemas/common.json#/$defs/node",
               "specs/schemas/common.json#/terminal",
               "specs/schemas/common.json#/$defs/node"
             ]

      assert_received {:loaded, "specs/schemas/common.json"}
      refute_received {:loaded, "specs/schemas/common.json"}
    end

    test "detects cycles without infinite recursion" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "a" => %{"$ref" => "#/$defs/b"},
          "b" => %{"$ref" => "#/$defs/a"}
        },
        "start" => %{"$ref" => "#/$defs/a"}
      }

      assert {:ok, events} =
               Ref.walk(document,
                 base_uri: "https://example.com/root.json"
               )

      assert 3 == Enum.count(events, &match?(%Resolution{}, &1))

      [cycle] = Enum.filter(events, &match?(%Cycle{}, &1))
      assert cycle.location.absolute_uri == "https://example.com/root.json#/$defs/b"

      assert cycle.trail == [
               "https://example.com/root.json#/$defs/b",
               "https://example.com/root.json#/$defs/a",
               "https://example.com/root.json#/$defs/b"
             ]
    end

    test "returns mixed resolution and error events" do
      document = %{
        "$defs" => %{
          "ok" => %{"type" => "string"}
        },
        "bad" => %{"$ref" => "#/$defs/missing"},
        "good" => %{"$ref" => "#/$defs/ok"}
      }

      assert {:ok, events} = Ref.walk(document)

      assert 1 == Enum.count(events, &match?(%Resolution{}, &1))
      assert 1 == Enum.count(events, &match?(%Error{}, &1))
    end
  end

  describe "resolve/3" do
    test "resolves local pointers against the current nested resource" do
      document = %{
        "$id" => "https://example.com/root.json",
        "container" => %{
          "$id" => "schemas/user.json",
          "$defs" => %{
            "name" => %{"type" => "string"}
          },
          "schema" => %{"$ref" => "#/$defs/name"}
        }
      }

      [location] =
        Ref.scan(document,
          source: "specs/root.json",
          base_uri: "https://example.com/root.json"
        )

      assert {:ok, resolution} =
               Ref.resolve(document, location,
                 source: "specs/root.json",
                 base_uri: "https://example.com/root.json"
               )

      assert resolution.location.absolute_uri ==
               "https://example.com/schemas/user.json#/$defs/name"

      assert resolution.target_source == "specs/root.json"
      assert resolution.target_pointer == "#/$defs/name"
      assert resolution.target_document == document["container"]
      assert resolution.target_value == %{"type" => "string"}
    end

    test "resolves external relative refs through the loader using path-like sources" do
      document = %{
        "components" => %{
          "User" => %{"$ref" => "schemas/common.json#/$defs/id"}
        }
      }

      [location] = Ref.scan(document, source: "specs/root.json")
      parent = self()

      loader = fn uri ->
        send(parent, {:loaded, uri})

        case uri do
          "specs/schemas/common.json" ->
            {:ok,
             %{
               document: %{
                 "$defs" => %{
                   "id" => %{"type" => "string"}
                 }
               },
               source: uri
             }}

          _ ->
            {:error, :enoent}
        end
      end

      assert {:ok, resolution} =
               Ref.resolve(document, location,
                 source: "specs/root.json",
                 loader: loader
               )

      assert_received {:loaded, "specs/schemas/common.json"}
      assert resolution.location.absolute_uri == "specs/schemas/common.json#/$defs/id"
      assert resolution.target_source == "specs/schemas/common.json"
      assert resolution.target_pointer == "#/$defs/id"
      assert resolution.target_document == %{"$defs" => %{"id" => %{"type" => "string"}}}
      assert resolution.target_value == %{"type" => "string"}
    end

    test "resolves bundled draft resources without a loader" do
      document = %{
        "$ref" => "https://json-schema.org/draft/2020-12/meta/core#/$defs/uriString"
      }

      [location] = Ref.scan(document)

      assert {:ok, resolution} = Ref.resolve(document, location)

      assert resolution.target_source == "https://json-schema.org/draft/2020-12/meta/core"
      assert resolution.target_pointer == "#/$defs/uriString"
      assert resolution.target_value == %{"type" => "string", "format" => "uri"}
      assert is_map(resolution.target_document)
    end

    test "returns structured errors for missing targets" do
      document = %{
        "$defs" => %{},
        "schema" => %{"$ref" => "#/$defs/missing"}
      }

      [location] = Ref.scan(document)

      assert {:error, %Error{} = error} = Ref.resolve(document, location)
      assert error.kind == :missing_target
      assert error.location == location
      assert error.location.absolute_uri == "#/$defs/missing"
    end
  end
end

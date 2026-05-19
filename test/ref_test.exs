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

    test "returns node paths, location keys, target URIs, resource URIs, and indexed walk events" do
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

      assert Ref.target_uri(resolution) == "specs/schemas/common.json#/$defs/id"
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

    test "reconstructs target URIs from target resource context when absolute_uri is absent" do
      resolution = %Resolution{
        location: %Location{raw_ref: "#/schema", path: ["schema", "$ref"]},
        target_source: "https://example.com/root.json",
        target_document: %{},
        target_value: %{},
        target_pointer: "#/$defs/name"
      }

      root_resolution = %{
        resolution
        | target_pointer: nil
      }

      assert Ref.target_uri(resolution) == "https://example.com/root.json#/$defs/name"
      assert Ref.target_uri(root_resolution) == "https://example.com/root.json"
    end

    test "collects reachable external resources keyed by canonical resource URI" do
      document = %{
        "$id" => "specs/root.json",
        "local" => %{
          "$id" => "schemas/local.json",
          "$defs" => %{
            "name" => %{"type" => "string"}
          },
          "schema" => %{"$ref" => "#/$defs/name"}
        },
        "start" => %{"$ref" => "schemas/common.json#/schema"}
      }

      loader = fn
        "specs/schemas/common.json" ->
          {:ok,
           %{
             document: %{
               "$id" => "specs/schemas/common.json",
               "schema" => %{"$ref" => "parts/nested.json#/schema"},
               "parts" => %{
                 "nested" => %{
                   "$id" => "parts/nested.json",
                   "$defs" => %{
                     "name" => %{"type" => "string"}
                   },
                   "schema" => %{"$ref" => "#/$defs/name"}
                 }
               }
             },
             source: "specs/schemas/common.json"
           }}

        _ ->
          {:error, :enoent}
      end

      assert {:ok, resources} =
               Ref.collect_external_resources(document,
                 source: "specs/root.json",
                 loader: loader
               )

      assert Map.keys(resources) |> Enum.sort() == [
               "specs/schemas/common.json",
               "specs/schemas/parts/nested.json"
             ]

      refute Map.has_key?(resources, "specs/root.json")
      refute Map.has_key?(resources, "specs/schemas/local.json")

      assert %{document: common_document, source: "specs/schemas/common.json", resolutions: common_resolutions} =
               resources["specs/schemas/common.json"]

      assert common_document["schema"] == %{"$ref" => "parts/nested.json#/schema"}
      assert Enum.map(common_resolutions, & &1.location.absolute_uri) == ["specs/schemas/common.json#/schema"]

      assert %{document: nested_document, source: "specs/schemas/common.json", resolutions: nested_resolutions} =
               resources["specs/schemas/parts/nested.json"]

      assert nested_document["schema"] == %{"$ref" => "#/$defs/name"}

      assert Enum.map(nested_resolutions, & &1.location.absolute_uri) == [
               "specs/schemas/parts/nested.json#/schema"
             ]
    end

    test "renders refs in original, absolute, prefer_local, and mounted modes" do
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

      mounted_nested_location = %Location{
        raw_ref: "common.json#Pet",
        path: ["schema", "$ref"],
        source: "https://example.com/root.json",
        base_uri: "https://example.com/schemas/nested/user.json",
        absolute_uri: "https://example.com/schemas/common.json#Pet"
      }

      mounted_nested_resolution = %Resolution{
        location: mounted_nested_location,
        target_source: "https://example.com/root.json",
        target_document: %{"$anchor" => "Pet"},
        target_value: %{"$anchor" => "Pet"},
        target_pointer: nil
      }

      mounted_absolute_location = %Location{
        raw_ref: "https://example.com/schemas/common.json#Pet",
        path: ["schema", "$ref"],
        source: "https://cdn.example/user.json",
        base_uri: "https://cdn.example/user.json",
        absolute_uri: "https://example.com/schemas/common.json#Pet"
      }

      mounted_absolute_resolution = %Resolution{
        location: mounted_absolute_location,
        target_source: "https://example.com/root.json",
        target_document: %{"$anchor" => "Pet"},
        target_value: %{"$anchor" => "Pet"},
        target_pointer: nil
      }

      mounted_path_like_location = %Location{
        raw_ref: "common.json#/$defs/id",
        path: ["schema", "$ref"],
        source: "specs/source/root.json",
        base_uri: "specs/source/schemas/nested/user.json",
        absolute_uri: "specs/source/schemas/common.json#/$defs/id"
      }

      mounted_path_like_resolution = %Resolution{
        location: mounted_path_like_location,
        target_source: "specs/source/schemas/common.json",
        target_document: %{"$defs" => %{"id" => %{"type" => "integer"}}},
        target_value: %{"type" => "integer"},
        target_pointer: "#/$defs/id"
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

      assert Ref.render_ref(same_resource_location, same_resource_resolution,
               mode: :mounted,
               mount_base_uri: "https://bundle.example/root.json"
             ) == "#/$defs/name"

      assert Ref.render_ref(anchor_location, anchor_resolution,
               mode: :mounted,
               mount_base_uri: "https://bundle.example/root.json"
             ) == "#name"

      assert Ref.render_ref(root_location, root_resolution,
               mode: :mounted,
               mount_base_uri: "https://bundle.example/root.json"
             ) == "#"



      assert Ref.render_ref(cross_resource_location, cross_resource_resolution,
               mode: :mounted,
               mount_base_uri: "specs/bundle/user.json",
               resource_uri_map: %{
                 "specs/schemas/common.json" => "specs/bundle/common.json",
                 "specs/root.json" => "specs/bundle/user.json"
               }
             ) == "common.json#/$defs/id"

      assert Ref.render_ref(mounted_nested_location, mounted_nested_resolution,
               mode: :mounted,
               mount_base_uri: "https://bundle.example/schemas/nested/user.json",
               resource_uri_map: %{
                 "https://example.com/schemas/common.json" => "https://bundle.example/schemas/common.json"
               }
             ) == "../common.json#Pet"

      assert Ref.render_ref(mounted_absolute_location, mounted_absolute_resolution,
               mode: :mounted,
               mount_base_uri: "https://cdn.example/user.json",
               resource_uri_map: %{
                 "https://example.com/schemas/common.json" => "https://bundle.example/schemas/common.json"
               }
             ) == "https://bundle.example/schemas/common.json#Pet"

      assert Ref.render_ref(mounted_path_like_location, mounted_path_like_resolution,
               mode: :mounted,
               mount_base_uri: "specs/bundle/schemas/nested/user.json",
               resource_uri_map: %{
                 "specs/source/schemas/common.json" => "specs/bundle/schemas/common.json"
               }
             ) == "../common.json#/$defs/id"


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

  describe "bundle/3" do
    test "returns rebased root, collected resources, rebased resources, and walk indexes" do
      document = %{
        "$id" => "specs/root.json",
        "$defs" => %{
          "root_name" => %{"type" => "string"}
        },
        "start" => %{"$ref" => "schemas/common.json#/schema"}
      }

      loader = fn
        "specs/schemas/common.json" ->
          {:ok,
           %{
             document: %{
               "$id" => "specs/schemas/common.json",
               "root_link" => %{"$ref" => "../root.json#/$defs/root_name"},
               "schema" => %{"$ref" => "parts/nested.json#/schema"},
               "parts" => %{
                 "nested" => %{
                   "$id" => "parts/nested.json",
                   "$defs" => %{
                     "name" => %{"type" => "string"}
                   },
                   "schema" => %{"$ref" => "#/$defs/name"}
                 }
               }
             },
             source: "specs/schemas/common.json"
           }}

        _ ->
          {:error, :enoent}
      end

      assert {:ok, bundle} =
               Ref.bundle(document, "specs/bundle/root.json",
                 source: "specs/root.json",
                 loader: loader,
                 resource_uri_map: %{
                   "specs/schemas/common.json" => "specs/bundle/common.json",
                   "specs/schemas/parts/nested.json" => "specs/bundle/parts/nested.json"
                 }
               )

      assert bundle.root_document["$id"] == "specs/bundle/root.json"
      assert bundle.root_document["start"]["$ref"] == "common.json#/schema"

      assert Map.keys(bundle.resources_by_uri) |> Enum.sort() == [
               "specs/schemas/common.json",
               "specs/schemas/parts/nested.json"
             ]

      assert bundle.rebased_resources_by_uri["specs/schemas/common.json"]["$id"] ==
               "specs/bundle/common.json"

      assert bundle.rebased_resources_by_uri["specs/schemas/common.json"]["schema"] ==
               %{"$ref" => "parts/nested.json#/schema"}

      assert bundle.rebased_resources_by_uri["specs/schemas/common.json"]["root_link"] ==
               %{"$ref" => "root.json#/$defs/root_name"}

      assert bundle.rebased_resources_by_uri["specs/schemas/parts/nested.json"]["$id"] ==
               "specs/bundle/parts/nested.json"

      assert bundle.rebased_resources_by_uri["specs/schemas/parts/nested.json"]["schema"] ==
               %{"$ref" => "#/$defs/name"}

      assert bundle.resource_uri_map["specs/root.json"] == "specs/bundle/root.json"
      assert bundle.resource_uri_map["specs/schemas/common.json"] == "specs/bundle/common.json"
      assert bundle.resource_uri_map["specs/schemas/parts/nested.json"] ==
               "specs/bundle/parts/nested.json"

      assert is_list(bundle.walk_events)
      assert bundle.walk_index.resolutions != %{}
      assert bundle.location_index == bundle.walk_index

      assert %{document: common_document, rebased_document: rebased_common_document, source: "specs/schemas/common.json", resolutions: common_resolutions, rebased_resource_uri: "specs/bundle/common.json"} =
               bundle.resource_index["specs/schemas/common.json"]

      assert common_document == bundle.resources_by_uri["specs/schemas/common.json"].document
      assert rebased_common_document == bundle.rebased_resources_by_uri["specs/schemas/common.json"]
      assert Enum.map(common_resolutions, & &1.location.absolute_uri) == ["specs/schemas/common.json#/schema"]

      assert %{rebased_resource_uri: "specs/bundle/parts/nested.json"} =
               bundle.resource_index["specs/schemas/parts/nested.json"]

      start_key =
        {"specs/root.json", "specs/root.json", ["start", "$ref"],
         "specs/schemas/common.json#/schema"}

      assert %Resolution{} = bundle.walk_index.resolutions[start_key]
    end

    test "preserves resource resolution order and returns walk errors alongside bundle state" do
      document = %{
        "$id" => "specs/root.json",
        "first" => %{"$ref" => "schemas/common.json#/schema"},
        "second" => %{"$ref" => "schemas/common.json#/schema"},
        "missing" => %{"$ref" => "schemas/missing.json#/schema"}
      }

      loader = fn
        "specs/schemas/common.json" ->
          {:ok,
           %{
             document: %{
               "$id" => "specs/schemas/common.json",
               "schema" => %{"type" => "string"}
             },
             source: "specs/schemas/common.json"
           }}

        _ ->
          {:error, :enoent}
      end

      assert {:ok, bundle} =
               Ref.bundle(document, "specs/bundle/root.json",
                 source: "specs/root.json",
                 loader: loader,
                 resource_uri_map: %{
                   "specs/schemas/common.json" => "specs/bundle/common.json"
                 }
               )

      assert Enum.any?(bundle.walk_events, &match?(%Error{kind: :missing_document}, &1))

      assert Enum.map(bundle.resources_by_uri["specs/schemas/common.json"].resolutions, & &1.location.path) == [
               ["first", "$ref"],
               ["second", "$ref"]
             ]

      assert Enum.map(bundle.resource_index["specs/schemas/common.json"].resolutions, & &1.location.path) == [
               ["first", "$ref"],
               ["second", "$ref"]
             ]

      refute Map.has_key?(bundle.resources_by_uri, "specs/schemas/missing.json")
      refute Map.has_key?(bundle.resource_index, "specs/schemas/missing.json")
    end
  end

  describe "rebase/3" do
    test "injects a new root $id and preserves same-resource local refs" do
      document = %{
        "$defs" => %{
          "name" => %{"type" => "string"}
        },
        "schema" => %{"$ref" => "#/$defs/name"}
      }

      assert {:ok, rebased} =
               Ref.rebase(document, "https://bundle.example/schemas/user.json",
                 base_uri: "https://example.com/schemas/user.json"
               )

      assert rebased["$id"] == "https://bundle.example/schemas/user.json"
      assert rebased["schema"]["$ref"] == "#/$defs/name"

      [location] = Ref.scan(rebased, base_uri: "https://bundle.example/schemas/user.json")
      assert {:ok, resolution} =
               Ref.resolve(rebased, location,
                 base_uri: "https://bundle.example/schemas/user.json"
               )

      assert resolution.target_value == %{"type" => "string"}
    end

    test "rewrites relative external refs against the new base when preserving original targets" do
      document = %{
        "schema" => %{"$ref" => "common.json#/$defs/id"}
      }

      assert {:ok, rebased} =
               Ref.rebase(document, "specs/bundle/user.json",
                 base_uri: "specs/source/user.json"
               )

      assert rebased["$id"] == "specs/bundle/user.json"
      assert rebased["schema"]["$ref"] == "../source/common.json#/$defs/id"
    end

    test "rebases nested relative $id resources under the new root" do
      document = %{
        "$id" => "https://example.com/root.json",
        "child" => %{
          "$id" => "schemas/user.json",
          "$defs" => %{
            "name" => %{"type" => "string"}
          },
          "schema" => %{"$ref" => "#/$defs/name"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["child"]["$id"] == "schemas/user.json"
      assert rebased["child"]["schema"]["$ref"] == "#/$defs/name"

      [location] = Ref.scan(rebased, base_uri: "https://bundle.example/root.json")

      assert {:ok, resolution} =
               Ref.resolve(rebased, location, base_uri: "https://bundle.example/root.json")

      assert resolution.location.base_uri == "https://bundle.example/schemas/user.json"
      assert resolution.target_document == rebased["child"]
      assert resolution.target_value == %{"type" => "string"}
    end

    test "preserves same-resource root refs when rebasing" do
      document = %{
        "self" => %{"$ref" => "#"}
      }

      assert {:ok, rebased} =
               Ref.rebase(document, "https://bundle.example/root.json",
                 base_uri: "https://example.com/root.json"
               )

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["self"]["$ref"] == "#"
    end

    test "preserves same-resource anchor refs when rebasing" do
      document = %{
        "$anchor" => "Pet",
        "self" => %{"$ref" => "#Pet"}
      }

      assert {:ok, rebased} =
               Ref.rebase(document, "https://bundle.example/root.json",
                 base_uri: "https://example.com/root.json"
               )

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["$anchor"] == "Pet"
      assert rebased["self"]["$ref"] == "#Pet"
    end

    test "rewrites internal cross-resource refs to rebased sibling resources" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "user" => %{
            "$id" => "schemas/user.json",
            "$defs" => %{
              "name" => %{"type" => "string"}
            }
          }
        },
        "schema" => %{"$ref" => "https://example.com/schemas/user.json#/$defs/name"}
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["$defs"]["user"]["$id"] == "schemas/user.json"
      assert rebased["schema"]["$ref"] == "schemas/user.json#/$defs/name"
    end

    test "rewrites nested child refs that point back to the rebased root resource" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "name" => %{"type" => "string"}
        },
        "child" => %{
          "$id" => "schemas/user.json",
          "schema" => %{"$ref" => "https://example.com/root.json#/$defs/name"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["child"]["$id"] == "schemas/user.json"
      assert rebased["child"]["schema"]["$ref"] == "../root.json#/$defs/name"
    end

    test "rewrites path-like nested child refs that point back to the rebased root resource" do
      document = %{
        "$id" => "specs/source/root.json",
        "$defs" => %{
          "name" => %{"type" => "string"}
        },
        "child" => %{
          "$id" => "schemas/user.json",
          "schema" => %{"$ref" => "specs/source/root.json#/$defs/name"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "specs/bundle/root.json")

      assert rebased["$id"] == "specs/bundle/root.json"
      assert rebased["child"]["$id"] == "schemas/user.json"
      assert rebased["child"]["schema"]["$ref"] == "../root.json#/$defs/name"
    end

    test "preserves absolute nested resource identities while rebasing the root" do
      document = %{
        "$id" => "https://example.com/root.json",
        "child" => %{
          "$id" => "https://cdn.example/user.json",
          "$anchor" => "Pet",
          "schema" => %{"$ref" => "#Pet"}
        },
        "link" => %{"$ref" => "https://cdn.example/user.json#Pet"}
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["child"]["$id"] == "https://cdn.example/user.json"
      assert rebased["child"]["schema"]["$ref"] == "#Pet"
      assert rebased["link"]["$ref"] == "https://cdn.example/user.json#Pet"
    end

    test "rewrites nested sibling resource refs with anchors under the rebased root" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "common" => %{
            "$id" => "schemas/common.json",
            "$anchor" => "Pet"
          },
          "user" => %{
            "$id" => "schemas/user.json",
            "schema" => %{"$ref" => "common.json#Pet"}
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["$defs"]["common"]["$id"] == "schemas/common.json"
      assert rebased["$defs"]["user"]["$id"] == "schemas/user.json"
      assert rebased["$defs"]["user"]["schema"]["$ref"] == "common.json#Pet"
    end

    test "preserves recursive local-file child resources after rebasing" do
      document = %{
        "$id" => "specs/source/root.json",
        "$defs" => %{
          "node_resource" => %{
            "$id" => "schemas/node.json",
            "$defs" => %{
              "node" => %{
                "type" => "object",
                "properties" => %{
                  "next" => %{"$ref" => "#/$defs/node"}
                }
              }
            },
            "schema" => %{"$ref" => "#/$defs/node"}
          }
        },
        "schema" => %{"$ref" => "schemas/node.json#/schema"}
      }

      assert {:ok, rebased} = Ref.rebase(document, "specs/bundle/root.json")

      assert rebased["$id"] == "specs/bundle/root.json"
      assert rebased["$defs"]["node_resource"]["$id"] == "schemas/node.json"
      assert rebased["$defs"]["node_resource"]["schema"]["$ref"] == "#/$defs/node"
      assert rebased["$defs"]["node_resource"]["$defs"]["node"]["properties"]["next"]["$ref"] ==
               "#/$defs/node"
      assert rebased["schema"]["$ref"] == "schemas/node.json#/schema"

      locations = Ref.scan(rebased, base_uri: "specs/bundle/root.json")

      next_location =
        Enum.find(locations, fn location ->
          location.path == ["$defs", "node_resource", "$defs", "node", "properties", "next", "$ref"]
        end)

      schema_location =
        Enum.find(locations, fn location ->
          location.path == ["schema", "$ref"]
        end)

      assert %Location{} = next_location
      assert %Location{} = schema_location
      assert next_location.absolute_uri == "specs/bundle/schemas/node.json#/$defs/node"
      assert schema_location.absolute_uri == "specs/bundle/schemas/node.json#/schema"

      assert {:ok, next_resolution} =
               Ref.resolve(rebased, next_location, base_uri: "specs/bundle/root.json")

      assert next_resolution.target_document == rebased["$defs"]["node_resource"]
      assert next_resolution.target_value["type"] == "object"

      assert {:ok, schema_resolution} =
               Ref.resolve(rebased, schema_location, base_uri: "specs/bundle/root.json")

      assert schema_resolution.target_document == rebased["$defs"]["node_resource"]
      assert schema_resolution.target_value == %{"$ref" => "#/$defs/node"}
    end

    test "preserves nested child same-resource root and anchor refs after rebasing the root" do
      document = %{
        "$id" => "https://example.com/root.json",
        "child" => %{
          "$id" => "schemas/user.json",
          "$anchor" => "Pet",
          "root_ref" => %{"$ref" => "#"},
          "anchor_ref" => %{"$ref" => "#Pet"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["child"]["$id"] == "schemas/user.json"
      assert rebased["child"]["$anchor"] == "Pet"
      assert rebased["child"]["root_ref"]["$ref"] == "#"
      assert rebased["child"]["anchor_ref"]["$ref"] == "#Pet"
    end

    test "rewrites path-like sibling refs between nested resources under the rebased root" do
      document = %{
        "$id" => "specs/source/root.json",
        "$defs" => %{
          "common" => %{
            "$id" => "schemas/common.json",
            "$anchor" => "Pet"
          },
          "user" => %{
            "$id" => "schemas/user.json",
            "schema" => %{"$ref" => "common.json#Pet"}
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "specs/bundle/root.json")

      assert rebased["$id"] == "specs/bundle/root.json"
      assert rebased["$defs"]["common"]["$id"] == "schemas/common.json"
      assert rebased["$defs"]["user"]["$id"] == "schemas/user.json"
      assert rebased["$defs"]["user"]["schema"]["$ref"] == "common.json#Pet"
    end

    test "uses resource_uri_map to retarget path-like external anchor refs to rebased companion resources" do
      document = %{
        "$id" => "specs/source/user.json",
        "schema" => %{"$ref" => "common.json#PetSummary"}
      }

      assert {:ok, rebased} =
               Ref.rebase(document, "specs/bundle/user.json",
                 resource_uri_map: %{
                   "specs/source/common.json" => "specs/bundle/common.json"
                 }
               )

      assert rebased["$id"] == "specs/bundle/user.json"
      assert rebased["schema"]["$ref"] == "common.json#PetSummary"
    end

    test "rebases multi-level relative $id chains and preserves descendant refs" do
      document = %{
        "$id" => "https://example.com/root.json",
        "tree" => %{
          "$id" => "schemas/",
          "user" => %{
            "$id" => "user.json",
            "$defs" => %{
              "name" => %{"type" => "string"}
            },
            "schema" => %{"$ref" => "#/$defs/name"}
          },
          "link" => %{"$ref" => "user.json#/$defs/name"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["tree"]["$id"] == "schemas/"
      assert rebased["tree"]["user"]["$id"] == "user.json"
      assert rebased["tree"]["user"]["schema"]["$ref"] == "#/$defs/name"
      assert rebased["tree"]["link"]["$ref"] == "user.json#/$defs/name"

      locations = Ref.scan(rebased, base_uri: "https://bundle.example/root.json")

      link_location =
        Enum.find(locations, fn location ->
          location.path == ["tree", "link", "$ref"]
        end)

      assert %Location{} = link_location
      assert link_location.absolute_uri == "https://bundle.example/schemas/user.json#/$defs/name"

      assert {:ok, resolution} =
               Ref.resolve(rebased, link_location, base_uri: "https://bundle.example/root.json")

      assert resolution.target_document == rebased["tree"]["user"]
      assert resolution.target_value == %{"type" => "string"}
    end

    test "rewrites anchor refs across rebased parent resource boundaries" do
      document = %{
        "$id" => "https://example.com/root.json",
        "package" => %{
          "$id" => "schemas/",
          "common" => %{
            "$id" => "common.json",
            "$anchor" => "Pet",
            "type" => "string"
          },
          "user" => %{
            "$id" => "user.json",
            "schema" => %{"$ref" => "common.json#Pet"}
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["package"]["$id"] == "schemas/"
      assert rebased["package"]["common"]["$id"] == "common.json"
      assert rebased["package"]["user"]["$id"] == "user.json"
      assert rebased["package"]["user"]["schema"]["$ref"] == "common.json#Pet"

      [location] =
        Ref.scan(rebased, base_uri: "https://bundle.example/root.json")
        |> Enum.filter(fn location -> location.path == ["package", "user", "schema", "$ref"] end)

      assert {:ok, resolution} =
               Ref.resolve(rebased, location, base_uri: "https://bundle.example/root.json")

      assert resolution.target_document == rebased["package"]["common"]
      assert resolution.target_value == rebased["package"]["common"]
    end

    test "preserves mixed absolute and relative nested resource identities" do
      document = %{
        "$id" => "https://example.com/root.json",
        "common" => %{
          "$id" => "schemas/common.json",
          "$anchor" => "Pet"
        },
        "vendor" => %{
          "$id" => "https://cdn.example/vendor.json",
          "$anchor" => "Vendor"
        },
        "user" => %{
          "$id" => "schemas/user.json",
          "common_ref" => %{"$ref" => "common.json#Pet"},
          "vendor_ref" => %{"$ref" => "https://cdn.example/vendor.json#Vendor"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["common"]["$id"] == "schemas/common.json"
      assert rebased["vendor"]["$id"] == "https://cdn.example/vendor.json"
      assert rebased["user"]["$id"] == "schemas/user.json"
      assert rebased["user"]["common_ref"]["$ref"] == "common.json#Pet"
      assert rebased["user"]["vendor_ref"]["$ref"] == "https://cdn.example/vendor.json#Vendor"
    end

    test "rewrites sibling root-resource refs without preserving an empty fragment" do
      document = %{
        "$id" => "https://example.com/root.json",
        "$defs" => %{
          "common" => %{
            "$id" => "schemas/common.json",
            "type" => "object"
          },
          "user" => %{
            "$id" => "schemas/user.json",
            "schema" => %{"$ref" => "common.json"}
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["$defs"]["user"]["schema"]["$ref"] == "common.json"

      [location] =
        Ref.scan(rebased, base_uri: "https://bundle.example/root.json")
        |> Enum.filter(fn location -> location.path == ["$defs", "user", "schema", "$ref"] end)

      assert {:ok, resolution} =
               Ref.resolve(rebased, location, base_uri: "https://bundle.example/root.json")

      assert resolution.target_document == rebased["$defs"]["common"]
      assert resolution.target_value == rebased["$defs"]["common"]
      assert is_nil(resolution.target_pointer)
    end

    test "preserves nested path-like directory refs that use dot segments" do
      document = %{
        "$id" => "specs/source/root.json",
        "package" => %{
          "$id" => "schemas/",
          "common" => %{
            "$id" => "./common.json",
            "$defs" => %{
              "id" => %{"type" => "integer"}
            }
          },
          "user" => %{
            "$id" => "nested/user.json",
            "schema" => %{"$ref" => "../common.json#/$defs/id"}
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "specs/bundle/root.json")

      assert rebased["$id"] == "specs/bundle/root.json"
      assert rebased["package"]["$id"] == "schemas/"
      assert rebased["package"]["common"]["$id"] == "./common.json"
      assert rebased["package"]["user"]["$id"] == "nested/user.json"
      assert rebased["package"]["user"]["schema"]["$ref"] == "../common.json#/$defs/id"

      [location] =
        Ref.scan(rebased, base_uri: "specs/bundle/root.json")
        |> Enum.filter(fn location -> location.path == ["package", "user", "schema", "$ref"] end)

      assert {:ok, resolution} =
               Ref.resolve(rebased, location, base_uri: "specs/bundle/root.json")

      assert resolution.target_document == rebased["package"]["common"]
      assert resolution.target_value == %{"type" => "integer"}
    end

    test "rewrites refs from absolute nested resources to rebased relative resources" do
      document = %{
        "$id" => "https://example.com/root.json",
        "common" => %{
          "$id" => "schemas/common.json",
          "$anchor" => "Pet"
        },
        "vendor_user" => %{
          "$id" => "https://cdn.example/user.json",
          "schema" => %{"$ref" => "https://example.com/schemas/common.json#Pet"}
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["common"]["$id"] == "schemas/common.json"
      assert rebased["vendor_user"]["$id"] == "https://cdn.example/user.json"
      assert rebased["vendor_user"]["schema"]["$ref"] ==
               "https://bundle.example/schemas/common.json#Pet"
    end

    test "rewrites multi-level nested sibling anchor refs through rebased parents" do
      document = %{
        "$id" => "https://example.com/root.json",
        "package" => %{
          "$id" => "schemas/",
          "common" => %{
            "$id" => "common.json",
            "$anchor" => "Pet"
          },
          "nested" => %{
            "$id" => "nested/",
            "user" => %{
              "$id" => "user.json",
              "schema" => %{"$ref" => "../common.json#Pet"}
            }
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "https://bundle.example/root.json")

      assert rebased["$id"] == "https://bundle.example/root.json"
      assert rebased["package"]["nested"]["user"]["schema"]["$ref"] == "../common.json#Pet"

      [location] =
        Ref.scan(rebased, base_uri: "https://bundle.example/root.json")
        |> Enum.filter(fn location ->
          location.path == ["package", "nested", "user", "schema", "$ref"]
        end)

      assert {:ok, resolution} =
               Ref.resolve(rebased, location, base_uri: "https://bundle.example/root.json")

      assert resolution.target_document == rebased["package"]["common"]
      assert resolution.target_value == rebased["package"]["common"]
    end

    test "preserves path-like absolute-path refs across rebasing" do
      document = %{
        "$id" => "specs/source/root.json",
        "schema" => %{"$ref" => "/shared/common.json#Pet"}
      }

      assert {:ok, rebased} = Ref.rebase(document, "specs/bundle/root.json")

      assert rebased["$id"] == "specs/bundle/root.json"
      assert rebased["schema"]["$ref"] == "/shared/common.json#Pet"
    end

    test "rewrites mixed nested path-like sibling refs that use dot segments" do
      document = %{
        "$id" => "specs/source/root.json",
        "package" => %{
          "$id" => "schemas/",
          "common" => %{
            "$id" => "nested/common.json",
            "$defs" => %{
              "id" => %{"type" => "integer"}
            }
          },
          "nested" => %{
            "$id" => "nested/",
            "user" => %{
              "$id" => "user.json",
              "schema" => %{"$ref" => "common.json#/$defs/id"}
            }
          }
        }
      }

      assert {:ok, rebased} = Ref.rebase(document, "specs/bundle/root.json")

      assert rebased["$id"] == "specs/bundle/root.json"
      assert rebased["package"]["common"]["$id"] == "nested/common.json"
      assert rebased["package"]["nested"]["$id"] == "nested/"
      assert rebased["package"]["nested"]["user"]["$id"] == "user.json"
      assert rebased["package"]["nested"]["user"]["schema"]["$ref"] ==
               "../source/common.json#/$defs/id"
    end

    test "uses resource_uri_map to retarget external anchor refs to rebased companion resources" do
      document = %{
        "$id" => "https://example.com/user.json",
        "schema" => %{"$ref" => "common.json#PetSummary"}
      }

      assert {:ok, rebased} =
               Ref.rebase(document, "https://bundle.example/user.json",
                 resource_uri_map: %{
                   "https://example.com/common.json" => "https://bundle.example/common.json"
                 }
               )

      assert rebased["$id"] == "https://bundle.example/user.json"
      assert rebased["schema"]["$ref"] == "common.json#PetSummary"
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

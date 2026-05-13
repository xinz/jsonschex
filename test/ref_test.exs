defmodule JSONSchex.Test.Ref do
  use ExUnit.Case, async: true

  doctest JSONSchex.Ref

  alias JSONSchex.Ref
  alias JSONSchex.Ref.{Cycle, Error, Resolution}

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
      assert wrapper_ref.fragment == "/components/schemas/Base"

      assert response_ref.base_uri == "https://example.com/schemas/user.json"
      assert response_ref.absolute_uri == "https://example.com/schemas/common.json#/$defs/error"
      assert response_ref.fragment == "/$defs/error"
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

      assert Enum.map(resolutions, & &1.target_uri) == [
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

      assert Enum.map(resolutions, & &1.target_uri) == [
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
      assert cycle.target_uri == "https://example.com/root.json#/$defs/b"

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

      assert resolution.target_uri == "https://example.com/schemas/user.json#/$defs/name"
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
      assert resolution.target_uri == "specs/schemas/common.json#/$defs/id"
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
      assert error.target_uri == "#/$defs/missing"
      assert error.location == location
    end
  end
end

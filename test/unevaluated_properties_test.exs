defmodule JSONSchex.Test.UnevaledProperties do
  use ExUnit.Case
  doctest JSONSchex

  # Alias the internal struct for cleaner assertions
  alias JSONSchex.Types.Error

  describe "Part 1: Basic Type Validation" do
    test "validates simple integer types" do
      raw_schema = %{"type" => "integer", "minimum" => 18}
      assert {:ok, compiled} = JSONSchex.compile(raw_schema)

      assert :ok == JSONSchex.validate(compiled, 25)

      assert {:error, errors} = JSONSchex.validate(compiled, 10)
      assert [%Error{rule: :minimum}] = errors

      assert {:error, errors} = JSONSchex.validate(compiled, "not a number")
      assert [%Error{rule: :type}] = errors
    end
  end

  describe "Part 2: Draft 2020-12 UnevaluatedProperties" do
    # This corresponds to the standard behavior where "additionalProperties" (old draft)
    # looked at the schema, but "unevaluatedProperties" looks at the *runtime validation path*.

    setup do
      # Schema:
      # {
      #   "type": "object",
      #   "properties": {
      #     "name": { "type": "string" },
      #     "age":  { "type": "integer" }
      #   },
      #   "unevaluatedProperties": false
      # }
      raw_schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "unevaluatedProperties" => false
      }
      {:ok, compiled} = JSONSchex.compile(raw_schema)
      %{schema: compiled}
    end

    test "allows data when all fields are defined in 'properties'", %{schema: schema} do
      data = %{"name" => "Gem", "age" => 100}
      assert :ok == JSONSchex.validate(schema, data)
    end

    test "allows partial data (properties are optional by default)", %{schema: schema} do
      data = %{"name" => "Gem"}
      assert :ok == JSONSchex.validate(schema, data)
    end

    test "fails when an extra field is present (unevaluated)", %{schema: schema} do
      data = %{"name" => "Gem", "age" => 100, "isAdmin" => true}

      assert {:error, errors} = JSONSchex.validate(schema, data)

      # Verify the error structure contains the path to the extra field
      assert length(errors) == 1
      [error] = errors
      assert error.rule == :unevaluatedProperties
      assert error.path == ["isAdmin"]
    end

    test "fails when an extra field is present (unevaluated: false)", %{schema: schema} do
      data = %{"name" => "Gem", "extra" => 123, "extra2" => true}

      assert {:error, errors} = JSONSchex.validate(schema, data)
      assert length(errors) == 2

      Enum.map(errors, fn e ->
        assert e.path == ["extra"] or e.path == ["extra2"]
        assert e.rule == :unevaluatedProperties
        assert JSONSchex.format_error(e) =~ "Property is not allowed"
      end)

    end

  end

  describe "Part 3: UnevaluatedProperties with Sub-Schema" do
    test "validates leftover fields against a specific schema" do
      # Schema: Explicit "id" is integer, anything else must be a String
      raw_schema = %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "integer"}
        },
        "unevaluatedProperties" => %{"type" => "string"}
      }
      {:ok, compiled} = JSONSchex.compile(raw_schema)

      # Valid: id is int, extra fields are strings
      valid_data = %{"id" => 1, "tag" => "admin", "note" => "hello"}
      assert :ok == JSONSchex.validate(compiled, valid_data)

      # Invalid: extra field 'score' is an integer, but unevaluated must be string
      invalid_data = %{"id" => 1, "score" => 99}

      assert {:error, errors} = JSONSchex.validate(compiled, invalid_data)
      assert [%Error{path: ["score"], rule: :type}] = errors
    end
  end

  describe "Part 4: Nested Error Reporting" do
    test "reports correct path for deep failures" do
      raw_schema = %{
        "properties" => %{
          "user" => %{
            "properties" => %{
              "profile" => %{
                "properties" => %{
                  "age" => %{"minimum" => 18}
                }
              }
            }
          }
        }
      }
      {:ok, compiled} = JSONSchex.compile(raw_schema)

      data = %{"user" => %{"profile" => %{"age" => 12}}}

      assert {:error, [error]} = JSONSchex.validate(compiled, data)
      assert error.path == ["age", "profile", "user"]
      assert error.rule == :minimum
    end
  end

  test "fails with specific error when extra field doesn't match schema" do
    raw = %{
      "unevaluatedProperties" => %{"type" => "string"}
    }
    {:ok, compiled} = JSONSchex.compile(raw)
    data = %{"extra" => 123}
    assert {:error, [error]} = JSONSchex.validate(compiled, data)
    # Because it's NOT a false schema, we get the detailed error
    assert error.path == ["extra"]
    assert error.rule == :type
  end

  describe "unevaluatedProperties should do not look up parents scope" do
    test "should not look up parents scope" do
      raw_schema = %{
        "type" => "object",
        "properties" => %{
          "id" => %{ "type" => "integer" }
        },
        "allOf" => [
          %{
            "comment" => "This sub-schema is 'blind' to the 'id' property above!",
            "properties" => %{
              "username" => %{ "type" => "string" }
            },
            "unevaluatedProperties" => false
          }
        ]
      }
      {:ok, compiled} = JSONSchex.compile(raw_schema)

      data = %{"id" => 1, "username" => "alice"}

      # This should fail

      # Why?
      #  The Root validator checks id. (Success)
      #  The validator enters the allOf sub-schema.
      #  Inside allOf, it checks username. (Success)
      #  Inside allOf, it hits unevaluatedProperties: false.
      #      It looks around inside this sub-schema. It sees username was handled.
      #      Crucially, it does not look up to the root. It has no idea id was handled by the parent.
      #      It sees id as an extra, unevaluated property and rejects the instance.

      assert {:error, [error]} = JSONSchex.validate(compiled, data)
      assert error.rule == :unevaluatedProperties and error.path == ["id"]

      assert :ok == JSONSchex.validate(compiled, %{"username" => "bob"})
    end
  end

  describe "unevaluatedProperties interacts with $ref" do
    setup do
      raw_schema = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$defs" => %{
          "user-base" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{ "type" => "string" },
              "email" => %{ "type" => "string", "format" => "email" }
            },
            "required" => ["name", "email"]
          }
        },
        "allOf" => [
          %{ "$ref" => "#/$defs/user-base" },
          %{
            "type" => "object",
            "properties" => %{
              "adminLevel" => %{ "type" => "integer" }
            }
          }
        ],
        "unevaluatedProperties" => false
      }
      {:ok, schema} = JSONSchex.compile(raw_schema)
      %{schema: schema}
    end

    test "instance contains exactly what is defined in the base schema AND the extension", %{schema: schema} do
      data = %{"name" => "Alice", "email" => "alice@example.com", "adminLevel" => 5}
      assert :ok == JSONSchex.validate(schema, data)
    end

    test "instance has an extra field favoriteColor that isn't in the base or the admin definition", %{schema: schema} do
      data = %{"name" => "Alice", "email" => "alice@example.com", "adminLevel" => 5, "favoriteColor" => "blue"}
      assert {:error, [error]} = JSONSchex.validate(schema, data)
      assert error.rule == :unevaluatedProperties and error.path == ["favoriteColor"]
    end
  end


end

defmodule JSONSchex.Test.RefRecursion do
  use ExUnit.Case
  alias JSONSchex.Types.Error

  test "validates recursive definitions (linked list)" do
    # A linked list of numbers: { "val": 1, "next": { "val": 2, "next": null } }
    schema = %{
      "$defs" => %{
        "node" => %{
          "type" => "object",
          "properties" => %{
            "val" => %{"type" => "integer"},
            "next" => %{"$ref" => "#/$defs/node"} # Recursive Ref
          }
        }
      },
      "$ref" => "#/$defs/node"
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    # 1. Valid Deep List
    valid_data = %{
      "val" => 1,
      "next" => %{
        "val" => 2,
        "next" => %{
          "val" => 3,
          "next" => nil # Terminates (assuming nil is not allowed, expected type object)
        }
      }
    }

    # In this strict schema, 'next' is optional (not in required), so 'nil' should fail type check if present.
    assert {:error, _} = JSONSchex.validate(compiled, valid_data)

    valid_data_fixed = %{
      "val" => 1,
      "next" => %{
        "val" => 2
        # no 'next' here, valid because optional
      }
    }

    assert :ok == JSONSchex.validate(compiled, valid_data_fixed)

    # 2. Invalid Type Deep Down
    invalid_data = %{
      "val" => 1,
      "next" => %{
        "val" => "NOT A NUMBER" # Error here
      }
    }

    assert {:error, errors} = JSONSchex.validate(compiled, invalid_data)
    # Path should be preserved across the ref jump
    assert [%Error{path: ["val", "next"], rule: :type}] = errors
  end
end

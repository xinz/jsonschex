defmodule JSONSchex.Validator.ShortCircuitTest do
  use ExUnit.Case, async: true

  test "compiler sets needs_evaluated_annotations statically" do
    {:ok, plain} = JSONSchex.compile(%{"type" => "object", "properties" => %{"a" => %{"type" => "integer"}}})
    refute plain.needs_evaluated_annotations

    {:ok, with_uneval_props} =
      JSONSchex.compile(%{
        "anyOf" => [
          %{"properties" => %{"a" => %{"type" => "integer"}}},
          %{"properties" => %{"b" => %{"type" => "string"}}}
        ],
        "unevaluatedProperties" => false
      })

    assert with_uneval_props.needs_evaluated_annotations

    {:ok, with_uneval_items} =
      JSONSchex.compile(%{
        "prefixItems" => [%{"type" => "integer"}],
        "unevaluatedItems" => false
      })

    assert with_uneval_items.needs_evaluated_annotations
  end

  test "valid?/2 preserves unevaluatedProperties annotations across multiple matching anyOf branches" do
    {:ok, schema} =
      JSONSchex.compile(%{
        "anyOf" => [
          %{"properties" => %{"a" => %{"type" => "integer"}}},
          %{"properties" => %{"b" => %{"type" => "string"}}}
        ],
        "unevaluatedProperties" => false
      })

    # Both branches match, so both "a" and "b" are evaluated.
    assert JSONSchex.valid?(schema, %{"a" => 1, "b" => "ok"})
    refute JSONSchex.valid?(schema, %{"a" => 1, "b" => "ok", "c" => true})
  end

  test "valid?/2 does not invert indeterminate_pattern under not" do
    # Reproduces PCRE match-limit exhaustion from regex_match_limit_test.exs
    pattern = "^(?:(a+)+b|a+!)$"
    long_input = String.duplicate("a", 25) <> "!"

    {:ok, schema} = JSONSchex.compile(%{"not" => %{"pattern" => pattern}})
    assert {:error, [%{rule: :indeterminate_pattern}]} = JSONSchex.validate(schema, long_input)
    refute JSONSchex.valid?(schema, long_input)
  end

  test "valid?/2 handles recursive $ref and contains bounds" do
    {:ok, node_schema} =
      JSONSchex.compile(%{
        "$defs" => %{
          "node" => %{
            "type" => "object",
            "required" => ["value"],
            "properties" => %{
              "value" => %{"type" => "integer"},
              "next" => %{"$ref" => "#/$defs/node"}
            }
          }
        },
        "$ref" => "#/$defs/node"
      })

    assert JSONSchex.valid?(node_schema, %{"value" => 1, "next" => %{"value" => 2}})
    refute JSONSchex.valid?(node_schema, %{"value" => 1, "next" => %{"value" => "bad"}})

    {:ok, contains_schema} =
      JSONSchex.compile(%{
        "type" => "array",
        "contains" => %{"type" => "integer"},
        "minContains" => 2,
        "maxContains" => 3
      })

    refute JSONSchex.valid?(contains_schema, [1, "a", "b"])
    assert JSONSchex.valid?(contains_schema, [1, 2, "a"])
    assert JSONSchex.valid?(contains_schema, [1, 2, 3])
    refute JSONSchex.valid?(contains_schema, [1, 2, 3, 4])
  end
end

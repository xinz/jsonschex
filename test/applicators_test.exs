defmodule JSONSchex.Test.Applicators do
  use ExUnit.Case

  describe "anyOf (Logical OR)" do
    setup do
      # Schema: Match (a string) OR (b integer) OR (c boolean)
      schema = %{
        "anyOf" => [
          %{"properties" => %{"a" => %{"type" => "string"}}},
          %{"properties" => %{"b" => %{"type" => "integer"}}},
          %{"properties" => %{"c" => %{"type" => "boolean"}}}
        ],
        "unevaluatedProperties" => false
      }
      {:ok, compiled} = JSONSchex.compile(schema)
      %{schema: compiled}
    end

    test "validates when one branch matches", %{schema: schema} do
      # Matches first branch. 'a' is evaluated. No extra fields.
      assert :ok == JSONSchex.validate(schema, %{"a" => "hello"})
    end

    test "validates when multiple branches match (Annotation Merging)", %{schema: schema} do
      # Matches branch 1 ("a") AND branch 2 ("b").
      # Logic: evaluated_keys = {"a"} U {"b"} = {"a", "b"}
      # unevaluatedProperties checks leftovers: {} -> Valid.
      data = %{"a" => "hello", "b" => 100}
      assert :ok == JSONSchex.validate(schema, data)
    end

    test "fails when no branches match", %{schema: schema} do
      data = %{"d" => "unknown"}
      assert {:error, errors} = JSONSchex.validate(schema, data)
      # Should contain errors from sub-schemas or a generic failure
      refute Enum.empty?(errors)
    end

    test "fails when partial match leaves unevaluated properties", %{schema: schema} do
      # Matches branch 1 ("a"). Branch 2 and 3 fail.
      # evaluated_keys = {"a"}
      # leftovers = {"d"} -> Fails unevaluatedProperties
      data = %{"a" => "hello", "d" => "extra"}

      assert {:error, [error]} = JSONSchex.validate(schema, data)
      assert error.rule == :unevaluatedProperties
      assert error.path == ["d"]
    end
  end

  describe "not (Logical NOT)" do
    test "basic inversion" do
      # Value must NOT be a string
      schema = %{"not" => %{"type" => "string"}}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, 123)

      assert {:error, [error]} = JSONSchex.validate(compiled, "bad")
      assert error.rule == :not
    end

    test "annotations are NOT propagated from inside 'not'" do
      # Spec: "The 'not' keyword does not affect which properties are considered evaluated."

      # Schema:
      # 1. check "a" (always valid) inside 'not' to trick the system?
      # 2. fail if "a" is string (inverted -> fail if "a" IS string)
      # Actually, let's test that checking a property inside 'not' doesn't "save" it from unevaluatedProperties

      raw = %{
        # "not" checks "a", but should NOT mark "a" as evaluated.
        "not" => %{"properties" => %{"a" => %{"const" => "bad_value"}}},
        "unevaluatedProperties" => false
      }
      {:ok, compiled} = JSONSchex.compile(raw)

      # Input: "a": "good_value"
      # 1. Inner 'properties' -> "a" != "bad_value" -> Inner Fails.
      # 2. 'not' Inverts -> Success.
      # 3. Annotations returned by 'not' -> Empty Set (Per Spec).
      # 4. 'unevaluatedProperties' sees "a" is unevaluated -> Error.

      data = %{"a" => "good_value"}

      assert {:error, [error]} = JSONSchex.validate(compiled, data)
      assert error.rule == :unevaluatedProperties
      assert error.path == ["a"]

      data = %{"a" => "bad_value"}
      assert {:error, errors} = JSONSchex.validate(compiled, data)
      assert length(errors) == 2
      Enum.map(errors, fn e ->
        assert (e.rule == :not and e.path == []) or
          (e.rule == :unevaluatedProperties and e.path == ["a"])
      end)
    end
  end

  describe "allOf (Logical AND) with Complexity" do
    test "accumulates evaluations from multiple steps" do
      raw = %{
        "allOf" => [
          # Step 1: Evaluate "id"
          %{"properties" => %{"id" => %{"type" => "integer"}}},
          # Step 2: Evaluate "meta"
          %{"properties" => %{"meta" => %{"type" => "object"}}}
        ],
        "unevaluatedProperties" => false
      }
      {:ok, compiled} = JSONSchex.compile(raw)

      data = %{"id" => 1, "meta" => %{}}
      assert :ok == JSONSchex.validate(compiled, data)

      # "id" matches, "meta" matches, but "extra" is leftover
      data_invalid = %{"id" => 1, "meta" => %{}, "extra" => true}
      assert {:error, [error]} = JSONSchex.validate(compiled, data_invalid)
      assert error.rule == :unevaluatedProperties
      assert error.path == ["extra"]
    end
  end
end

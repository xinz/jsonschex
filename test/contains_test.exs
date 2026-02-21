defmodule JSONSchex.Test.Contains do
  use ExUnit.Case

  describe "Basic Contains" do
    test "requires at least one match by default" do
      schema = %{"contains" => %{"type" => "integer"}}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, ["a", 1, "b"]) # 1 match
      assert :ok == JSONSchex.validate(compiled, [1, 2, 3])     # 3 matches

      assert {:error, [e]} = JSONSchex.validate(compiled, ["a", "b"]) # 0 matches
      assert e.rule == :contains
    end
  end

  describe "minContains / maxContains" do
    test "validates boundaries" do
      schema = %{
        "contains" => %{"type" => "integer"},
        "minContains" => 2,
        "maxContains" => 3
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert {:error, _} = JSONSchex.validate(compiled, [1])          # Too few (1)
      assert :ok         == JSONSchex.validate(compiled, [1, 2])       # Exact min
      assert :ok         == JSONSchex.validate(compiled, [1, 2, 3])    # Exact max
      assert {:error, _} = JSONSchex.validate(compiled, [1, 2, 3, 4]) # Too many (4)
    end

    test "minContains: 0 allows no matches" do
      # If minContains is 0, the schema is always valid unless maxContains is exceeded
      schema = %{
        "contains" => %{"const" => "found"},
        "minContains" => 0
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, ["nothing", "here"])
    end
  end

  describe "Integration: contains + unevaluatedItems" do
    test "matches from contains are considered evaluated" do
      schema = %{
        "contains" => %{"const" => "apple"},
        "unevaluatedItems" => false
      }
      {:ok, compiled} = JSONSchex.compile(schema)
      assert {:error, [e]} = JSONSchex.validate(compiled, ["apple", "banana"])
      assert e.rule == :unevaluatedItems and e.path == [1]
      assert JSONSchex.format_error(e) =~ "Item is not allowed"
    end
  end

  describe "Error message formatting" do
    # These tests exercise all four contains format_message clauses in
    # error_formatter.ex, with particular focus on the L86-88 clause:
    #
    #   format_message(%Error{rule: :contains,
    #                         context: %{contrast: 1, error_detail: "min", input: 0}})
    #   => "Array must contain at least one matching item, but none matched"

    test "default contains (min=1) with zero matches produces 'but none matched' message" do
      schema = %{"contains" => %{"type" => "integer"}}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert {:error, [error]} = JSONSchex.validate(compiled, ["a", "b", "c"])
      assert error.rule == :contains
      assert error.context.contrast == 1
      assert error.context.input == 0
      assert error.context.error_detail == "min"
      assert JSONSchex.format_error(error) == "Array must contain at least one matching item, but none matched"
    end

    test "explicit minContains: 1 with zero matches produces 'but none matched' message" do
      # Same L86-88 clause reached via an explicit minContains: 1 declaration
      schema = %{
        "contains" => %{"type" => "boolean"},
        "minContains" => 1
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert {:error, [error]} = JSONSchex.validate(compiled, [1, "x", %{}])
      assert error.rule == :contains
      assert error.context.contrast == 1
      assert error.context.input == 0
      assert error.context.error_detail == "min"
      assert JSONSchex.format_error(error) == "Array must contain at least one matching item, but none matched"
    end

    test "minContains > 1 with too few matches reports found count" do
      # Targets the contrast: min, error_detail: "min", input: count clause
      schema = %{
        "contains" => %{"type" => "integer"},
        "minContains" => 3
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert {:error, [error]} = JSONSchex.validate(compiled, [1, "a", "b"])
      assert error.rule == :contains
      assert error.context.contrast == 3
      assert error.context.input == 1
      assert error.context.error_detail == "min"
      assert JSONSchex.format_error(error) == "Array must contain at least 3 matching items, found 1"
    end

    test "maxContains exceeded reports found count" do
      # Targets the contrast: max, error_detail: "max", input: count clause
      schema = %{
        "contains" => %{"type" => "integer"},
        "maxContains" => 2
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert {:error, [error]} = JSONSchex.validate(compiled, [1, 2, 3])
      assert error.rule == :contains
      assert error.context.contrast == 2
      assert error.context.input == 3
      assert error.context.error_detail == "max"
      assert JSONSchex.format_error(error) == "Array must contain at most 2 matching items, found 3"
    end
  end
end

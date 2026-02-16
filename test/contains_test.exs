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

      assert {:error, _} = JSONSchex.validate(compiled, [1])       # Too few (1)
      assert :ok         == JSONSchex.validate(compiled, [1, 2])    # Exact min
      assert :ok         == JSONSchex.validate(compiled, [1, 2, 3]) # Exact max
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
      # Schema:
      # 1. contains: Must have at least one Integer.
      # 2. unevaluatedItems: Must be String.
      #
      # Logic:
      # - Input: [1, "a"]
      # - Index 0 (1): Matches 'contains'. marked Evaluated.
      # - Index 1 ("a"): Fails 'contains'. Unevaluated.
      # - unevaluatedItems checks Index 1 ("a") -> Valid (String).
      # - Result: OK.

      #schema = %{
      #  "contains" => %{"type" => "integer"},
      #  "unevaluatedItems" => %{"type" => "string"}
      #}
      #{:ok, compiled} = JSONSchex.compile(schema)

      #assert :ok == JSONSchex.validate(compiled, [100, "hello"])

      ## Fail case: Index 0 is Int (Evaluated). Index 1 is Bool (Unevaluated).
      ## Unevaluated (Bool) != String -> Error.
      #assert {:error, [e]} = JSONSchex.validate(compiled, [100, true])
      #assert e.rule == :type
      #assert e.path == "/1"

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
end

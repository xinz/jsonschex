defmodule JSONSchex.Compiler.PredicatesTest do
  use ExUnit.Case
  alias JSONSchex.Compiler.Predicates
  alias JSONSchex.Types.{Error, ErrorContext}

  test "type checks accept matching scalar, collection, and numeric values" do
    cases = [
      {"", "string"},
      {"héllo", "string"},
      {<<0xFF>>, "string"},
      {0, "integer"},
      {-42, "integer"},
      {Integer.pow(2, 100), "integer"},
      {1.0, "integer"},
      {-0.0, "integer"},
      {1.0e100, "integer"},
      {1, "number"},
      {1.0, "number"},
      {1.5, "number"},
      {true, "boolean"},
      {false, "boolean"},
      {%{}, "object"},
      {%ErrorContext{}, "object"},
      {[], "array"},
      {[1, nil], "array"},
      {nil, "null"}
    ]

    for {data, expected} <- cases do
      assert Predicates.check_type(data, expected) == :ok
    end
  end

  test "type mismatches retain scalar error contexts" do
    cases = [
      {1, "string", "integer"},
      {"1", "integer", "string"},
      {1.5, "integer", "float"},
      {1.0, "string", "integer"},
      {1.5, "string", "number"},
      {nil, "boolean", "null"},
      {false, "null", "boolean"},
      {[], "object", "array"},
      {%{}, "array", "object"},
      {"1", "number", "string"},
      {:not_json, "string", "unknown"},
      {{1, 2}, "array", "unknown"},
      {"value", "unsupported", "string"},
      {1, "unsupported", "integer"},
      {nil, "unsupported", "null"}
    ]

    for {data, expected, actual} <- cases do
      assert Predicates.check_type(data, expected) ===
               {:error, %ErrorContext{contrast: expected, input: actual}}
    end
  end

  test "type unions accept matching members in different positions" do
    cases = [
      {1, ["string", "number"]},
      {1.0, ["null", "integer"]},
      {1.5, ["integer", "number"]},
      {"value", ["string", "null"]},
      {nil, ["integer", "null", "string"]},
      {false, ["null", "boolean"]},
      {%{}, ["array", "object"]},
      {[], ["object", "array"]}
    ]

    for {data, types} <- cases do
      assert Predicates.check_type(data, types) == :ok
    end
  end

  test "type union failures preserve declared types and aggregate input inference" do
    # A failed scalar integer check reports "float"; a union reports the
    # inferred JSON type "number", retaining the original order and duplicates.
    cases = [
      {1.5, ["integer"], "number"},
      {1.5, ["integer", "string", "integer"], "number"},
      {1.0, ["string", "null"], "integer"},
      {nil, ["string", "boolean"], "null"},
      {:not_json, ["string", "number"], "unknown"},
      {1, [], "integer"}
    ]

    for {data, types, actual} <- cases do
      assert Predicates.check_type(data, types) ===
               {:error, %ErrorContext{contrast: types, input: actual}}
    end
  end

  for draft <- ["draft7", "draft2020_12"] do
    @draft draft

    test "nested type errors retain paths, values, and scalar/union diagnostics (#{draft})" do
      types = ["null", "integer", "integer"]
      schema = %{
        "type" => "object",
        "properties" => %{
          "single" => %{"type" => "integer"},
          "union" => %{"type" => types}
        }
      }

      assert {:ok, compiled} = JSONSchex.compile(schema, draft: @draft)
      assert :ok == JSONSchex.validate(compiled, %{"single" => 1.0, "union" => nil})
      assert {:error, errors} = JSONSchex.validate(compiled, %{"single" => 1.5, "union" => 1.5})
      assert length(errors) == 2
      errors_by_path = Map.new(errors, &{&1.path, &1})

      assert errors_by_path[["single"]] === %Error{
               path: ["single"], rule: :type, value: 1.5,
               context: %ErrorContext{contrast: "integer", input: "float"}
             }
      assert errors_by_path[["union"]] === %Error{
               path: ["union"], rule: :type, value: 1.5,
               context: %ErrorContext{contrast: types, input: "number"}
             }
    end
  end

  test "uniqueItems rejects mathematically equal numbers inside arrays and objects" do
    for data <- nested_numeric_duplicates() do
      assert Predicates.check_unique_items(data, true) ===
               {:error, %ErrorContext{contrast: true, input: data}}
    end
  end

  test "uniqueItems ignores object construction order when hashing nested numbers" do
    integers = Map.new(1..40, fn index -> {"key-#{index}", [index]} end)
    floats = Map.new(40..1//-1, fn index -> {"key-#{index}", [index * 1.0]} end)
    assert integers == floats
    refute integers === floats
    data = [integers, floats]

    assert Predicates.check_unique_items(data, true) ===
             {:error, %ErrorContext{contrast: true, input: data}}
  end

  test "uniqueItems preserves equality for Elixir composites without normalizing map keys" do
    for data <- [
      [{1, [2]}, {1.0, [2.0]}],
      [[1 | 2], [1.0 | 2.0]],
      [%ErrorContext{input: [1]}, %ErrorContext{input: [1.0]}]
    ] do
      assert Predicates.check_unique_items(data, true) ===
               {:error, %ErrorContext{contrast: true, input: data}}
    end
    assert Predicates.check_unique_items([%{1 => "value"}, %{1.0 => "value"}], true) == :ok
  end

  test "uniqueItems keeps distinct structures and scalar types separate" do
    data = [
      [1, 2], [2, 1], [1, 2.5], true, false, nil, 0, "0",
      %{"x" => 1}, %{"y" => 1.0}, %{"x" => [1, 2]}, %{"x" => [1, 3]}
    ]
    assert Predicates.check_unique_items(data, true) == :ok
  end

  test "uniqueItems checks equality rather than treating hash collisions as duplicates" do
    # These distinct integers collide under the scalar hash used by the predicate.
    first = 16_634
    second = 23_078
    assert :erlang.phash2(first) == :erlang.phash2(second)
    assert Predicates.check_unique_items([first, second], true) == :ok
    data = [first, second, first]
    assert Predicates.check_unique_items(data, true) ===
             {:error, %ErrorContext{contrast: true, input: data}}
  end

  test "uniqueItems remains inapplicable to non-arrays and disabled assertions" do
    for data <- [nil, false, 1, "value", %{"x" => 1}] do
      assert Predicates.check_unique_items(data, true) == :ok
    end
    for data <- [[], [1], [1, 1.0], [[1], [1.0]]] do
      assert Predicates.check_unique_items(data, false) == :ok
    end
    assert Predicates.check_unique_items([], true) == :ok
    assert Predicates.check_unique_items([%{"x" => [1.0]}], true) == :ok
  end

  test "uniqueItems agrees with pairwise equality for a bounded JSON-value corpus" do
    values = [
      nil, false, true, -1, 0, 1, 1.0, -0.0, 1.5, "", "1", [], [1], [1.0],
      %{}, %{"x" => 1}, %{"x" => 1.0}, %{"x" => [1]}, %{"x" => [1.0]}
    ]
    small = [0, 1, 1.0, nil, [1], [1.0]]
    corpus = [[]] ++ Enum.map(values, &[&1]) ++
      (for left <- values, right <- values, do: [left, right]) ++
      (for first <- small, second <- small, third <- small, do: [first, second, third])

    for data <- corpus do
      expected = if duplicate_by_equality?(data),
        do: {:error, %ErrorContext{contrast: true, input: data}}, else: :ok
      assert Predicates.check_unique_items(data, true) === expected,
             "Unexpected uniqueness result for #{inspect(data)}"
    end
  end

  test "unique items that numbers are unique if mathematically unequal" do
    assert {:error, %JSONSchex.Types.ErrorContext{contrast: true}} = JSONSchex.Compiler.Predicates.check_unique_items([1.0, 1], true)

    schema =%{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "uniqueItems" => true
    }

    {:ok, c} = JSONSchex.compile(schema)
    assert {:error, _} = JSONSchex.validate(c, [1.0, 1])
  end

  test "validates string length using unicode code points (not graphemes)" do
    data = "#️⃣"
    assert String.length(data) == 1
    assert length(String.to_charlist(data)) == 3

    schema = %{"type" => "string", "minLength" => 3}
    {:ok, c} = JSONSchex.compile(schema)
    assert :ok == JSONSchex.validate(c, data)

    schema = %{"type" => "string", "maxLength" => 1}
    {:ok, c} = JSONSchex.compile(schema)

    assert {:error, [error]} = JSONSchex.validate(c, data)
    assert error.rule == :maxLength
  end

  defp nested_numeric_duplicates do
    [
      [[1], [1.0]],
      [%{"x" => 1}, %{"x" => 1.0}],
      [%{"x" => [1, %{"y" => 2}]}, %{"x" => [1.0, %{"y" => 2.0}]}],
      [[0, [%{"value" => 3}], true], [0.0, [%{"value" => 3.0}], true]],
      [[trunc(1.0e100)], [1.0e100]],
      [[0], [-0.0]]
    ]
  end

  # Deliberately independent of hashing and exact-key map/set membership.
  defp duplicate_by_equality?([]), do: false
  defp duplicate_by_equality?([item | rest]) do
    Enum.any?(rest, &(&1 == item)) or duplicate_by_equality?(rest)
  end
end

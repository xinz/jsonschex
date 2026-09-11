defmodule JSONSchex.Test.RequiredPropertiesTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Error, ErrorContext, Rule}
  alias JSONSchex.Validator.Rules

  test "reports missing properties in required declaration order" do
    required = ["missing-c", "present", "missing-a", "missing-b"]
    assert {:ok, schema} = JSONSchex.compile(%{"required" => required})

    assert {:error, [%Error{} = error]} = JSONSchex.validate(schema, %{"present" => true})
    assert error.rule == :required
    assert error.context.contrast == ["missing-c", "missing-a", "missing-b"]
  end

  test "direct rules preserve duplicate missing entries" do
    rule = %Rule{name: :required, params: ["missing", "present", "missing"]}
    context = {[], MapSet.new(), nil}

    assert {:error, [%Error{} = error]} = Rules.apply(rule, %{"present" => true}, context)
    assert error.context.contrast == ["missing", "missing"]
  end

  test "detects missing properties at the first, middle, and last positions" do
    required = Enum.map(1..64, &"property-#{&1}")
    assert {:ok, schema} = JSONSchex.compile(%{"required" => required})
    complete = Map.new(required, &{&1, true})

    for missing <- [List.first(required), Enum.at(required, 32), List.last(required)] do
      assert {:error, [%Error{} = error]} = JSONSchex.validate(schema, Map.delete(complete, missing))
      assert error.context.contrast == [missing]
    end
  end

  test "passes when every required property is present" do
    required = Enum.map(1..64, &"property-#{&1}")
    assert {:ok, schema} = JSONSchex.compile(%{"required" => required})

    assert :ok == JSONSchex.validate(schema, Map.new(required, &{&1, nil}))
  end

  test "remains inapplicable to non-object data and compatible with direct rules" do
    rule = %Rule{name: :required, params: ["first", "second"]}
    context = {[:parent], MapSet.new(), nil}

    assert :ok == Rules.apply(rule, [], context)
    assert :ok == Rules.apply(%Rule{name: :required, params: []}, %{}, context)

    assert {:error,
            [
              %Error{
                path: [:parent],
                rule: :required,
                context: %ErrorContext{contrast: ["first", "second"]}
              }
            ]} = Rules.apply(rule, %{}, context)
  end
end

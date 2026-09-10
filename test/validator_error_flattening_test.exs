defmodule JSONSchex.Test.ValidatorErrorFlatteningTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Error, ErrorContext, Rule, Schema, ValidationContext}

  test "public validation preserves nested error order, paths, and local values" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "properties" => %{
                 "rows" => %{
                   "items" => %{
                     "allOf" => [
                       %{"type" => "integer"},
                       %{"minimum" => 10},
                       %{"maximum" => 0}
                     ]
                   }
                 }
               }
             })

    data = %{"rows" => ["bad", 5, 20]}

    assert {:error, errors} = JSONSchex.validate(schema, data)

    assert Enum.map(errors, fn %Error{rule: rule, path: path, value: value} ->
             {rule, path, value}
           end) == [
             {:maximum, [2, "rows"], 20},
             {:minimum, [1, "rows"], 5},
             {:maximum, [1, "rows"], 5},
             {:type, [0, "rows"], "bad"}
           ]
  end

  test "public validation does not change validate_entry error grouping" do
    assert {:ok, compiled} =
             JSONSchex.compile(%{
               "required" => ["missing"],
               "properties" => %{
                 "value" => %{
                   "allOf" => [
                     %{"type" => "string"},
                     %{"minimum" => 10}
                   ]
                 }
               }
             })

    schema = reorder_rules(compiled, [:required, :properties])
    data = %{"value" => 5}

    assert {:error, [property_errors, required_errors] = grouped_errors} =
             validate_entry(schema, data)

    assert Enum.map(property_errors, & &1.rule) == [:type, :minimum]
    assert Enum.map(required_errors, & &1.rule) == [:required]

    assert {:error, public_errors} = JSONSchex.validate(schema, data)
    assert public_errors == List.flatten(grouped_errors)
  end

  test "failed applicators preserve nested branch error order" do
    branches =
      1..8
      |> Enum.chunk_every(2)
      |> Enum.map(fn contrasts ->
        %{"allOf" => Enum.map(contrasts, &%{"const" => &1})}
      end)

    for keyword <- ["allOf", "anyOf", "oneOf"] do
      assert {:ok, schema} = JSONSchex.compile(%{keyword => branches})

      initial_evaluated =
        if keyword == "anyOf", do: MapSet.new(1..8), else: MapSet.new()

      assert {:error, errors} = validate_entry(schema, -1, initial_evaluated)
      assert Enum.map(errors, & &1.rule) == List.duplicate(:const, 8)
      assert Enum.map(errors, & &1.context.contrast) == Enum.to_list(1..8)
    end
  end

  test "false unevaluated schemas retain rewritten errors and reverse traversal order" do
    property_data = %{"a" => 1, "b" => 2, "c" => 3, "d" => 4}
    assert {:ok, property_schema} = JSONSchex.compile(%{"unevaluatedProperties" => false})
    assert {:error, property_errors} = JSONSchex.validate(property_schema, property_data)

    expected_property_paths =
      property_data
      |> Map.to_list()
      |> Enum.map(fn {key, _value} -> [key] end)
      |> Enum.reverse()

    assert Enum.map(property_errors, & &1.path) == expected_property_paths

    Enum.each(property_errors, fn error ->
      assert error.rule == :unevaluatedProperties
      assert error.context == %ErrorContext{contrast: "not_allowed"}
      assert error.value == nil
    end)

    assert {:ok, item_schema} = JSONSchex.compile(%{"unevaluatedItems" => false})
    assert {:error, item_errors} = JSONSchex.validate(item_schema, [1, 2, 3, 4])
    assert Enum.map(item_errors, & &1.path) == [[3], [2], [1], [0]]

    Enum.each(item_errors, fn error ->
      assert error.rule == :unevaluatedItems
      assert error.context == %ErrorContext{contrast: "not_allowed"}
      assert error.value == nil
    end)
  end

  test "ordinary unevaluated-property failures retain child rules and values" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "unevaluatedProperties" => %{
                 "allOf" => [
                   %{"type" => "string"},
                   %{"minLength" => 3}
                 ]
               }
             })

    assert {:error, errors} = JSONSchex.validate(schema, %{"a" => 1, "b" => "x"})

    assert Enum.map(errors, fn %Error{rule: rule, path: path, value: value} ->
             {rule, path, value}
           end) == [
             {:minLength, ["b"], "x"},
             {:type, ["a"], 1}
           ]
  end

  test "wide flat error results are flattened without losing entries" do
    width = 4_096
    assert {:ok, schema} = JSONSchex.compile(%{"items" => %{"type" => "integer"}})

    assert {:error, errors} = JSONSchex.validate(schema, List.duplicate("bad", width))
    assert length(errors) == width
    assert hd(errors).path == [width - 1]
    assert List.last(errors).path == [0]
    assert Enum.all?(errors, &(&1.rule == :type and &1.value == "bad"))
  end

  defp validate_entry(%Schema{} = schema, data, initial_evaluated \\ MapSet.new()) do
    context = %ValidationContext{
      root_schema: schema,
      source_id: schema.source_id,
      raw: schema.raw,
      scope_stack: if(schema.source_id, do: [schema.source_id], else: [])
    }

    JSONSchex.Validator.validate_entry(schema, data, [], context, initial_evaluated)
  end

  # Rule order is observable because the validator accumulates sibling failures
  # in reverse execution order. Make that order explicit for the grouping test.
  defp reorder_rules(%Schema{rules: rules} = schema, names) do
    selected =
      Enum.map(names, fn name ->
        case Enum.find(rules, &(&1.name == name)) do
          %Rule{} = rule -> rule
          nil -> raise "expected compiled #{inspect(name)} rule"
        end
      end)

    remaining = Enum.reject(rules, &(&1.name in names))
    %{schema | rules: selected ++ remaining}
  end
end

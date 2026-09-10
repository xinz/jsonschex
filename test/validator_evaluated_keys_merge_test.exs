defmodule JSONSchex.Test.ValidatorEvaluatedKeysMergeTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Rule, Schema, ValidationContext}

  test "allOf unions overlapping and disjoint successful evaluated keys" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "allOf" => [
                 %{"properties" => %{"a" => true, "shared" => true}},
                 %{"properties" => %{"b" => true, "shared" => true}}
               ]
             })

    assert {:ok, evaluated} = validate_entry(schema, %{"a" => 1, "b" => 2, "shared" => 3})
    assert evaluated == MapSet.new(["a", "b", "shared"])
  end

  test "anyOf unions every successful branch with the same incoming evaluated keys" do
    assert {:ok, compiled} =
             JSONSchex.compile(%{
               "properties" => %{"seed" => true},
               "anyOf" => [
                 %{"properties" => %{"a" => true, "shared" => true}},
                 %{"properties" => %{"b" => true, "shared" => true}}
               ]
             })

    schema = reorder_rules(compiled, [:properties, :anyOf])
    data = %{"seed" => 0, "a" => 1, "b" => 2, "shared" => 3}

    assert {:ok, evaluated} = validate_entry(schema, data)
    assert evaluated == MapSet.new(["seed", "a", "b", "shared"])
  end

  test "direct anyOf merging does not pass earlier branch evaluated keys into a later branch" do
    seed_keys = Enum.map(1..8, &"seed-#{&1}")

    assert {:ok, compiled} =
             JSONSchex.compile(%{
               "properties" => Map.new(seed_keys, &{&1, true}),
               "anyOf" => [
                 %{"properties" => %{"a" => true}},
                 %{
                   "properties" => %{"b" => true},
                   "unevaluatedProperties" => false
                 },
                 true,
                 true,
                 true
               ],
               "unevaluatedProperties" => false
             })

    schema = reorder_rules(compiled, [:properties, :anyOf, :unevaluatedProperties])
    data = Map.merge(Map.new(seed_keys, &{&1, 0}), %{"a" => 1, "b" => 2})

    assert {:error, errors} = JSONSchex.validate(schema, data)
    assert [%{rule: :unevaluatedProperties, path: ["b"]}] = errors
  end

  test "anyOf continues through later branches after an earlier success" do
    parent = self()
    seed_keys = Enum.map(1..8, &"seed-#{&1}")

    assert {:ok, compiled} =
             JSONSchex.compile(
               %{
                 "properties" => Map.new(seed_keys, &{&1, true}),
                 "anyOf" => [
                   %{"properties" => %{"first" => true}},
                   %{"$ref" => "https://example.test/later.json"},
                   true,
                   true
                 ]
               },
               loader: fn _uri ->
                 send(parent, :later_any_of_branch)
                 {:ok, false}
               end
             )

    schema = reorder_rules(compiled, [:properties, :anyOf])
    data = Map.put(Map.new(seed_keys, &{&1, true}), "first", true)

    refute_received :later_any_of_branch
    assert :ok == JSONSchex.validate(schema, data)
    assert_received :later_any_of_branch
  end

  test "dependentSchemas unions all triggered successful evaluated keys" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "dependentSchemas" => %{
                 "trigger-a" => %{"properties" => %{"a" => true, "shared" => true}},
                 "trigger-b" => %{"properties" => %{"b" => true, "shared" => true}}
               }
             })

    data = %{
      "trigger-a" => true,
      "trigger-b" => true,
      "a" => 1,
      "b" => 2,
      "shared" => 3
    }

    assert {:ok, evaluated} = validate_entry(schema, data)
    assert evaluated == MapSet.new(["a", "b", "shared"])
  end

  test "schema-valued legacy dependencies unions triggered evaluated keys" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "dependencies" => %{
                 "trigger-a" => %{"properties" => %{"a" => true, "shared" => true}},
                 "trigger-b" => %{"properties" => %{"b" => true, "shared" => true}}
               }
             })

    data = %{
      "trigger-a" => true,
      "trigger-b" => true,
      "a" => 1,
      "b" => 2,
      "shared" => 3
    }

    assert {:ok, evaluated} = validate_entry(schema, data)
    assert evaluated == MapSet.new(["a", "b", "shared"])
  end

  test "empty successful evaluated-key results remain MapSets" do
    for raw_schema <- [
          %{"allOf" => [true]},
          %{"anyOf" => [true, false]},
          %{"dependentSchemas" => %{"trigger" => %{"properties" => %{"value" => true}}}}
        ] do
      assert {:ok, schema} = JSONSchex.compile(raw_schema)
      assert {:ok, evaluated} = validate_entry(schema, %{})
      assert evaluated == MapSet.new()
    end
  end

  test "anyOf merges dominant shared incoming evaluated keys" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "anyOf" => [
                 %{"properties" => %{"a" => true}},
                 %{"properties" => %{"b" => true}},
                 %{"properties" => %{"c" => true}},
                 %{"properties" => %{"d" => true}}
               ]
             })

    parent_evaluated_keys = MapSet.new(Enum.map(1..16, &"seed-#{&1}"))
    data = %{"a" => 1, "b" => 2, "c" => 3, "d" => 4}

    assert {:ok, evaluated} = validate_entry(schema, data, parent_evaluated_keys)
    assert evaluated == MapSet.union(parent_evaluated_keys, MapSet.new(["a", "b", "c", "d"]))
  end

  test "anyOf preserves evaluated keys when incoming overlap falls back to bulk merging" do
    branches =
      Enum.map(1..4, fn branch ->
        fields = Enum.map(1..8, &"branch-#{branch}-#{&1}")
        %{"properties" => Map.new(fields, &{&1, true})}
      end)

    branch_fields =
      for branch <- 1..4, field <- 1..8 do
        "branch-#{branch}-#{field}"
      end

    assert {:ok, schema} = JSONSchex.compile(%{"anyOf" => branches})
    parent_evaluated_keys = MapSet.new(Enum.map(1..8, &"seed-#{&1}"))

    assert {:ok, evaluated} =
             validate_entry(schema, Map.new(branch_fields, &{&1, true}), parent_evaluated_keys)

    assert evaluated == MapSet.union(parent_evaluated_keys, MapSet.new(branch_fields))
  end

  test "anyOf preserves evaluated keys when a later branch causes bulk fallback" do
    early_fields = Enum.map(1..3, &"early-#{&1}")
    late_fields = Enum.map(1..16, &"late-#{&1}")

    assert {:ok, schema} =
             JSONSchex.compile(%{
               "anyOf" =>
                 Enum.map(early_fields, &%{"properties" => %{&1 => true}}) ++
                   [%{"properties" => Map.new(late_fields, &{&1, true})}]
             })

    parent_evaluated_keys = MapSet.new(Enum.map(1..8, &"seed-#{&1}"))
    data = Map.new(early_fields ++ late_fields, &{&1, true})

    assert {:ok, evaluated} = validate_entry(schema, data, parent_evaluated_keys)

    assert evaluated ==
             MapSet.union(parent_evaluated_keys, MapSet.new(early_fields ++ late_fields))
  end

  test "allOf and all-failed anyOf retain child error order" do
    branches = [false, %{"type" => "string"}, %{"required" => ["missing"]}]

    for keyword <- ["allOf", "anyOf"] do
      assert {:ok, schema} = JSONSchex.compile(%{keyword => branches})
      assert {:error, errors} = validate_entry(schema, %{})
      assert Enum.map(errors, & &1.rule) == [:boolean_schema, :type, :required]
    end

    assert {:ok, direct_any_of} =
             JSONSchex.compile(%{"anyOf" => branches ++ [false]})

    parent_evaluated_keys = MapSet.new(Enum.map(1..8, &"seed-#{&1}"))
    assert {:error, errors} = validate_entry(direct_any_of, %{}, parent_evaluated_keys)
    assert Enum.map(errors, & &1.rule) == [:boolean_schema, :type, :required, :boolean_schema]
  end

  test "dependentSchemas retains its existing reverse map-traversal error order" do
    assert {:ok, schema} =
             JSONSchex.compile(%{
               "dependentSchemas" => %{
                 "first" => false,
                 "second" => %{"type" => "string"},
                 "third" => %{"required" => ["missing"]}
               }
             })

    [%Rule{name: :dependentSchemas, params: dependencies}] =
      Enum.filter(schema.rules, &(&1.name == :dependentSchemas))

    expected_rules =
      dependencies
      |> Map.to_list()
      |> Enum.map(fn {_trigger, %Schema{rules: [%Rule{name: name} | _]}} -> name end)
      |> Enum.reverse()

    assert {:error, errors} =
             validate_entry(schema, %{"first" => true, "second" => true, "third" => true})

    assert Enum.map(errors, & &1.rule) == expected_rules
  end

  test "anyOf retains its existing list-valued evaluated-key behavior on the direct-merge fallback" do
    assert {:ok, schema} = JSONSchex.compile(%{"anyOf" => [true, true, true, true]})
    parent_evaluated_keys = MapSet.new(Enum.map(1..8, &[&1]))

    assert {:ok, evaluated} = validate_entry(schema, %{}, parent_evaluated_keys)
    assert evaluated == MapSet.union(parent_evaluated_keys, MapSet.new(1..8))
  end

  test "failed allOf and dependentSchemas discard successful child evaluated keys" do
    assert {:ok, all_of_schema} =
             JSONSchex.compile(%{
               "allOf" => [%{"properties" => %{"a" => true}}, false],
               "unevaluatedProperties" => false
             })

    assert {:error, all_of_errors} = JSONSchex.validate(all_of_schema, %{"a" => 1})
    assert Enum.any?(all_of_errors, &(&1.rule == :boolean_schema))
    assert Enum.any?(all_of_errors, &(&1.rule == :unevaluatedProperties and &1.path == ["a"]))

    assert {:ok, dependent_schema} =
             JSONSchex.compile(%{
               "dependentSchemas" => %{
                 "trigger" => %{"properties" => %{"a" => true}},
                 "failure" => false
               },
               "unevaluatedProperties" => false
             })

    data = %{"trigger" => true, "failure" => true, "a" => 1}
    assert {:error, dependent_errors} = JSONSchex.validate(dependent_schema, data)
    assert Enum.any?(dependent_errors, &(&1.rule == :boolean_schema))
    assert Enum.any?(dependent_errors, &(&1.rule == :unevaluatedProperties and &1.path == ["a"]))
  end

  defp validate_entry(schema, data, initial_evaluated_keys \\ MapSet.new())

  defp validate_entry(%Schema{} = schema, data, initial_evaluated_keys) do
    context = %ValidationContext{
      root_schema: schema,
      source_id: schema.source_id,
      raw: schema.raw,
      scope_stack: if(schema.source_id, do: [schema.source_id], else: [])
    }

    JSONSchex.Validator.validate_entry(schema, data, [], context, initial_evaluated_keys)
  end

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

defmodule JSONSchex.Test.ValidatorPatternMatchCacheTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Rule, Schema}

  test "cached classification preserves overlapping pattern diagnostics in both sibling orders" do
    assert {:ok, compiled} =
             JSONSchex.compile(%{
               "patternProperties" => %{
                 "^x-" => %{"type" => "string"},
                 "name$" => %{"minimum" => 2}
               },
               "additionalProperties" => false
             })

    data = %{"x-name" => 1, "other" => true}

    for order <- [[:patternProperties, :additionalProperties], [:additionalProperties, :patternProperties]] do
      cached = reorder_rules(compiled, order)
      uncached = uncached_additional_patterns(cached)
      cached_result = JSONSchex.validate(cached, data)

      assert cached_result === JSONSchex.validate(uncached, data)
      assert {:error, errors} = cached_result
      assert Enum.any?(errors, &(&1.rule == :type and &1.path == ["x-name"]))
      assert Enum.any?(errors, &(&1.rule == :minimum and &1.path == ["x-name"]))
      assert Enum.any?(errors, &(&1.rule == :boolean_schema and &1.path == ["other"]))
      refute Enum.any?(errors, &(&1.rule == :boolean_schema and &1.path == ["x-name"]))
    end
  end

  test "structural matches remain separate from evaluated-property annotations in both sibling orders" do
    assert {:ok, compiled} =
             JSONSchex.compile(%{
               "patternProperties" => %{
                 "^x-" => %{"type" => "string"},
                 "^never-" => true
               },
               "additionalProperties" => true,
               "unevaluatedProperties" => false
             })

    for order <- [[:patternProperties, :additionalProperties], [:additionalProperties, :patternProperties]] do
      cached = reorder_rules(compiled, order)
      uncached = uncached_additional_patterns(cached)
      invalid = %{"x-name" => 1}
      cached_result = JSONSchex.validate(cached, invalid)

      assert cached_result === JSONSchex.validate(uncached, invalid)
      assert {:error, errors} = cached_result
      assert Enum.any?(errors, &(&1.rule == :type and &1.path == ["x-name"]))
      assert Enum.any?(errors, &(&1.rule == :unevaluatedProperties and &1.path == ["x-name"]))

      assert :ok == JSONSchex.validate(cached, %{"x-name" => "ok", "other" => true})
    end
  end

  test "cache selection does not run regex matching ahead of preceding rules" do
    parent = self()

    assert {:ok, compiled} =
             JSONSchex.compile(
               %{
                 "$ref" => "https://example.test/remote.json",
                 "patternProperties" => %{"^x-" => true, "^y-" => true},
                 "additionalProperties" => true
               },
               loader: fn _uri ->
                 send(parent, :runtime_loader_called)
                 {:error, :unavailable}
               end
             )

    refute_received :runtime_loader_called
    schema = reorder_rules(compiled, [:ref, :patternProperties, :additionalProperties])

    assert_raise FunctionClauseError, fn ->
      JSONSchex.validate(schema, %{1 => true})
    end

    assert_received :runtime_loader_called
  end

  test "shared referenced schemas do not transfer failed annotations between object instances" do
    raw_schema = %{
      "$id" => "https://example.test/root.json",
      "$defs" => %{
        "node" => %{
          "$id" => "node.json",
          "patternProperties" => %{
            "^x-" => %{"type" => "string"},
            "^never-" => true
          },
          "additionalProperties" => true,
          "unevaluatedProperties" => false
        }
      },
      "properties" => %{
        "left" => %{"$ref" => "#/$defs/node"},
        "right" => %{"$ref" => "#/$defs/node"}
      }
    }

    assert {:ok, compiled} = JSONSchex.compile(raw_schema)

    assert {:error, errors} =
             JSONSchex.validate(compiled, %{
               "left" => %{"x-name" => 1},
               "right" => %{"x-name" => "ok", "other" => true}
             })

    assert Enum.any?(errors, &(&1.rule == :type and &1.path == ["x-name", "left"]))

    assert Enum.any?(errors, fn error ->
             error.rule == :unevaluatedProperties and error.path == ["x-name", "left"]
           end)

    refute Enum.any?(errors, fn error -> "right" in error.path end)

    assert :ok ==
             JSONSchex.validate(compiled, %{
               "left" => %{"x-name" => "left"},
               "right" => %{"x-name" => "right", "other" => true}
             })
  end

  test "concurrent validations share no match state" do
    assert {:ok, schema} = JSONSchex.compile(runtime_schema(8, true))

    results =
      Task.async_stream(
        1..64,
        fn index ->
          data =
            if rem(index, 2) == 0 do
              %{"pattern-1" => "value", "field" <> Integer.to_string(index) => index}
            else
              %{"pattern-2" => "value"}
            end

          JSONSchex.validate(schema, data)
        end,
        max_concurrency: 8,
        timeout: 5_000,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
  end

  @tag :performance
  test "sibling matching avoids a second full classification pass in reductions" do
    assert {:ok, compiled} = JSONSchex.compile(runtime_schema(128, true))
    cached = reorder_rules(compiled, [:patternProperties, :additionalProperties])
    uncached = uncached_additional_patterns(cached)
    data = Map.new(1..128, fn index -> {"field-" <> Integer.to_string(index), index} end)

    assert :ok == JSONSchex.validate(cached, data)
    assert :ok == JSONSchex.validate(uncached, data)

    cached_work = validation_reductions(cached, data, 10)
    uncached_work = validation_reductions(uncached, data, 10)

    assert cached_work * 100 < uncached_work * 85,
           "cached used #{cached_work} vs uncached #{uncached_work} reductions"
  end

  defp runtime_schema(width, additional_properties) do
    patterns =
      Map.new(1..width, fn index ->
        {"^pattern-" <> Integer.to_string(index) <> "$", %{"type" => "string"}}
      end)

    %{"patternProperties" => patterns, "additionalProperties" => additional_properties}
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

  # Reverse only additionalProperties' regex list. It is equivalent for normal
  # JSON property names because additionalProperties asks only whether any regex
  # matches, but it intentionally fails the runtime cache's exact-sequence gate.
  defp uncached_additional_patterns(%Schema{rules: rules} = schema) do
    updated_rules =
      Enum.map(rules, fn
        %Rule{name: :additionalProperties, params: %{patterns: patterns} = params} = rule ->
          reversed_patterns = Enum.reverse(patterns)

          if reversed_patterns === patterns do
            raise "test requires at least two distinct patternProperties regexes"
          end

          %{rule | params: %{params | patterns: reversed_patterns}}

        rule ->
          rule
      end)

    %{schema | rules: updated_rules}
  end

  defp validation_reductions(schema, data, iterations) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)

    Enum.each(1..iterations, fn _ ->
      :ok = JSONSchex.validate(schema, data)
    end)

    {:reductions, after_validation} = Process.info(self(), :reductions)
    after_validation - before
  end
end

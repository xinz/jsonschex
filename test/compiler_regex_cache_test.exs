defmodule JSONSchex.Test.CompilerRegexCacheTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Error, Schema}

  @draft2020_12 "https://json-schema.org/draft/2020-12/schema"
  @core_vocabulary "https://json-schema.org/draft/2020-12/vocab/core"

  test "sibling rules retain compiled regex order and object validation semantics" do
    schema = %{
      "properties" => %{"fixed" => %{"type" => "integer"}},
      "patternProperties" => %{
        "^x-" => %{"type" => "string"},
        "^count-" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)
    pattern_rule = rule(compiled, :patternProperties)
    additional_rule = rule(compiled, :additionalProperties)
    pattern_regexes = Enum.map(pattern_rule.params, &elem(&1, 0))

    assert Enum.all?(pattern_regexes, &match?(%Regex{}, &1))
    assert pattern_regexes === additional_rule.params.patterns
    assert additional_rule.params.known_props == MapSet.new(["fixed"])
    refute additional_rule.params.always_valid?

    assert :ok ==
             JSONSchex.validate(compiled, %{
               "fixed" => 1,
               "x-name" => "alice",
               "count-total" => 2
             })

    assert {:error, pattern_errors} = JSONSchex.validate(compiled, %{"x-name" => 1})
    assert Enum.any?(pattern_errors, &(&1.rule == :type and &1.path == ["x-name"]))
    refute Enum.any?(pattern_errors, &(&1.rule == :boolean_schema and &1.path == ["x-name"]))

    assert {:error, additional_errors} = JSONSchex.validate(compiled, %{"unmatched" => true})
    assert Enum.any?(additional_errors, &(&1.rule == :boolean_schema and &1.path == ["unmatched"]))
  end

  test "always-valid additionalProperties retains evaluated-property annotations" do
    schema = %{
      "patternProperties" => %{"^x-" => %{"type" => "string"}},
      "additionalProperties" => true,
      "unevaluatedProperties" => false
    }

    assert {:ok, compiled} = JSONSchex.compile(schema)
    assert rule(compiled, :additionalProperties).params.always_valid?

    assert :ok == JSONSchex.validate(compiled, %{"x-name" => "alice", "other" => %{}})
  end

  test "inactive applicator vocabulary does not prepare sibling regexes" do
    schema = %{
      "$schema" => @draft2020_12,
      "$vocabulary" => %{@core_vocabulary => true},
      "patternProperties" => %{"[" => true},
      "additionalProperties" => false
    }

    assert {:ok, %Schema{rules: []}} = JSONSchex.compile(schema)
  end

  test "local definitions still fail before sibling pattern regex preparation" do
    schema = %{
      "$defs" => %{"invalid" => %{"pattern" => "["}},
      "patternProperties" => %{"[" => true},
      "additionalProperties" => false
    }

    assert {:error, %Error{} = error} = JSONSchex.compile(schema)
    assert error.rule == :invalid_regex
    assert error.path == ["$defs", "invalid", "pattern"]
    assert List.starts_with?(error.context.error_detail, ~c"missing terminating ]")
  end

  test "sibling child schema errors retain their existing path contracts" do
    pattern_child_error = %{
      "patternProperties" => %{"^x-" => %{"minLength" => -1}},
      "additionalProperties" => false
    }

    additional_child_error = %{
      "patternProperties" => %{"^x-" => true},
      "additionalProperties" => %{"minLength" => -1}
    }

    assert {:error, %Error{} = pattern_error} = JSONSchex.compile(pattern_child_error)
    assert pattern_error.path == ["minLength", "^x-"]

    assert {:error, %Error{} = additional_error} = JSONSchex.compile(additional_child_error)
    assert additional_error.path == ["minLength"]
  end

  @tag :performance
  test "sibling regex compilation stays near patternProperties-only reductions" do
    patterns_only = wide_pattern_schema(256, false)
    siblings = wide_pattern_schema(256, true)

    # Load compiler and regex machinery before measuring process-local work.
    assert {:ok, _} = JSONSchex.compile(patterns_only)
    assert {:ok, _} = JSONSchex.compile(siblings)

    patterns_only_work = compile_reductions(patterns_only)
    sibling_work = compile_reductions(siblings)

    # The pre-P6 compiler used about 1.8x work here because it compiled every
    # pattern twice. The small allowance covers the additional rule itself.
    assert sibling_work * 100 < patterns_only_work * 145,
           "siblings used #{sibling_work} vs #{patterns_only_work} reductions"
  end

  defp rule(%Schema{rules: rules}, name), do: Enum.find(rules, &(&1.name == name))

  defp wide_pattern_schema(width, additional?) do
    patterns =
      Map.new(1..width, fn index ->
        {Integer.to_string(index) <> "\\p{Letter}\\s", true}
      end)

    schema = %{"patternProperties" => patterns}
    if additional?, do: Map.put(schema, "additionalProperties", true), else: schema
  end

  defp compile_reductions(schema) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)
    assert {:ok, %Schema{}} = JSONSchex.compile(schema)
    {:reductions, after_compile} = Process.info(self(), :reductions)
    after_compile - before
  end
end

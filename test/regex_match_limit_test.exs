defmodule JSONSchex.Test.RegexMatchLimitTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Types.{Error, ErrorContext, Rule, Schema}

  # The final alternative matches these subjects, but the first alternative
  # exhausts PCRE's default match budget before it can reach that alternative.
  @pattern "^(?:(a+)+b|a+!)$"
  @long String.duplicate("a", 25) <> "!"
  @short "aaa!"
  @near_limit String.duplicate("a", 20) <> "!"
  @nonmatch "ordinary"
  @sibling_orders [
    [:patternProperties, :additionalProperties],
    [:additionalProperties, :patternProperties]
  ]

  test "the advisory fixture exhausts the engine rather than returning a genuine nonmatch" do
    regex = Regex.compile!(@pattern)
    options = [:report_errors, {:capture, :none}]

    assert :match == :re.run(@short, Regex.re_pattern(regex), options)
    assert :nomatch == :re.run(@nonmatch, Regex.re_pattern(regex), options)
    assert {:error, reason} = :re.run(@long, Regex.re_pattern(regex), options)
    assert reason in [:match_limit, :match_limit_recursion]
  end

  test "an invalid compiled pattern is not retried by recompiling its source" do
    regex = Regex.compile!("^a$")
    invalid = %{regex | re_pattern: :invalid_compiled_pattern}

    assert_raise ArgumentError, fn ->
      JSONSchex.Validator.Pattern.match?(invalid, "a", [])
    end
  end

  for draft <- ["draft7", "draft2020_12"] do
    describe "#{draft} regex match limits" do
      @describetag draft: draft

      test "pattern reports an indeterminate result without changing ordinary matches", %{draft: draft} do
        schema = compile_schema(%{"pattern" => @pattern}, draft)
        error = assert_indeterminate(schema, @long, [])

        message = JSONSchex.format_error(error)
        assert String.downcase(message) =~ "pattern"
        assert message =~ "match_limit"

        for subject <- [@short, @near_limit, "aaab"] do
          assert :ok == JSONSchex.validate(schema, subject)
        end

        assert_rule_error(schema, @nonmatch, :pattern)
      end

      test "pattern still ignores nonstring instances", %{draft: draft} do
        schema = compile_schema(%{"pattern" => @pattern}, draft)

        for data <- [nil, true, 123, [], %{}] do
          assert :ok == JSONSchex.validate(schema, data)
        end
      end

      test "an engine error aborts instead of being combined with earlier ordinary errors", %{draft: draft} do
        schema =
          %{"type" => "integer", "pattern" => @pattern}
          |> compile_schema(draft)
          |> reorder_rules([:type, :pattern])

        assert_indeterminate(schema, @long, [])
      end

      test "patternProperties alone cannot skip an exhausted matching property name", %{draft: draft} do
        schema =
          compile_schema(
            %{"patternProperties" => %{@pattern => %{"type" => "integer"}}},
            draft
          )

        for value <- [1, "not an int"] do
          assert_indeterminate(schema, %{@long => value}, [@long])
        end

        for key <- [@short, @near_limit] do
          assert :ok == JSONSchex.validate(schema, %{key => 1})
          assert_rule_error(schema, %{key => "not an int"}, :type, [key])
        end

        assert :ok == JSONSchex.validate(schema, %{@nonmatch => "not an int"})
        assert :ok == JSONSchex.validate(schema, @long)
      end

      test "not and repeated not cannot invert an engine error into success", %{draft: draft} do
        for depth <- 1..3 do
          raw =
            Enum.reduce(1..depth, %{"pattern" => @pattern}, fn _, child ->
              %{"not" => child}
            end)

          schema = compile_schema(raw, draft)
          assert_indeterminate(schema, @long, [])

          if rem(depth, 2) == 0 do
            assert :ok == JSONSchex.validate(schema, @short)
            assert_rule_error(schema, @nonmatch, :not)
          else
            assert_rule_error(schema, @short, :not)
            assert :ok == JSONSchex.validate(schema, @nonmatch)
          end
        end
      end

      test "not preserves the instance path of an exhausted nested property name", %{draft: draft} do
        schema =
          compile_schema(
            %{
              "not" => %{
                "properties" => %{
                  "payload" => %{
                    "items" => %{
                      "patternProperties" => %{@pattern => %{"type" => "integer"}}
                    }
                  }
                }
              }
            },
            draft
          )

        data = %{"payload" => [%{@long => "not an int"}]}
        assert_indeterminate(schema, data, [@long, 0, "payload"])
      end

      test "propertyNames reports the name as the subject even through not", %{draft: draft} do
        for name_schema <- [%{"pattern" => @pattern}, %{"not" => %{"pattern" => @pattern}}] do
          schema = compile_schema(%{"propertyNames" => name_schema}, draft)
          assert_indeterminate(schema, %{@long => 123}, [@long])
        end

        schema = compile_schema(%{"propertyNames" => %{"pattern" => @pattern}}, draft)
        assert :ok == JSONSchex.validate(schema, %{@short => 123})
        assert_rule_error(schema, %{@nonmatch => 123}, :pattern, [@nonmatch])
      end

      test "anyOf cannot hide exhaustion behind a successful branch in either order", %{draft: draft} do
        pattern = %{"pattern" => @pattern}

        for branches <- [[true, pattern], [pattern, true]] do
          schema = compile_schema(%{"anyOf" => branches}, draft)
          assert_indeterminate(schema, @long, [])
          assert :ok == JSONSchex.validate(schema, @short)
          assert :ok == JSONSchex.validate(schema, @nonmatch)
        end
      end

      test "oneOf cannot count an exhausted branch as an ordinary failure", %{draft: draft} do
        pattern = %{"pattern" => @pattern}

        for branches <- [[true, pattern], [pattern, true]] do
          schema = compile_schema(%{"oneOf" => branches}, draft)
          assert_indeterminate(schema, @long, [])
          assert :ok == JSONSchex.validate(schema, @nonmatch)
          assert_rule_error(schema, @short, :oneOf)
        end
      end

      test "allOf propagates the indeterminate error without wrapping it", %{draft: draft} do
        schema = compile_schema(%{"allOf" => [%{"pattern" => @pattern}, true]}, draft)
        assert_indeterminate(schema, @long, [])
        assert :ok == JSONSchex.validate(schema, @short)
        assert_rule_error(schema, @nonmatch, :pattern)
      end

      test "if cannot select a successful else branch after an engine error", %{draft: draft} do
        schema =
          compile_schema(
            %{"if" => %{"pattern" => @pattern}, "then" => false, "else" => true},
            draft
          )

        assert_indeterminate(schema, @long, [])
        assert_rule_error(schema, @short, :boolean_schema)
        assert :ok == JSONSchex.validate(schema, @nonmatch)
      end

      test "contains cannot ignore exhaustion even after an earlier successful item", %{draft: draft} do
        schema = compile_schema(%{"contains" => %{"pattern" => @pattern}}, draft)

        for {data, index} <- [{[@long], 0}, {[@short, @long], 1}, {[@long, @short], 0}] do
          assert_indeterminate(schema, data, [index])
        end

        assert :ok == JSONSchex.validate(schema, [@short, @nonmatch])
        assert_rule_error(schema, [@nonmatch], :contains)
      end

      test "cached patternProperties and additionalProperties abort in both sibling orders", %{draft: draft} do
        for additional <- [true, false, %{"type" => "integer"}] do
          compiled = compile_schema(pattern_siblings(additional), draft)

          for order <- @sibling_orders do
            schema = reorder_rules(compiled, order)
            assert_sibling_regression(schema, additional)
          end
        end
      end

      test "uncached patternProperties and additionalProperties abort in both sibling orders", %{draft: draft} do
        for additional <- [true, false, %{"type" => "integer"}] do
          compiled = compile_schema(pattern_siblings(additional), draft)

          for order <- @sibling_orders do
            schema =
              compiled
              |> reorder_rules(order)
              |> uncached_additional_patterns()

            assert_sibling_regression(schema, additional)
          end
        end
      end

      test "the single-pattern single-key uncached path also aborts for every fallback", %{draft: draft} do
        for additional <- [true, false, %{"type" => "integer"}] do
          compiled =
            compile_schema(
              %{
                "patternProperties" => %{@pattern => %{"type" => "integer"}},
                "additionalProperties" => additional
              },
              draft
            )

          for order <- @sibling_orders do
            schema = reorder_rules(compiled, order)
            assert_indeterminate(schema, %{@long => 1}, [@long])
            assert :ok == JSONSchex.validate(schema, %{@short => 1})
          end
        end
      end

      test "a cached earlier match cannot suppress exhaustion in a later pattern", %{draft: draft} do
        schema =
          %{
            "patternProperties" => %{
              "^a" => true,
              @pattern => %{"type" => "integer"}
            },
            "additionalProperties" => false
          }
          |> compile_schema(draft)
          |> reorder_patterns(["^a", @pattern])
          |> reorder_rules([:additionalProperties, :patternProperties])

        # additionalProperties stops at ^a. patternProperties must still test
        # the later regex rather than treating the first match as sufficient.
        assert_indeterminate(schema, %{@long => "not an int"}, [@long])
        assert :ok == JSONSchex.validate(schema, %{@short => 1})
        assert_rule_error(schema, %{@short => "not an int"}, :type, [@short])
      end

      test "declared properties do not bypass patternProperties with or without caching", %{draft: draft} do
        compiled =
          compile_schema(
            %{
              "properties" => %{@long => true, @short => true},
              "patternProperties" => %{
                @pattern => %{"type" => "integer"},
                "^safe$" => true
              },
              "additionalProperties" => false
            },
            draft
          )

        # The undeclared safe key makes the second object cache-eligible while
        # avoiding an unrelated additionalProperties failure.
        for data <- [%{@long => "not an int"}, %{@long => "not an int", "safe" => 1}],
            order <- @sibling_orders do
          schema = reorder_rules(compiled, order)
          assert_indeterminate(schema, data, [@long])
          assert_rule_error(schema, %{@short => "not an int"}, :type, [@short])
        end
      end

      test "cached property matching keeps the full reversed instance path", %{draft: draft} do
        schema =
          compile_schema(
            %{"properties" => %{"payload" => %{"items" => pattern_siblings(true)}}},
            draft
          )

        data = %{"payload" => [%{@long => "not an int"}]}
        assert_indeterminate(schema, data, [@long, 0, "payload"])
      end

      test "referenced patterns report the scalar path and abort earlier ordinary failures", %{draft: draft} do
        definitions = if draft == "draft7", do: "definitions", else: "$defs"

        schema =
          compile_schema(
            %{
              definitions => %{"bounded" => %{"pattern" => @pattern}},
              "properties" => %{
                "payload" => %{"items" => %{"$ref" => "#/" <> definitions <> "/bounded"}}
              }
            },
            draft
          )

        assert_indeterminate(schema, %{"payload" => [@nonmatch, @long]}, [1, "payload"])
        assert :ok == JSONSchex.validate(schema, %{"payload" => [@short]})
        assert_rule_error(schema, %{"payload" => [@nonmatch]}, :pattern, [0, "payload"])
      end
    end
  end

  test "draft2020_12 contains bounds do not turn exhaustion into a match-count decision" do
    for bounds <- [
          %{"minContains" => 0},
          %{"minContains" => 0, "maxContains" => 0},
          %{"minContains" => 1, "maxContains" => 1},
          %{"minContains" => 2, "maxContains" => 2}
        ] do
      schema =
        bounds
        |> Map.put("contains", %{"pattern" => @pattern})
        |> compile_schema("draft2020_12")

      # With maxContains: 0, put the exhausted item first so the engine is
      # actually reached before any legitimate over-maximum short circuit.
      data = if bounds["maxContains"] == 0, do: [@long], else: [@short, @long]
      index = if bounds["maxContains"] == 0, do: 0, else: 1
      assert_indeterminate(schema, data, [index])
    end
  end

  defp compile_schema(raw, draft) do
    assert {:ok, %Schema{} = schema} = JSONSchex.compile(raw, draft: draft)
    schema
  end

  defp assert_indeterminate(schema, data, path) do
    assert {:error, [%Error{} = error]} = JSONSchex.validate(schema, data)
    assert error.rule == :indeterminate_pattern
    assert error.path == path
    assert error.value == @long

    assert %ErrorContext{
             contrast: %Regex{} = regex,
             input: @long,
             error_detail: reason
           } = error.context

    assert Regex.source(regex) == @pattern
    assert reason in [:match_limit, :match_limit_recursion]
    error
  end

  defp assert_rule_error(schema, data, rule, path \\ []) do
    assert {:error, [%Error{rule: ^rule, path: ^path}]} = JSONSchex.validate(schema, data)
  end

  defp pattern_siblings(additional) do
    %{
      "patternProperties" => %{
        @pattern => %{"type" => "integer"},
        "^never-" => true
      },
      "additionalProperties" => additional
    }
  end

  defp assert_sibling_regression(schema, additional) do
    assert_indeterminate(schema, %{@long => "not an int"}, [@long])
    assert :ok == JSONSchex.validate(schema, %{@short => 1})
    assert_rule_error(schema, %{@short => "not an int"}, :type, [@short])

    case additional do
      true ->
        assert :ok == JSONSchex.validate(schema, %{@nonmatch => "not an int"})

      false ->
        assert_rule_error(schema, %{@nonmatch => "not an int"}, :boolean_schema, [@nonmatch])

      %{} ->
        assert_rule_error(schema, %{@nonmatch => "not an int"}, :type, [@nonmatch])
    end
  end

  defp reorder_rules(%Schema{rules: rules} = schema, names) do
    selected =
      Enum.map(names, fn name ->
        assert %Rule{} = rule = Enum.find(rules, &(&1.name == name))
        rule
      end)

    %{schema | rules: selected ++ Enum.reject(rules, &(&1.name in names))}
  end

  defp reorder_patterns(%Schema{rules: rules} = schema, sources) do
    ranks = sources |> Enum.with_index() |> Map.new()
    rank = fn regex -> Map.fetch!(ranks, Regex.source(regex)) end

    rules =
      Enum.map(rules, fn
        %Rule{name: :patternProperties, params: patterns} = rule ->
          %{rule | params: Enum.sort_by(patterns, fn {regex, _schema} -> rank.(regex) end)}

        %Rule{name: :additionalProperties, params: %{patterns: patterns} = params} = rule ->
          %{rule | params: %{params | patterns: Enum.sort_by(patterns, rank)}}

        rule ->
          rule
      end)

    %{schema | rules: rules}
  end

  # Reverse only additionalProperties' regexes, preserving ordinary semantics
  # while disabling the cache's exact-sequence gate for these two-pattern tests.
  defp uncached_additional_patterns(%Schema{rules: rules} = schema) do
    rules =
      Enum.map(rules, fn
        %Rule{name: :additionalProperties, params: %{patterns: patterns} = params} = rule ->
          reversed = Enum.reverse(patterns)
          refute reversed === patterns, "test requires at least two distinct regexes"
          %{rule | params: %{params | patterns: reversed}}

        rule ->
          rule
      end)

    %{schema | rules: rules}
  end
end

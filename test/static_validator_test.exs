defmodule JSONSchex.Test.StaticValidatorTest do
  use ExUnit.Case, async: true

  defmodule SampleValidators do
    require JSONSchex.Schema

    JSONSchex.Schema.defvalidator :validate_user,
      %{
        "type" => "object",
        "required" => ["id", "name", "age", "active"],
        "additionalProperties" => false,
        "properties" => %{
          "id" => %{"type" => "integer", "minimum" => 1},
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 10},
          "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
          "active" => %{"type" => "boolean"},
          "role" => %{"enum" => ["admin", "user", "guest"]},
          "slug" => %{"type" => "string", "pattern" => "^[a-z0-9_-]+$"},
          "uuid" => %{"type" => "string", "format" => "uuid"}
        }
      },
      format_assertion: true

    JSONSchex.Schema.defvalidator :valid_batch?, %{
      "type" => "array",
      "minItems" => 1,
      "items" => %{
        "type" => "object",
        "required" => ["sku", "qty", "price"],
        "properties" => %{
          "sku" => %{"type" => "string", "minLength" => 1},
          "qty" => %{"type" => "integer", "minimum" => 1},
          "price" => %{"type" => "number", "minimum" => 0}
        }
      }
    }

    JSONSchex.Schema.defvalidator :validate_combinators, %{
      "allOf" => [
        %{"type" => "object"},
        %{
          "anyOf" => [
            %{"required" => ["a"], "properties" => %{"a" => %{"type" => "integer"}}},
            %{"required" => ["b"], "properties" => %{"b" => %{"type" => "string"}}}
          ]
        },
        %{
          "oneOf" => [
            %{"properties" => %{"tier" => %{"const" => 1}}},
            %{"properties" => %{"tier" => %{"const" => 2}}}
          ]
        },
        %{"not" => %{"properties" => %{"banned" => %{"const" => true}}, "required" => ["banned"]}}
      ]
    }

    # A local loader makes it observable whether oneOf visits its last branch.
    def load_last(uri) do
      send(self(), {:loaded_branch, uri})
      {:ok, %{"type" => "string"}}
    end

    JSONSchex.Schema.defvalidator :match_one?,
      %{"oneOf" => [%{"type" => "integer"}, %{"const" => 1}, %{"$ref" => "https://example.test/last"}]},
      loader: &__MODULE__.load_last/1

    # Hybrid fallback: uses $ref and unevaluatedProperties
    JSONSchex.Schema.defvalidator :validate_hybrid_ref, %{
      "$defs" => %{
        "node" => %{
          "type" => "object",
          "required" => ["val"],
          "properties" => %{
            "val" => %{"type" => "integer"},
            "next" => %{"$ref" => "#/$defs/node"}
          }
        }
      },
      "$ref" => "#/$defs/node"
    }

    JSONSchex.Schema.defvalidator :validate_hybrid_uneval, %{
      "anyOf" => [
        %{"properties" => %{"a" => %{"type" => "integer"}}},
        %{"properties" => %{"b" => %{"type" => "string"}}}
      ],
      "unevaluatedProperties" => false
    }

    JSONSchex.Schema.defvalidator :validate_numeric_enum, %{
      "enum" => [1, "two", true]
    }
  end

  defmodule SigilAndUseValidators do
    use JSONSchex

    defvalidator :validate_email, %{"type" => "string", "format" => "email"}, format_assertion: true

    @user_schema ~X|%{
      "type" => "object",
      "required" => ["id", "name"],
      "properties" => %{
        "id" => %{"type" => "integer", "minimum" => 1},
        "name" => %{"type" => "string", "minLength" => 1}
      }
    }|
    defvalidator :validate_attr_user, @user_schema

    defvalidator :validate_fragment_name,
      JSONSchex.Schema.compile_fragment!(
        %{
          "components" => %{"schemas" => %{"Name" => %{"type" => "string", "minLength" => 2}}},
          "schema" => %{"$ref" => "#/components/schemas/Name"}
        },
        entry: "#/schema"
      )
  end

  test "validate_user/1 and validate_user?/1 handle valid, optional, UTF-8, format, and error diagnostics" do
    valid = %{
      "id" => 1,
      "name" => "Alice",
      "age" => 30,
      "active" => true,
      "role" => "admin",
      "slug" => "alice-01",
      "uuid" => "550e8400-e29b-41d4-a716-446655440000"
    }

    assert SampleValidators.validate_user?(valid)
    assert :ok == SampleValidators.validate_user(valid)

    # Integral float is a valid JSON Schema integer
    assert :ok == SampleValidators.validate_user(%{valid | "id" => 1.0, "age" => 30.0})

    # Multi-byte UTF-8: 4 codepoints (12 bytes > maxLength 10 bytes, but <= 10 codepoints!)
    assert :ok == SampleValidators.validate_user(%{valid | "name" => "你好世界"})
    # 11 codepoints exceeds maxLength 10
    assert {:error, [%{rule: :maxLength, path: ["name"]}]} =
             SampleValidators.validate_user(%{valid | "name" => "你好世界你好世界你好世"})

    # Invalid UTF-8 rejected (reports invalid_utf8 for both minLength and maxLength)
    assert {:error, errors} = SampleValidators.validate_user(%{valid | "name" => <<0xFF>>})
    assert Enum.any?(errors, &(&1.rule == :minLength and &1.path == ["name"]))
    assert Enum.any?(errors, &(&1.rule == :maxLength and &1.path == ["name"]))

    # Invalid age returns full structured error on fallback
    refute SampleValidators.validate_user?(%{valid | "age" => -5})
    assert {:error, [%{rule: :minimum, path: ["age"]}]} =
             SampleValidators.validate_user(%{valid | "age" => -5})

    # Additional property rejected
    assert {:error, [%{rule: :boolean_schema, path: ["extra"]}]} =
             SampleValidators.validate_user(Map.put(valid, "extra", 123))

    # Invalid format rejected
    assert {:error, [%{rule: :format, path: ["uuid"]}]} =
             SampleValidators.validate_user(%{valid | "uuid" => "not-a-uuid"})
  end

  test "question-mark name generates boolean predicate only" do
    assert function_exported?(SampleValidators, :valid_batch?, 1)
    refute function_exported?(SampleValidators, :valid_batch, 1)

    assert SampleValidators.valid_batch?([%{"sku" => "A1", "qty" => 2, "price" => 9.99}])
    refute SampleValidators.valid_batch?([])
    refute SampleValidators.valid_batch?([%{"sku" => "A1", "qty" => 0, "price" => 9.99}])
  end

  test "combinators (allOf, anyOf, oneOf, not) work accurately" do
    assert :ok == SampleValidators.validate_combinators(%{"a" => 1, "tier" => 1})
    assert :ok == SampleValidators.validate_combinators(%{"b" => "hi", "tier" => 2})

    # Neither a nor b present
    refute SampleValidators.validate_combinators?(%{"tier" => 1})
    # tier matches both oneOf branches when tier is omitted!
    refute SampleValidators.validate_combinators?(%{"a" => 1})
    # banned: true fails `not`
    refute SampleValidators.validate_combinators?(%{"a" => 1, "tier" => 1, "banned" => true})
  end

  test "oneOf visits branches in order and stops after the second match" do
    refute SampleValidators.match_one?(1)
    refute_received {:loaded_branch, _}
    assert SampleValidators.match_one?(2)
    assert_received {:loaded_branch, "https://example.test/last"}
    assert SampleValidators.match_one?("last")
    refute SampleValidators.match_one?(nil)
  end

  test "doubling oneOf branches grows generated code at most linearly" do
    size = fn width ->
      branches = Enum.map(1..width, &%{"const" => &1})
      {:ok, schema} = JSONSchex.compile(%{"oneOf" => branches})
      {body, helpers, _} = JSONSchex.StaticCompiler.compile(:choice?, schema)
      {_, nodes} = Macro.prewalk([body | helpers], 0, fn node, n -> {node, n + 1} end)
      nodes
    end

    assert size.(8) <= 2 * size.(4)
  end

  test "hybrid fallback preserves $ref and unevaluatedProperties semantics" do
    assert :ok == SampleValidators.validate_hybrid_ref(%{"val" => 1, "next" => %{"val" => 2}})
    assert {:error, [%{rule: :type, path: ["val", "next"]}]} =
             SampleValidators.validate_hybrid_ref(%{"val" => 1, "next" => %{"val" => "bad"}})

    assert :ok == SampleValidators.validate_hybrid_uneval(%{"a" => 1, "b" => "ok"})
    assert {:error, [%{rule: :unevaluatedProperties, path: ["c"]}]} =
             SampleValidators.validate_hybrid_uneval(%{"a" => 1, "b" => "ok", "c" => true})
  end

  test "numeric enum preserves JSON numeric equality (1 == 1.0)" do
    assert SampleValidators.validate_numeric_enum?(1)
    assert SampleValidators.validate_numeric_enum?(1.0)
    assert SampleValidators.validate_numeric_enum?("two")
    refute SampleValidators.validate_numeric_enum?(2)
  end

  test "use JSONSchex integrates ~X sigil, module attributes, and compile_fragment!/2 with defvalidator" do
    assert SigilAndUseValidators.validate_email?("ada@example.com")
    assert :ok == SigilAndUseValidators.validate_email("ada@example.com")
    assert {:error, [%{rule: :format}]} = SigilAndUseValidators.validate_email("not-an-email")

    assert SigilAndUseValidators.validate_attr_user?(%{"id" => 1, "name" => "Ada"})
    assert :ok == SigilAndUseValidators.validate_attr_user(%{"id" => 1, "name" => "Ada"})

    assert {:error, [%{rule: :minimum, path: ["id"]}]} =
             SigilAndUseValidators.validate_attr_user(%{"id" => 0, "name" => "Ada"})

    assert SigilAndUseValidators.validate_fragment_name?("Ada")
    assert :ok == SigilAndUseValidators.validate_fragment_name("Ada")
    assert {:error, [%{rule: :minLength}]} = SigilAndUseValidators.validate_fragment_name("A")
  end

  test "defvalidator rejects options when passed an already-compiled ~X schema" do
    assert_raise CompileError, ~r/does not accept options when given an already-compiled schema/, fn ->
      Code.compile_string("""
      defmodule InvalidDefvalidatorOpts do
        use JSONSchex
        defvalidator :bad, ~X|%{"type" => "string"}|, format_assertion: true
      end
      """)
    end
  end
end

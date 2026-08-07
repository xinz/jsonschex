defmodule JSONSchex.Test.MultipleOfDecimalTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias JSONSchex.Compiler.Predicates.MultipleOf

  test "checks large integer multiples exactly" do
    refute MultipleOf.valid?(20_606_440_141_923_986_926_444_292_610, 67_471)
    assert MultipleOf.valid?(15_241_578_751_714_678_875_142_508_889, 123_456_789)
  end

  test "supports negative instances" do
    assert MultipleOf.valid?(-6, 3)
    refute MultipleOf.valid?(-7, 3)
  end

  test "rejects zero and negative divisors" do
    assert MultipleOf.valid?(6, 3)
    refute MultipleOf.valid?(6, 0)
    refute MultipleOf.valid?(6, -3)
  end

  test "validates arbitrary-precision integers through the schema API" do
    large_multiple = Integer.pow(10, 100)

    {:ok, one_schema} = JSONSchex.compile(%{"multipleOf" => 1})
    assert :ok = JSONSchex.validate(one_schema, large_multiple)

    {:ok, three_schema} = JSONSchex.compile(%{"multipleOf" => 3})
    assert {:error, [error]} = JSONSchex.validate(three_schema, large_multiple + 1)
    assert error.rule == :multipleOf
  end

  test "compares decimal coefficients and exponents without expanding powers of ten" do
    assert MultipleOf.valid?(D.new("1.2"), D.new("0.03"))
    assert MultipleOf.valid?(D.new("1200"), D.new("3e2"))
    refute MultipleOf.valid?(D.new("1.20000000000000000001"), D.new("0.03"))
    refute MultipleOf.valid?(D.new("1200"), D.new("3e3"))

    assert MultipleOf.valid?(D.new(1, 1, 1_000_000), D.new(1, 1, -1_000_000))
    refute MultipleOf.valid?(D.new(1, 1, -1_000_000), D.new(1))
  end

  test "rejects non-finite Decimal values before arithmetic" do
    for non_finite <- [%D{coef: :inf}, %D{coef: :NaN}] do
      refute MultipleOf.valid?(non_finite, D.new(1))
      refute MultipleOf.valid?(D.new(1), non_finite)
    end
  end
end

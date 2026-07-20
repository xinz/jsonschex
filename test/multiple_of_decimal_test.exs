defmodule JSONSchex.Test.MultipleOfDecimalTest do
  use ExUnit.Case, async: true
  alias JSONSchex.Compiler.Predicates.MultipleOf

  describe "valid?/2 Decimal implementation" do
    test "does not round a large non-multiple into a match" do
      refute MultipleOf.valid?(20_606_440_141_923_986_926_444_292_610, 67_471)
    end

    test "does not reject a large exact multiple" do
      assert MultipleOf.valid?(15_241_578_751_714_678_875_142_508_889, 123_456_789)
    end

    test "supports large integer divisibility checks" do
      assert MultipleOf.valid?(Integer.pow(10, 100), 1)
      refute MultipleOf.valid?(Integer.pow(10, 100) + 1, 3)
    end

    test "compares decimal coefficients and exponents exactly" do
      assert MultipleOf.valid?(Decimal.new("1.2"), Decimal.new("0.03"))
      assert MultipleOf.valid?(Decimal.new("1200"), Decimal.new("3e2"))
      refute MultipleOf.valid?(Decimal.new("1.20000000000000000001"), Decimal.new("0.03"))
      refute MultipleOf.valid?(Decimal.new("1200"), Decimal.new("3e3"))
    end

    test "does not expand hostile exponent differences" do
      assert MultipleOf.valid?(Decimal.new(1, 1, 1_000_000), Decimal.new(1, 1, -1_000_000))
      refute MultipleOf.valid?(Decimal.new(1, 1, -1_000_000), Decimal.new(1))
    end

    test "matches exact rational divisibility across coefficient and exponent combinations" do
      for coefficient <- [0, 1, 2, 3, 5, 7, 10, 21, 125],
          divisor <- [1, 2, 3, 5, 6, 10, 25, 70],
          instance_exp <- -4..4,
          divisor_exp <- -4..4 do
        shift = instance_exp - divisor_exp

        expected =
          if shift >= 0 do
            rem(coefficient * Integer.pow(10, shift), divisor) == 0
          else
            rem(coefficient, divisor * Integer.pow(10, -shift)) == 0
          end

        instance = Decimal.new(1, coefficient, instance_exp)
        multiple_of = Decimal.new(1, divisor, divisor_exp)
        assert MultipleOf.valid?(instance, multiple_of) == expected
      end
    end
  end
end

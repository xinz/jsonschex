defmodule JSONSchex.Test.MultipleOfNativeTest do
  use ExUnit.Case, async: true
  alias JSONSchex.Compiler.Predicates.MultipleOf.Native

  describe "valid?/2 native fallback" do
    test "raises useful error on arithmetic overflow" do
      # Case: 1.0e308 / 0.3 causes overflow (Infinity)
      instance = 1.0e308
      divisor = 0.3

      error = assert_raise ArithmeticError, fn ->
        Native.valid?(instance, divisor)
      end

      assert error.message =~ "Arithmetic error checking multipleOf"
      assert error.message =~ "Please add {:decimal, \"~> 2.0\"}"

      # Case: 1.0e308 / 0.5 causes overflow (Infinity)
      # Since we removed the heuristic, this must now raise and ask for Decimal
      assert_raise ArithmeticError, fn ->
        Native.valid?(1.0e308, 0.5)
      end
    end

    test "handles standard valid cases" do
      assert Native.valid?(10, 5)
      assert Native.valid?(10.0, 5.0)
      assert Native.valid?(10.5, 0.5)
    end

    test "handles standard invalid cases" do
      refute Native.valid?(10, 3)
      refute Native.valid?(10.5, 0.4)
    end

    test "handles zero divisor" do
      refute Native.valid?(10, 0)
      refute Native.valid?(10, 0.0)
    end
  end
end
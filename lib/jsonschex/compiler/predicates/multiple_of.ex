defmodule JSONSchex.Compiler.Predicates.MultipleOf do
  @moduledoc """
  Validates numbers against the JSON Schema `multipleOf` rule.
  Handles arbitrary precision if `Decimal` is available.
  Falls back to native arithmetic with overflow protection if not.
  """

  defmodule Native do
    @moduledoc false

    @spec valid?(number(), number()) :: boolean()
    def valid?(_instance, 0), do: false
    def valid?(_instance, +0.0), do: false

    def valid?(instance, divisor) when is_number(instance) and is_number(divisor) do
      quotient = instance / divisor
      diff = abs(quotient - round(quotient))
      diff < 1.0e-9
    rescue
      ArithmeticError ->
        raise_missing_decimal_error(instance, divisor)
    end

    def valid?(_, _), do: false

    defp raise_missing_decimal_error(instance, divisor) do
      raise ArithmeticError,
        message:
          "Arithmetic error checking multipleOf(#{inspect(instance)}, #{inspect(divisor)}) with native arithmetic. " <>
            "Please add {:decimal, \"~> 3.0\"} to your dependencies to handle arbitrary precision."
    end
  end

  if Code.ensure_loaded?(Decimal) do
    alias Decimal, as: D

    @doc """
    Checks if `instance` is a multiple of `divisor`.
    Uses `Decimal` for high precision.
    """
    @spec valid?(number() | String.t() | D.t(), number() | String.t() | D.t()) :: boolean()
    def valid?(instance, divisor) do
      d_instance = to_decimal(instance)
      d_divisor = to_decimal(divisor)

      if finite_decimal?(d_instance) and finite_decimal?(d_divisor) and D.gt?(d_divisor, 0) do
        exact_multiple?(d_instance, d_divisor)
      else
        false
      end
    end

    # A finite Decimal is `coefficient * 10 ^ exponent`. Checking that their
    # quotient is an integer avoids Decimal context rounding and quotient limits.
    defp exact_multiple?(%D{coef: coefficient_i, exp: exponent_i}, %D{coef: coefficient_d, exp: exponent_d}) do
      case exponent_i - exponent_d do
        shift when shift >= 0 ->
          remaining_divisor = div(coefficient_d, Integer.gcd(coefficient_i, coefficient_d))
          divides_power_of_ten?(remaining_divisor, shift)

        shift ->
          rem(coefficient_i, coefficient_d) == 0 and
            divisible_by_power_of_ten?(div(coefficient_i, coefficient_d), -shift)
      end
    end

    defp finite_decimal?(%D{coef: coefficient, exp: exponent})
         when is_integer(coefficient) and coefficient >= 0 and is_integer(exponent),
         do: true

    defp finite_decimal?(_), do: false

    defp divides_power_of_ten?(1, _shift), do: true

    defp divides_power_of_ten?(divisor, shift) do
      {remaining, twos} = factor_out(divisor, 2, 0)
      {remaining, fives} = factor_out(remaining, 5, 0)

      remaining == 1 and twos <= shift and fives <= shift
    end

    defp divisible_by_power_of_ten?(0, _shift), do: true
    defp divisible_by_power_of_ten?(_coefficient, 0), do: true

    defp divisible_by_power_of_ten?(coefficient, shift) when rem(coefficient, 10) == 0 do
      divisible_by_power_of_ten?(div(coefficient, 10), shift - 1)
    end

    defp divisible_by_power_of_ten?(_coefficient, _shift), do: false

    defp factor_out(value, factor, count) when rem(value, factor) == 0 do
      factor_out(div(value, factor), factor, count + 1)
    end

    defp factor_out(value, _factor, count), do: {value, count}

    defp to_decimal(%D{} = val), do: val
    defp to_decimal(val) when is_integer(val), do: D.new(val)
    defp to_decimal(val) when is_binary(val), do: D.new(val)
    defp to_decimal(val) when is_float(val), do: D.from_float(val)
  else
    @doc """
    Checks if `instance` is a multiple of `divisor`.
    Uses native arithmetic with overflow handling.
    """
    defdelegate valid?(instance, divisor), to: Native
  end
end

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
            "Please add {:decimal, \"~> 2.0\"} to your dependencies to handle arbitrary precision."
    end
  end

  if Code.ensure_loaded?(Decimal) do
    alias Decimal, as: D

    @precision_buffer 28

    @doc """
    Checks if `instance` is a multiple of `divisor`.
    Uses `Decimal` for high precision.
    """
    @spec valid?(number() | String.t() | D.t(), number() | String.t() | D.t()) :: boolean()
    def valid?(instance, divisor) do
      d_instance = to_decimal(instance)
      d_divisor = to_decimal(divisor)

      if D.gt?(d_divisor, 0) do
        check_remainder_valid?(d_instance, d_divisor)
      else
        false
      end
    end

    defp check_remainder_valid?(instance, divisor) do
      required_precision = calculate_needed_precision(instance, divisor)

      D.Context.with(%D.Context{precision: required_precision}, fn ->
        remainder = D.rem(instance, divisor)
        D.eq?(remainder, 0)
      end)
    end

    defp calculate_needed_precision(%D{exp: exp_i}, %D{exp: exp_d}) do
      estimated_digits = abs(exp_i - exp_d)
      max(estimated_digits + @precision_buffer, 28)
    end

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

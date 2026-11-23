defmodule JSONSchex.Guards do
  @moduledoc """
  Shared byte and JSON-type guard macros for format, pattern, and rule validators.

  All guards compile directly to BEAM guard instructions with zero runtime overhead.

  ## Examples

      iex> import JSONSchex.Guards
      iex> is_ascii_digit?(?5)
      true
      iex> is_ascii_hex?(?F)
      true
      iex> is_ascii_word?(?_)
      true
      iex> is_ascii_printable?(?~)
      true
      iex> is_ascii_printable?(?\\n)
      false
  """

  @json_types ~w(string integer number boolean object array null)

  @doc """
  Returns `true` if `c` is an ASCII decimal digit (`0`..`9`).
  """
  defguard is_ascii_digit?(c) when c in ?0..?9

  @doc """
  Returns `true` if `c` is an ASCII hexadecimal digit (`0`..`9`, `a`..`f`, `A`..`F`).
  """
  defguard is_ascii_hex?(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  @doc """
  Returns `true` if `c` is an ASCII ECMA-262 word character (`a`..`z`, `A`..`Z`, `0`..`9`, `_`).
  """
  defguard is_ascii_word?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  @doc """
  Returns `true` if `c` is a printable ASCII byte (`0x20`..`0x7E`, excluding control characters and DEL).
  """
  defguard is_ascii_printable?(c) when is_integer(c) and c >= 0x20 and c < 0x7F

  @doc false
  @spec json_types() :: [String.t()]
  def json_types, do: @json_types

  @doc false
  @spec type_check_ast(String.t(), Macro.t()) :: Macro.t()
  def type_check_ast("string", var), do: quote(do: is_binary(unquote(var)))

  def type_check_ast("integer", var) do
    quote do: is_integer(unquote(var)) or (is_float(unquote(var)) and unquote(var) == trunc(unquote(var)))
  end

  def type_check_ast("number", var), do: quote(do: is_number(unquote(var)))
  def type_check_ast("boolean", var), do: quote(do: is_boolean(unquote(var)))
  def type_check_ast("object", var), do: quote(do: is_map(unquote(var)))
  def type_check_ast("array", var), do: quote(do: is_list(unquote(var)))
  def type_check_ast("null", var), do: quote(do: is_nil(unquote(var)))
end

defmodule JSONSchex.Guards do
  @moduledoc """
  Shared ASCII byte guard macros for binary pattern matching in format and pattern validators.

  All guards operate on integer byte values (such as those matched directly from a binary)
  and compile directly to BEAM guard instructions with zero runtime overhead.

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
end

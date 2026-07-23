defmodule JSONSchex.Formats.IP do
  @moduledoc """
  Validates `ipv4` and `ipv6` formats.
  """

  @doc """
  Validates an IPv4 address in dotted-decimal notation.

  Rejects leading zeros (e.g., "01.02.03.04"), values > 255,
  and non-numeric characters. Uses pure binary pattern matching
  for maximum performance — no regex, no String.split, no String.to_integer.
  """
  @spec valid_ipv4?(binary()) :: boolean()
  def valid_ipv4?(data) when is_binary(data), do: parse_ipv4(data, 4)
  def valid_ipv4?(_), do: false

  defp parse_ipv4(data, 1), do: match?({:ok, <<>>}, parse_octet_start(data))

  defp parse_ipv4(data, remaining_octets) do
    case parse_octet_start(data) do
      {:ok, <<?., rest::binary>>} -> parse_ipv4(rest, remaining_octets - 1)
      _ -> false
    end
  end

  # Parse the start of an octet — handles leading-zero rejection.
  # Returns {:ok, rest} where rest is the remaining binary after the octet,
  # or :error if the octet is invalid.
  @compile {:inline, parse_octet_start: 1}
  defp parse_octet_start(<<>>), do: :error

  # Single "0" is valid; "0" followed by another digit is a leading zero (invalid).
  defp parse_octet_start(<<?0, d, _::binary>>) when d in ?0..?9, do: :error
  defp parse_octet_start(<<?0, rest::binary>>), do: {:ok, rest}

  # Four or more digits are never a valid octet.
  defp parse_octet_start(<<d1, d2, d3, d4, _::binary>>)
       when d1 in ?1..?9 and d2 in ?0..?9 and d3 in ?0..?9 and d4 in ?0..?9,
       do: :error

  # Three-digit octets must be no greater than 255.
  defp parse_octet_start(<<d1, d2, d3, rest::binary>>)
       when d1 in ?1..?9 and d2 in ?0..?9 and d3 in ?0..?9 do
    if (d1 - ?0) * 100 + (d2 - ?0) * 10 + (d3 - ?0) <= 255 do
      {:ok, rest}
    else
      :error
    end
  end

  # One- and two-digit non-zero-prefixed octets are always in range.
  defp parse_octet_start(<<d1, d2, rest::binary>>) when d1 in ?1..?9 and d2 in ?0..?9,
    do: {:ok, rest}

  defp parse_octet_start(<<d1, rest::binary>>) when d1 in ?1..?9, do: {:ok, rest}

  defp parse_octet_start(_), do: :error

  @doc """
  Validates an IPv6 address using Erlang's `:inet.parse_ipv6_address/1`.

  Rejects addresses containing a zone ID (`%`), which is not allowed
  by the JSON Schema specification.
  """
  @spec valid_ipv6?(binary()) :: boolean()
  def valid_ipv6?(data) when is_binary(data) do
    if String.contains?(data, ":") and not String.contains?(data, "%") do
      case :inet.parse_ipv6_address(String.to_charlist(data)) do
        {:ok, _} -> true
        _ -> false
      end
    else
      false
    end
  end

  def valid_ipv6?(_), do: false
end
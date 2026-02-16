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
  def valid_ipv4?(data) when is_binary(data) do
    case parse_octet_start(data) do
      {:ok, <<?., rest1::binary>>} ->
        case parse_octet_start(rest1) do
          {:ok, <<?., rest2::binary>>} ->
            case parse_octet_start(rest2) do
              {:ok, <<?., rest3::binary>>} ->
                match?({:ok, <<>>}, parse_octet_start(rest3))

              _ ->
                false
            end

          _ ->
            false
        end

      _ ->
        false
    end
  end

  def valid_ipv4?(_), do: false

  # Parse the start of an octet — handles leading-zero rejection.
  # Returns {:ok, rest} where rest is the remaining binary after the octet,
  # or :error if the octet is invalid.
  @compile {:inline, parse_octet_start: 1}
  defp parse_octet_start(<<>>), do: :error

  # Single "0" is valid; "0" followed by another digit is a leading zero (invalid).
  defp parse_octet_start(<<?0, d, _::binary>>) when d in ?0..?9, do: :error
  defp parse_octet_start(<<?0, rest::binary>>), do: {:ok, rest}

  # 1-digit: 1..9
  defp parse_octet_start(<<d1, rest::binary>>) when d1 in ?1..?9 do
    case rest do
      # 3-digit: check d1 d2 d3 <= 255
      <<d2, d3, rest2::binary>> when d2 in ?0..?9 and d3 in ?0..?9 ->
        value = (d1 - ?0) * 100 + (d2 - ?0) * 10 + (d3 - ?0)

        if value <= 255 do
          # Ensure the next char is not a digit (no 4+ digit octets)
          case rest2 do
            <<d, _::binary>> when d in ?0..?9 -> :error
            _ -> {:ok, rest2}
          end
        else
          :error
        end

      # 2-digit: 10..99 (always valid, d1 in 1..9 and d2 in 0..9)
      <<d2, rest2::binary>> when d2 in ?0..?9 ->
        {:ok, rest2}

      # 1-digit: 1..9
      _ ->
        {:ok, rest}
    end
  end

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
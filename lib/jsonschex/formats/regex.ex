defmodule JSONSchex.Formats.Regex do
  @moduledoc """
  Validates `regex` format according to strict ECMA-262.
  """

  # Permitted escape characters in strict ECMA-262:
  # - Syntax characters: ^ $ \ . * + ? ( ) [ ] { } | /
  # - Control/Meta chars: b B c d D f k n p P r s S t u v w W x
  # - Digits: 0-9
  # - Dash: - (Allowed in character classes)
  @regex_escapes ~c"^$\\.*+?()[]{}|/bBcdDfkmnpPrsStuvwWx0123456789-"

  def valid?(data) do
    # Strict ECMA-262 validation:
    # Validate that every escape sequence (odd backslashes followed by a char)
    # uses a permitted character.
    has_invalid_escape =
      Regex.scan(~r/(?<!\\)(?:\\\\)*\\(.)/s, data)
      |> Enum.any?(fn [_, <<c::utf8>>] ->
        invalid_regex_escape?(c)
      end)

    if has_invalid_escape do
      false
    else
      case Regex.compile(data) do
        {:ok, _} -> true
        _ -> false
      end
    end
  end

  defp invalid_regex_escape?(char) when char not in @regex_escapes, do: true
  defp invalid_regex_escape?(_), do: false
end
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
    # PCRE accepts syntax that ECMA-262 forbids and rejects valid ECMA-262 constructs
    # such as empty character classes and variable-width lookbehind. Compile a validation
    # shadow instead of the original expression to retain PCRE's structural checks.
    with {:ok, shadow} <- validation_shadow(data, :normal, []),
         {:ok, _} <- Regex.compile(shadow) do
      true
    else
      _ -> false
    end
  end

  defp validation_shadow(<<>>, :normal, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp validation_shadow(<<>>, :class, _acc), do: :error

  defp validation_shadow(<<?\\, rest::binary>>, context, acc) do
    case rest do
      <<char::utf8, rest::binary>> when char in @regex_escapes ->
        validation_shadow(rest, context, [<<?\\, char::utf8>> | acc])

      _ ->
        :error
    end
  end

  defp validation_shadow(<<?], rest::binary>>, :class, acc) do
    validation_shadow(rest, :normal, ["]" | acc])
  end

  defp validation_shadow(<<char::utf8, rest::binary>>, :class, acc) do
    validation_shadow(rest, :class, [<<char::utf8>> | acc])
  end

  # `[]` never matches, while `[^]` matches every character in ECMA-262.
  defp validation_shadow(<<"[]", rest::binary>>, :normal, acc) do
    validation_shadow(rest, :normal, ["[^\\s\\S]" | acc])
  end

  defp validation_shadow(<<"[^]", rest::binary>>, :normal, acc) do
    validation_shadow(rest, :normal, ["[\\s\\S]" | acc])
  end

  # PCRE restricts lookbehind width; lookahead gives us an equivalent structural check.
  defp validation_shadow(<<"(?<=", rest::binary>>, :normal, acc) do
    validation_shadow(rest, :normal, ["(?=" | acc])
  end

  defp validation_shadow(<<"(?<!", rest::binary>>, :normal, acc) do
    validation_shadow(rest, :normal, ["(?!" | acc])
  end

  defp validation_shadow(<<"(?", rest::binary>>, :normal, acc) do
    case rest do
      <<char::utf8, _::binary>> when char in [?: , ?=, ?!, ?<] ->
        validation_shadow(rest, :normal, ["(?" | acc])

      _ ->
        :error
    end
  end

  defp validation_shadow(<<?[, rest::binary>>, :normal, acc) do
    validation_shadow(rest, :class, ["[" | acc])
  end

  defp validation_shadow(<<char::utf8, rest::binary>>, :normal, acc) do
    validation_shadow(rest, :normal, [<<char::utf8>> | acc])
  end
end

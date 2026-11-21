defmodule JSONSchex.PredefinedPattern do
  @moduledoc """
  Binary matchers for predefined shapes of JSON Schema `pattern` expressions.

  The shapes, not the literals, are predefined: exact, prefix, suffix and
  substring matches, and anchored repetitions of a positive ASCII character class.
  `compile/1` recognizes these shapes; it does not validate regex syntax. The
  schema compiler first compiles the regex and retains it for fallback and diagnostics.
  """

  import JSONSchex.Guards,
    only: [is_ascii_digit?: 1, is_ascii_hex?: 1, is_ascii_word?: 1, is_ascii_printable?: 1]

  @digit_chars Enum.to_list(?0..?9)
  @word_chars Enum.concat([?a..?z, ?A..?Z, @digit_chars, [?_]])

  @digit_set MapSet.new(@digit_chars)
  @hex_set MapSet.new(Enum.concat([@digit_chars, ?a..?f, ?A..?F]))
  @word_set MapSet.new(@word_chars)

  @type matcher ::
          {:exact, binary()}
          | {:prefix, binary()}
          | {:suffix, binary()}
          | {:contains, binary()}
          | {:ascii_class, :digit | :hex | :word | tuple(), non_neg_integer(), non_neg_integer() | :infinity}

  @doc """
  Returns an embeddable matcher, or `nil` when the original regex must be used.

      iex> matcher = JSONSchex.PredefinedPattern.compile("^x-api-")
      iex> JSONSchex.PredefinedPattern.match?(matcher, "x-api-version")
      true
      iex> JSONSchex.PredefinedPattern.compile("^(yes|no)$")
      nil
  """
  @spec compile(String.t()) :: matcher() | nil
  def compile(""), do: {:contains, ""}
  def compile(<<"^", rest::binary>>), do: compile_anchored_start(rest)
  def compile(source) when is_binary(source), do: compile_unanchored_start(source)
  def compile(_), do: nil

  @doc "Matches a binary against a descriptor returned by `compile/1`."
  @spec match?(matcher(), binary()) :: boolean()
  def match?({:exact, literal}, subject) do
    subject === literal or
      (byte_size(subject) == byte_size(literal) + 1 and
         :binary.last(subject) == ?\n and
         binary_part(subject, 0, byte_size(literal)) == literal)
  end

  def match?({:prefix, prefix}, subject), do: String.starts_with?(subject, prefix)

  def match?({:suffix, suffix}, subject) do
    String.ends_with?(subject, suffix) or
      (byte_size(subject) > byte_size(suffix) and
         :binary.last(subject) == ?\n and
         binary_part(subject, byte_size(subject) - byte_size(suffix) - 1, byte_size(suffix)) == suffix)
  end

  def match?({:contains, ""}, _subject), do: true
  def match?({:contains, literal}, subject), do: :binary.match(subject, literal) != :nomatch

  def match?({:ascii_class, class, min, :infinity}, subject) do
    {len, body} = strip_trailing_newline(subject)
    len >= min and match_class_all?(body, class)
  end

  def match?({:ascii_class, class, min, max}, subject) do
    {len, body} = strip_trailing_newline(subject)
    len >= min and len <= max and match_class_all?(body, class)
  end

  @compile {:inline, strip_trailing_newline: 1}
  defp strip_trailing_newline(<<>>), do: {0, <<>>}

  defp strip_trailing_newline(subject) do
    len = byte_size(subject)

    if :binary.last(subject) == ?\n do
      {len - 1, binary_part(subject, 0, len - 1)}
    else
      {len, subject}
    end
  end

  # --- ASCII character-class matching ---

  defp match_class_all?(<<>>, _class), do: true

  defp match_class_all?(<<c1, c2, c3, c4, rest::binary>>, :digit)
       when is_ascii_digit?(c1) and is_ascii_digit?(c2) and is_ascii_digit?(c3) and is_ascii_digit?(c4),
       do: match_class_all?(rest, :digit)

  defp match_class_all?(<<c, rest::binary>>, :digit) when is_ascii_digit?(c),
    do: match_class_all?(rest, :digit)

  defp match_class_all?(<<c1, c2, c3, c4, rest::binary>>, :hex)
       when is_ascii_hex?(c1) and is_ascii_hex?(c2) and is_ascii_hex?(c3) and is_ascii_hex?(c4),
       do: match_class_all?(rest, :hex)

  defp match_class_all?(<<c, rest::binary>>, :hex) when is_ascii_hex?(c),
    do: match_class_all?(rest, :hex)

  defp match_class_all?(<<c1, c2, c3, c4, rest::binary>>, :word)
       when is_ascii_word?(c1) and is_ascii_word?(c2) and is_ascii_word?(c3) and is_ascii_word?(c4),
       do: match_class_all?(rest, :word)

  defp match_class_all?(<<c, rest::binary>>, :word) when is_ascii_word?(c),
    do: match_class_all?(rest, :word)

  defp match_class_all?(<<c1, c2, c3, c4, rest::binary>>, table)
       when is_tuple(table) and c1 < 128 and c2 < 128 and c3 < 128 and c4 < 128 do
    if elem(table, c1) and elem(table, c2) and elem(table, c3) and elem(table, c4) do
      match_class_all?(rest, table)
    else
      false
    end
  end

  defp match_class_all?(<<c, rest::binary>>, table) when is_tuple(table) and c < 128 do
    if elem(table, c), do: match_class_all?(rest, table), else: false
  end

  defp match_class_all?(_, _), do: false

  # --- Compile-time pattern recognizers ---

  defp compile_anchored_start("$"), do: {:exact, ""}

  # Anchored shorthand classes: ^\d+$, ^\d{4}$, ^\w+$, etc.
  defp compile_anchored_start(<<"\\d", rest::binary>>) do
    compile_class_quantifier(:digit, rest)
  end

  defp compile_anchored_start(<<"\\w", rest::binary>>) do
    compile_class_quantifier(:word, rest)
  end

  # Anchored bracketed ASCII character class: ^[a-z0-9_-]+$, ^[0-9a-f]{32}$, etc.
  # Explicitly reject negated classes `[^...]` because they match multi-byte Unicode.
  defp compile_anchored_start(<<"[^", _::binary>>), do: nil

  defp compile_anchored_start(<<"[", rest::binary>>) do
    case parse_ascii_class(rest, []) do
      {:ok, chars, after_bracket} when chars != [] ->
        class = build_class_matcher(chars)
        compile_class_quantifier(class, after_bracket)

      _ ->
        nil
    end
  end

  defp compile_anchored_start(rest) do
    case parse_ascii_literal(rest, [], true) do
      {:ok, literal, :end_anchor} -> {:exact, literal}
      {:ok, literal, :eof} when literal != "" -> {:prefix, literal}
      _ -> nil
    end
  end

  defp compile_unanchored_start(source) do
    case parse_ascii_literal(source, [], true) do
      {:ok, literal, :end_anchor} when literal != "" -> {:suffix, literal}
      {:ok, literal, :eof} when literal != "" -> {:contains, literal}
      _ -> nil
    end
  end

  defp compile_class_quantifier(class, "+$"), do: {:ascii_class, class, 1, :infinity}
  defp compile_class_quantifier(class, "*$"), do: {:ascii_class, class, 0, :infinity}
  defp compile_class_quantifier(class, "?$"), do: {:ascii_class, class, 0, 1}
  defp compile_class_quantifier(class, "$"), do: {:ascii_class, class, 1, 1}

  defp compile_class_quantifier(class, <<"{", rest::binary>>) do
    case parse_brace_quantifier(rest) do
      {:ok, min, max} -> {:ascii_class, class, min, max}
      :error -> nil
    end
  end

  defp compile_class_quantifier(_, _), do: nil

  defp parse_brace_quantifier(bin) do
    case parse_uint(bin, 0, false) do
      {:ok, n, "}$"} ->
        {:ok, n, n}

      {:ok, min, <<",}$">>} ->
        {:ok, min, :infinity}

      {:ok, min, <<",", rest::binary>>} ->
        case parse_uint(rest, 0, false) do
          {:ok, max, "}$"} when min <= max -> {:ok, min, max}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_uint(<<d, rest::binary>>, acc, _seen) when is_ascii_digit?(d) do
    parse_uint(rest, acc * 10 + (d - ?0), true)
  end

  defp parse_uint(rest, acc, true), do: {:ok, acc, rest}
  defp parse_uint(_, _, false), do: :error

  # Parses plain ASCII literal characters (and safe escaped punctuation) until
  # optional trailing `$` or end of string. Bails out on any regex metacharacter.
  defp parse_ascii_literal(<<>>, acc, _allow_dollar) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), :eof}
  end

  defp parse_ascii_literal("$", acc, true) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), :end_anchor}
  end

  defp parse_ascii_literal(<<"\\", c, rest::binary>>, acc, allow_dollar)
       when c in [?., ?-, ?_, ?/, ?\\, ?:, ?+] do
    parse_ascii_literal(rest, [c | acc], allow_dollar)
  end

  defp parse_ascii_literal(<<c, rest::binary>>, acc, allow_dollar)
       when is_ascii_printable?(c) and
              c not in [?^, ?$, ?\\, ?., ?*, ?+, ??, ?(, ?), ?[, ?], ?{, ?}, ?|] do
    parse_ascii_literal(rest, [c | acc], allow_dollar)
  end

  defp parse_ascii_literal(_, _, _), do: :error

  # Parses an ASCII bracketed character class body until `]`.
  # Supports single ASCII chars, `a-z` ranges, safe escapes, `\d`, and `\w`.
  defp parse_ascii_class(<<"]", rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_ascii_class(source, acc) do
    # Decode an endpoint before looking for a range: `\.-z` starts at a dot,
    # whereas a shorthand such as `\d` is a set, not a single endpoint.
    case take_class_atom(source) do
      {:ok, chars, <<"-]", rest::binary>>} ->
        {:ok, [?- | chars] ++ acc, rest}

      {:ok, [first], <<?-, rest::binary>>} ->
        case take_class_atom(rest) do
          {:ok, [last], tail} when first <= last ->
            parse_ascii_class(tail, Enum.to_list(first..last) ++ acc)

          _ ->
            :error
        end

      {:ok, _set, <<?-, _::binary>>} ->
        :error

      {:ok, chars, rest} ->
        parse_ascii_class(rest, chars ++ acc)

      :error ->
        :error
    end
  end

  defp take_class_atom(<<"\\d", rest::binary>>), do: {:ok, @digit_chars, rest}
  defp take_class_atom(<<"\\w", rest::binary>>), do: {:ok, @word_chars, rest}

  defp take_class_atom(<<"\\", c, rest::binary>>) when c in [?-, ?\\, ?], ?[, ?/, ?., ?_, ?+],
    do: {:ok, [c], rest}

  defp take_class_atom(<<c, rest::binary>>) when is_ascii_printable?(c) and c not in [?[, ?], ?\\],
    do: {:ok, [c], rest}

  defp take_class_atom(_), do: :error

  defp build_class_matcher(chars) do
    unique = MapSet.new(chars)

    cond do
      unique == @digit_set -> :digit
      unique == @hex_set -> :hex
      unique == @word_set -> :word

      true ->
        0..127
        |> Enum.map(&MapSet.member?(unique, &1))
        |> List.to_tuple()
    end
  end
end

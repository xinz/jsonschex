defmodule JSONSchex.Validator.Pattern do
  @moduledoc false

  import JSONSchex.Guards,
    only: [is_ascii_digit?: 1, is_ascii_hex?: 1, is_ascii_word?: 1, is_ascii_printable?: 1]

  alias JSONSchex.Types.{Error, ErrorContext}

  @run_options [:report_errors, {:capture, :none}]

  @type fast_matcher ::
          {:exact, binary()}
          | {:prefix, binary()}
          | {:suffix, binary()}
          | {:contains, binary()}
          | {:ascii_class, :digit | :hex | :word | tuple(), non_neg_integer(), non_neg_integer() | :infinity}

  @doc false
  @spec match?(Regex.t(), String.t(), list()) :: boolean()
  def match?(%Regex{re_pattern: compiled} = regex, subject, path) when is_binary(subject) do
    case :re.run(subject, compiled, @run_options) do
      :match ->
        true

      :nomatch ->
        false

      {:error, reason} ->
        # Only the public validation boundary catches this tag. An ordinary
        # validation error could be inverted by not or ignored by a combinator.
        throw({__MODULE__,
               %Error{
                 path: path,
                 rule: :indeterminate_pattern,
                 value: subject,
                 context: %ErrorContext{contrast: regex, input: subject, error_detail: reason}
               }})
    end
  end

  @doc false
  @spec compile_fast(String.t()) :: fast_matcher() | nil
  def compile_fast(""), do: {:contains, ""}
  def compile_fast(<<"^", rest::binary>>), do: compile_anchored_start(rest)
  def compile_fast(source) when is_binary(source) do
    compile_unanchored_start(source)
  end
  def compile_fast(_), do: nil

  @doc false
  @spec match_fast?(fast_matcher(), binary()) :: boolean()
  def match_fast?({:exact, literal}, subject) do
    subject === literal or
      (byte_size(subject) == byte_size(literal) + 1 and
         :binary.last(subject) == ?\n and
         binary_part(subject, 0, byte_size(literal)) == literal)
  end

  def match_fast?({:prefix, prefix}, subject), do: String.starts_with?(subject, prefix)

  def match_fast?({:suffix, suffix}, subject) do
    String.ends_with?(subject, suffix) or
      (byte_size(subject) > byte_size(suffix) and
         :binary.last(subject) == ?\n and
         binary_part(subject, byte_size(subject) - byte_size(suffix) - 1, byte_size(suffix)) == suffix)
  end

  def match_fast?({:contains, ""}, _subject), do: true
  def match_fast?({:contains, literal}, subject), do: :binary.match(subject, literal) != :nomatch

  def match_fast?({:ascii_class, class, min, :infinity}, subject) do
    {len, body} = strip_trailing_newline(subject)
    len >= min and match_class_all?(body, class)
  end

  def match_fast?({:ascii_class, class, min, max}, subject) do
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

  # --- Fast-path matcher execution loops ---

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
  defp parse_ascii_class(<<>>, _acc), do: :error

  defp parse_ascii_class(<<"\\d", rest::binary>>, acc) do
    parse_ascii_class(rest, Enum.to_list(?0..?9) ++ acc)
  end

  defp parse_ascii_class(<<"\\w", rest::binary>>, acc) do
    word_chars = Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ Enum.to_list(?0..?9) ++ [?_]
    parse_ascii_class(rest, word_chars ++ acc)
  end

  defp parse_ascii_class(<<"\\", c, rest::binary>>, acc)
       when c in [?-, ?\\, ?], ?[, ?/, ?., ?_, ?+] do
    parse_ascii_class(rest, [c | acc])
  end

  defp parse_ascii_class(<<"\\", _::binary>>, _acc), do: :error

  # Range `a-z` (printable ASCII only so `\n` is never inside the class)
  defp parse_ascii_class(<<c1, ?-, c2, rest::binary>>, acc)
       when is_ascii_printable?(c1) and is_ascii_printable?(c2) and c1 <= c2 and
              c2 != ?] and c2 != ?\\ do
    parse_ascii_class(rest, Enum.to_list(c1..c2) ++ acc)
  end

  # Literal `-` at the end before `]`
  defp parse_ascii_class(<<"-]", rest::binary>>, acc) do
    {:ok, [?- | acc], rest}
  end

  defp parse_ascii_class(<<c, rest::binary>>, acc)
       when is_ascii_printable?(c) and c != ?[ do
    parse_ascii_class(rest, [c | acc])
  end

  defp parse_ascii_class(_, _), do: :error

  defp build_class_matcher(chars) do
    unique = chars |> MapSet.new()

    cond do
      unique == MapSet.new(?0..?9) ->
        :digit

      unique == MapSet.new(Enum.to_list(?0..?9) ++ Enum.to_list(?a..?f) ++ Enum.to_list(?A..?F)) ->
        :hex

      unique ==
          MapSet.new(Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z) ++ Enum.to_list(?0..?9) ++ [?_]) ->
        :word

      true ->
        0..127
        |> Enum.map(&MapSet.member?(unique, &1))
        |> List.to_tuple()
    end
  end
end

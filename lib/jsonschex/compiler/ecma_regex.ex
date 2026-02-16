defmodule JSONSchex.Compiler.ECMARegex do
  @moduledoc """
  Handles compilation of ECMA-262 regular expressions for use in Elixir/PCRE.

  The current implementation targets coverage of the optional `ecmascript-regex.json` test suite
  of draft2020-12. Be aware that some ECMA-262 syntax features may not be fully supported
  or perfectly translatable to PCRE.

  This module normalizes ECMA-262 regex features (like property names) to PCRE equivalents
  and expands whitespace shorthands to match ECMA-262 definitions while maintaining
  ASCII semantics for other character classes where required.

  Unicode General Category (gc) mappings are derived from the
  [Unicode Property Value Aliases](https://unicode.org/Public/UCD/latest/ucd/PropertyValueAliases.txt).
  """

  @property_map Map.new([
    {"Other", "C"},
    {"Control", "Cc"},
    {"cntrl", "Cc"},
    {"Format", "Cf"},
    {"Unassigned", "Cn"},
    {"Private_Use", "Co"},
    {"Surrogate", "Cs"},
    {"Letter", "L"},
    {"Cased_Letter", "Lc"},
    {"LC", "Lc"},
    {"Lowercase_Letter", "Ll"},
    {"Modifier_Letter", "Lm"},
    {"Other_Letter", "Lo"},
    {"Titlecase_Letter", "Lt"},
    {"Uppercase_Letter", "Lu"},
    {"Mark", "M"},
    {"Combining_Mark", "M"},
    {"Spacing_Mark", "Mc"},
    {"Enclosing_Mark", "Me"},
    {"Nonspacing_Mark", "Mn"},
    {"Number", "N"},
    {"Decimal_Number", "Nd"},
    {"digit", "Nd"},
    {"Letter_Number", "Nl"},
    {"Other_Number", "No"},
    {"Punctuation", "P"},
    {"punct", "P"},
    {"Connector_Punctuation", "Pc"},
    {"Dash_Punctuation", "Pd"},
    {"Close_Punctuation", "Pe"},
    {"Final_Punctuation", "Pf"},
    {"Initial_Punctuation", "Pi"},
    {"Other_Punctuation", "Po"},
    {"Open_Punctuation", "Ps"},
    {"Symbol", "S"},
    {"Currency_Symbol", "Sc"},
    {"Modifier_Symbol", "Sk"},
    {"Math_Symbol", "Sm"},
    {"Other_Symbol", "So"},
    {"Separator", "Z"},
    {"Line_Separator", "Zl"},
    {"Paragraph_Separator", "Zp"},
    {"Space_Separator", "Zs"}
  ])

  @doc """
  Compiles a regex string with ECMA-262 compatibility adjustments.

  Returns `{:ok, Regex.t()}` or `{:error, term}`.

  ## Examples

      iex> {:ok, regex} = JSONSchex.Compiler.ECMARegex.compile("\\p{Letter}")
      iex> Regex.match?(regex, "a")
      true

      iex> {:ok, regex} = JSONSchex.Compiler.ECMARegex.compile("\\p{Script=Latin}")
      iex> Regex.match?(regex, "a")
      true

      iex> {:ok, regex} = JSONSchex.Compiler.ECMARegex.compile("[^]")
      iex> Regex.match?(regex, "\\n")
      true

      iex> {:ok, regex} = JSONSchex.Compiler.ECMARegex.compile(~S"a\\/b")
      iex> Regex.match?(regex, "a/b")
      true
  """
  def compile(pattern) do
    pattern = transform_ecma_pattern(pattern)

    # ECMA-262 whitespace (\s) includes Unicode separators (Zs), \t, \n, \r, \v (\x0B), \f, and \uFEFF.
    # PCRE \s (without (*UCP)) only matches ASCII whitespace.
    # We avoid (*UCP) because it makes \w match Unicode letters, which violates ECMA-262 (where \w is ASCII).
    # So we manually expand \s and \S.
    expanded_pattern = expand_ecma_whitespace(pattern, false, <<>>)

    Regex.compile(expanded_pattern, [:unicode])
  end

  defp transform_ecma_pattern(pattern) do
    Regex.replace(~r/\\\/|\[\^\]|\\([pP])\{([^}]+)\}/, pattern, fn
      "\\/", _, _ ->
        "/"

      "[^]", _, _ ->
        "[\\s\\S]"

      _, p_flag, content ->
        content =
          case content do
            "Script=" <> name -> name
            "sc=" <> name -> name
            _ -> content
          end

        short_code = Map.get(@property_map, content, content)
        "\\#{p_flag}{#{short_code}}"
    end)
  end

  defp expand_ecma_whitespace("", _, acc), do: acc

  defp expand_ecma_whitespace(<<?\\, ?s, rest::binary>>, true, acc) do
    r = "\\p{Zs}\\t\\n\\r\\x0B\\f\\x{FEFF}\\x{2028}\\x{2029}"
    expand_ecma_whitespace(rest, true, acc <> r)
  end
  defp expand_ecma_whitespace(<<?\\, ?s, rest::binary>>, false, acc) do
    r = "[\\p{Zs}\\t\\n\\r\\x0B\\f\\x{FEFF}\\x{2028}\\x{2029}]"
    expand_ecma_whitespace(rest, false, acc <> r)
  end
  defp expand_ecma_whitespace(<<?\\, ?S, rest::binary>>, true, acc) do
    expand_ecma_whitespace(rest, true, acc <> "\\S")
  end
  defp expand_ecma_whitespace(<<?\\, ?S, rest::binary>>, false, acc) do
    r = "[^\\p{Zs}\\t\\n\\r\\x0B\\f\\x{FEFF}\\x{2028}\\x{2029}]"
    expand_ecma_whitespace(rest, false, acc <> r)
  end
  defp expand_ecma_whitespace(<<?\\, ?\\, rest::binary>>, in_class, acc) do
    expand_ecma_whitespace(rest, in_class, acc <> "\\\\")
  end
  defp expand_ecma_whitespace(<<?\\, c, rest::binary>>, in_class, acc) do
    expand_ecma_whitespace(rest, in_class, acc <> <<?\\, c>>)
  end

  defp expand_ecma_whitespace(<<?\[, rest::binary>>, _in_class, acc) do
    expand_ecma_whitespace(rest, true, acc <> "[")
  end

  defp expand_ecma_whitespace(<<?], rest::binary>>, _in_class, acc) do
    expand_ecma_whitespace(rest, false, acc <> "]")
  end

  defp expand_ecma_whitespace(<<c, rest::binary>>, in_class, acc) do
    expand_ecma_whitespace(rest, in_class, acc <> <<c>>)
  end
end

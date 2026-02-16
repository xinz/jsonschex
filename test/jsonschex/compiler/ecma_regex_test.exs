defmodule JSONSchex.Compiler.ECMARegexTest do
  use ExUnit.Case, async: true
  alias JSONSchex.Compiler.ECMARegex

  describe "compile/1" do
    test "property name expansion" do
      cases = [
        {"\\p{Letter}", "a", true},
        {"\\p{Letter}", "1", false},
        {"\\p{L}", "a", true},
        {"\\p{digit}", "1", true},
        {"\\p{digit}", "a", false},
        {"\\p{Decimal_Number}", "1", true},
        {"\\p{Space_Separator}", " ", true},
        {"\\p{Zs}", " ", true},
        {"\\p{Zs}", "\u00A0", true}, # NBSP
        {"\\P{Decimal_Number}", "a", true},
        {"\\P{Decimal_Number}", "1", false},
        {"\\p{Other_Punctuation}", "!", true},
        {"\\p{Po}", "!", true}
      ]

      for {pattern, input, expected} <- cases do
        assert {:ok, regex} = ECMARegex.compile(pattern)
        assert Regex.match?(regex, input) == expected,
               "Pattern '#{pattern}' failed on input '#{input}'. Expected: #{expected}"
      end
    end

    test "Script property stripping" do
      # \p{Script=Latin} -> \p{Latin}
      {:ok, regex} = ECMARegex.compile("\\p{Script=Latin}")
      assert Regex.match?(regex, "a")
      refute Regex.match?(regex, "α") # Greek

      {:ok, regex} = ECMARegex.compile("\\p{Script=Greek}")
      assert Regex.match?(regex, "α")
      refute Regex.match?(regex, "a")

      # \P{Script=Latin} -> \P{Latin}
      {:ok, regex} = ECMARegex.compile("\\P{Script=Latin}")
      assert Regex.match?(regex, "α")
      refute Regex.match?(regex, "a")
    end

    test "Match all [^] replacement" do
      # [^] -> [\s\S]
      {:ok, regex} = ECMARegex.compile("[^]")
      assert Regex.match?(regex, "\n")
      assert Regex.match?(regex, "a")
      assert Regex.match?(regex, " ")
    end

    test "Forward slash unescaping" do
      # \/ -> /
      {:ok, regex} = ECMARegex.compile("a\\/b")
      assert Regex.match?(regex, "a/b")
      
      # Should also work inside classes if needed, though mostly for pattern delimiters
      {:ok, regex} = ECMARegex.compile("[a\\/b]")
      assert Regex.match?(regex, "/")
    end

    test "ECMA whitespace \s expansion" do
      # \s matches many things in ECMA
      {:ok, regex} = ECMARegex.compile("^\\s$")
      
      # Standard ASCII
      assert Regex.match?(regex, " ")
      assert Regex.match?(regex, "\t")
      assert Regex.match?(regex, "\n")
      assert Regex.match?(regex, "\r")
      assert Regex.match?(regex, "\f")
      assert Regex.match?(regex, "\v") # \x0B
      
      # Unicode
      assert Regex.match?(regex, "\u00A0") # NBSP
      assert Regex.match?(regex, "\uFEFF") # ZWNBSP / BOM
      assert Regex.match?(regex, "\u2028") # Line Separator
      assert Regex.match?(regex, "\u2029") # Paragraph Separator
      assert Regex.match?(regex, "\u1680") # Ogham Space Mark (in Zs)
      
      # \S should match non-whitespace
      {:ok, regex_S} = ECMARegex.compile("^\\S$")
      refute Regex.match?(regex_S, " ")
      refute Regex.match?(regex_S, "\u2028")
      assert Regex.match?(regex_S, "a")
    end

    test "ECMA whitespace inside character classes" do
      {:ok, regex} = ECMARegex.compile("^[\\s]$")
      assert Regex.match?(regex, " ")
      assert Regex.match?(regex, "\u2028")
      
      {:ok, regex} = ECMARegex.compile("^[^\\s]$")
      refute Regex.match?(regex, " ")
      assert Regex.match?(regex, "a")
      
      # Mixed with other chars
      {:ok, regex} = ECMARegex.compile("^[a\\sc]$")
      assert Regex.match?(regex, "a")
      assert Regex.match?(regex, "c")
      assert Regex.match?(regex, " ")
    end

    test "invalid regex returns error" do
      assert {:error, _} = ECMARegex.compile("([a-z]")
    end
  end
end

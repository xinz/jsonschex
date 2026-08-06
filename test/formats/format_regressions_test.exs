defmodule JSONSchex.Formats.RegressionTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Formats
  alias JSONSchex.Formats.URITemplate

  test "regex format follows ECMA-262 rather than PCRE extensions" do
    for pattern <- ["(?<n>a)\\k<n>", "(?<=a+)b", "[]", "[^]", "\\cA"] do
      assert :ok = Formats.validate("regex", pattern), "Expected valid ECMA-262 regex: #{inspect(pattern)}"
    end

    for pattern <- ["(?P<name>x)", "(?P<n>a)(?P=n)", "(?#comment)a", "(?i)abc", "(?ims)abc"] do
      assert {:error, _} = Formats.validate("regex", pattern),
             "Expected invalid ECMA-262 regex: #{inspect(pattern)}"
    end
  end

  test "format grammars require complete input" do
    assert {:error, _} = Formats.validate("duration", "P1D\n")
    assert {:error, _} = Formats.validate("uuid", "2eb8aa08-aa98-11ea-b4aa-73b441d16380\n")
    assert {:error, _} = Formats.validate("relative-json-pointer", "1\n")
  end

  test "date-time requires an RFC 3339 numeric offset" do
    assert :ok = Formats.validate("date-time", "1985-04-12T23:20:50+01:00")
    assert {:error, _} = Formats.validate("date-time", "1985-04-12T23:20:50+01")
  end

  test "URI template prefix modifiers are one to four digits and non-zero" do
    assert URITemplate.valid?("{v:9999}")
    refute URITemplate.valid?("{v:0}")
    refute URITemplate.valid?("{v:10000}")
  end
end

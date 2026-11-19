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

  test "uuid binary validation accepts uppercase/lowercase hex and rejects malformed inputs" do
    assert :ok = Formats.validate("uuid", "550e8400-e29b-41d4-a716-446655440000")
    assert :ok = Formats.validate("uuid", "550E8400-E29B-41D4-A716-446655440000")
    assert {:error, _} = Formats.validate("uuid", "550e8400-e29b-41d4-a716-44665544000g")
    assert {:error, _} = Formats.validate("uuid", "550e8400e29b41d4a716446655440000")
    assert {:error, _} = Formats.validate("uuid", "550e8400-e29b-41d4-a716-44665544000")
    assert {:error, _} = Formats.validate("uuid", "550e8400-e29b-41d4-a716-4466554400000")
  end

  test "duration binary validation enforces RFC 3339 Appendix A unit ordering" do
    for valid <- ["P3W", "P1Y", "P1Y2M3D", "P1Y2M3DT4H5M6S", "PT30M", "PT1H2M3S", "P2DT4H"] do
      assert :ok = Formats.validate("duration", valid), "Expected valid duration: #{valid}"
    end

    for invalid <- ["P", "PT", "P1Y2D", "PT1H2S", "P1W2D", "P1DT", "P-1D", "P1.5D"] do
      assert {:error, _} = Formats.validate("duration", invalid),
             "Expected invalid duration: #{invalid}"
    end
  end

  test "date-time and time binary validation handle leap years, offsets, and leap seconds" do
    for valid <- [
          "2024-02-29T12:00:00Z",
          "2000-02-29t12:00:00.123z",
          "1990-12-31T23:59:60Z",
          "1990-12-31T15:59:60-08:00",
          "1990-12-31T00:59:60+01:00",
          "2020-01-01T00:00:00-00:00"
        ] do
      assert :ok = Formats.validate("date-time", valid), "Expected valid date-time: #{valid}"
    end

    for invalid <- [
          "1900-02-29T12:00:00Z",
          "2023-02-29T12:00:00Z",
          "2020-04-31T12:00:00Z",
          "2020-01-01T23:59:60+01:00",
          "2020-01-01T22:59:60Z",
          "2020-01-01T12:00:00.Z",
          "2020-01-01T12:00:00+24:00",
          "2020-01-01T12:00:00+00:60"
        ] do
      assert {:error, _} = Formats.validate("date-time", invalid),
             "Expected invalid date-time: #{invalid}"
    end

    assert :ok = Formats.validate("time", "23:59:60Z")
    assert :ok = Formats.validate("time", "15:59:60-08:00")
    assert :ok = Formats.validate("time", "00:00:00-00:00")
    assert {:error, _} = Formats.validate("time", "12:00:00,5Z")
    assert {:error, _} = Formats.validate("time", "22:59:60Z")
  end

  test "uri percent-encoding binary validation rejects incomplete or non-hex escapes" do
    assert :ok = Formats.validate("uri", "https://example.com/a%20b%2Fc")
    assert {:error, _} = Formats.validate("uri", "https://example.com/a%2")
    assert {:error, _} = Formats.validate("uri", "https://example.com/a%ZZ")
    assert {:error, _} = Formats.validate("uri", "https://example.com/a%")
  end
end

defmodule JSONSchex.Formats.URITemplateTest do
  use ExUnit.Case
  alias JSONSchex.Formats.URITemplate
  alias JSONSchex.JSON

  @negative_tests_file "test/fixtures/uritemplate-test/negative-tests.json"
  @spec_tests_file "test/fixtures/uritemplate-test/spec-examples.json"

  test "accepts RFC6570 ASCII literals and percent encodings" do
    for template <- [
          "",
          "!#$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~",
          "a%20b",
          "%00%7f%FF",
          "%2f%2F%C3%A9",
          "/caf%C3%A9/{name}?q=%20",
          "%FF{value}%00",
          "'{var}'"
        ] do
      assert URITemplate.valid?(template), "Expected valid template: #{inspect(template)}"
    end
  end

  test "rejects incomplete and non-hex literal percent encodings" do
    for template <- ["a%", "a%4", "a%GG", "%4G", "%G4", "%%20", "%é", "%{value}20", "%4{value}1"] do
      refute URITemplate.valid?(template), "Expected invalid template: #{inspect(template)}"
    end
  end

  test "rejects forbidden ASCII literal characters and controls" do
    forbidden = Enum.to_list(0x00..0x20) ++ Enum.to_list(0x7F..0x9F) ++ ~c"\"<>\\^`{|}"

    for codepoint <- forbidden do
      template = "a" <> <<codepoint::utf8>> <> "b"
      refute URITemplate.valid?(template), "Expected invalid template: #{inspect(template)}"
    end
  end

  test "accepts Unicode ucschar and iprivate literals" do
    assert URITemplate.valid?("/café/日本語/😀/{name}")

    # Exercise the endpoints of every ucschar and iprivate range, including private-use planes.
    ranges = [
      {0xA0, 0xD7FF}, {0xF900, 0xFDCF}, {0xFDF0, 0xFFEF},
      {0x10000, 0x1FFFD}, {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD},
      {0x40000, 0x4FFFD}, {0x50000, 0x5FFFD}, {0x60000, 0x6FFFD},
      {0x70000, 0x7FFFD}, {0x80000, 0x8FFFD}, {0x90000, 0x9FFFD},
      {0xA0000, 0xAFFFD}, {0xB0000, 0xBFFFD}, {0xC0000, 0xCFFFD},
      {0xD0000, 0xDFFFD}, {0xE1000, 0xEFFFD},
      {0xE000, 0xF8FF}, {0xF0000, 0xFFFFD}, {0x100000, 0x10FFFD}
    ]

    for {first, last} <- ranges, codepoint <- [first, last] do
      template = "a" <> <<codepoint::utf8>> <> "{value}"
      assert URITemplate.valid?(template), "Expected valid template: #{inspect(template)}"
    end
  end

  test "rejects Unicode outside the ucschar and iprivate ranges" do
    excluded = [0xFDD0, 0xFDEF, 0xFFF0, 0xFFFD, 0xE0000, 0xE0FFF]
    plane_noncharacters = for plane <- 0..16, suffix <- [0xFFFE, 0xFFFF], do: plane * 0x10000 + suffix

    for codepoint <- excluded ++ plane_noncharacters do
      template = "a" <> <<codepoint::utf8>> <> "b"
      refute URITemplate.valid?(template), "Expected invalid template: #{inspect(template)}"
    end
  end

  test "negative tests from uritemplate-test" do
    json = File.read!(@negative_tests_file) |> JSON.decode!()

    # "Failure Tests" is the top key
    failure_tests = json["Failure Tests"]["testcases"]

    # Filter out test cases that are valid syntax but fail expansion (runtime errors).
    # {keys:1} and {+keys:1} fail because 'keys' is a map and prefix modifiers are not allowed on maps.
    # But syntactically they are valid.
    syntax_valid_but_expansion_fail = ["{keys:1}", "{+keys:1}"]

    for [template, _expected_result] <- failure_tests,
        template not in syntax_valid_but_expansion_fail do
      refute URITemplate.valid?(template), "Expected invalid template: #{inspect(template)}"
    end
  end

  test "positive spec tests from uritemplate-test" do
    json = File.read!(@spec_tests_file) |> JSON.decode!()

    for {level_name, level_data} <- json do
      testcases = level_data["testcases"]

      for [template, _expansion] <- testcases do
        assert URITemplate.valid?(template), "Expected valid template in #{level_name}: #{inspect(template)}"
      end
    end
  end
end

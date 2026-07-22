defmodule JSONSchex.Formats.DateTest do
  use ExUnit.Case, async: true
  use JSONSchex.Test.SuiteRunner

  alias JSONSchex.Formats

  run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/date.json")

  test "RFC 3339 date years cannot have a sign prefix" do
    assert :ok == Formats.validate("date", "2020-01-01")
    assert {:error, _} = Formats.validate("date", "+2020-01-01")
    assert {:error, _} = Formats.validate("date", "-2020-01-01")
  end
end

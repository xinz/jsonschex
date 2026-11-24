defmodule JSONSchex.Test.DebugOptionalFormatSuite do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner
  # alias JSONSchex.JSON

  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-date.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-date-time.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-hostname.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-email.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-time.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-idn-hostname.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-uri.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-json-pointer.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-relative-json-pointer.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-idn-email.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-ipv4.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-ipv6.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/optional/ecmascript-regex.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-iri.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-iri-reference.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-uri-template.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/format-duration.json")
  run_suite("test/fixtures/JSON-Schema-Test-Suite/validation/tests/optional/float-overflow.json")

  #test "debug - validation of date strings - a invalid date string with 31 days in April" do
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "format": "date"
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [loader: &JSONSchex.Test.SuiteLoader.load/1, format_assertion: true])
  #  assert {:error, _} = JSONSchex.validate(c, "2020-04-31")
  #  assert :ok == JSONSchex.validate(c, "2020-04-30")
  #end

  #test "debug - a valid idn e-mail (example@example.test in Hangul)" do
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "format": "idn-email"
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [loader: &JSONSchex.Test.SuiteLoader.load/1, format_assertion: true])
  #  assert :ok == JSONSchex.validate(c, "실례@실례.테스트")
  #end
end

defmodule JSONSchex.Test.DebugOptionalFormatSuite do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner
  # alias JSONSchex.JSON

  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/date.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/date-time.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/hostname.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/email.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/time.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/idn-hostname.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/uri.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/json-pointer.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/relative-json-pointer.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/idn-email.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/ipv4.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/ipv6.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/ecmascript-regex.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/iri.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/iri-reference.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/uri-template.json")
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/format/duration.json")
  run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/optional/float-overflow.json")

  #test "debug - validation of date strings - a invalid date string with 31 days in April" do
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "format": "date"
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1, format_assertion: true])
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
  #  {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1, format_assertion: true])
  #  assert :ok == JSONSchex.validate(c, "실례@실례.테스트")
  #end
end

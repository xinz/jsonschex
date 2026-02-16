defmodule JSONSchex.Test.OfficialJSTSCompliance do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner

  run_suite(
    "test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12",
    [
      ignore_files: [
        "optional/cross-draft"
      ]
    ]
  )
end

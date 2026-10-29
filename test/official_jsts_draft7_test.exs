defmodule JSONSchex.Test.OfficialJSTSDraft7Compliance do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner

  run_suite(
    "test/fixtures/JSON-Schema-Test-Suite/tests/draft7",
    [
      draft: "draft7",
      ignore_files: [
        "optional/cross-draft"
      ]
    ]
  )
end

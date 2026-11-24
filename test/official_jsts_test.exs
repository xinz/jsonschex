defmodule JSONSchex.Test.OfficialJSTSCompliance do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner

  run_suite(
    "test/fixtures/JSON-Schema-Test-Suite/validation/tests",
    [
      draft: "draft2020_12",
      ignore_directories: [
        "proposals"
      ],
      ignore_files: [
        "optional/cross-draft"
      ],
      # Elixir's JSON/Jason decoders parse JSON decimals into IEEE 754 64-bit floats,
      # which cannot distinguish values differing beyond 53 bits of significand.
      ignore_suites: [
        {"optional/bignum", "float comparison with high precision"},
        {"optional/bignum", "float comparison with high precision on negative numbers"},
        {"optional/bignum", "enum comparison with high precision"},
        {"optional/bignum", "const comparison with high precision"},
        {"optional/bignum", "uniqueItems comparison with high precision"}
      ]
    ]
  )
end

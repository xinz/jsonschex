defmodule JSONSchex.Formats.URITemplateTest do
  use ExUnit.Case
  alias JSONSchex.Formats.URITemplate
  alias JSONSchex.JSON

  @negative_tests_file "test/fixtures/uritemplate-test/negative-tests.json"
  @spec_tests_file "test/fixtures/uritemplate-test/spec-examples.json"

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

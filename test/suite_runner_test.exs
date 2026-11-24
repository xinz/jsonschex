defmodule JSONSchex.Test.SuiteRunnerTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Test.SuiteRunner

  describe "compatible?/2" do
    test "nil compatibility applies to any dialect" do
      assert SuiteRunner.compatible?(nil, 3)
      assert SuiteRunner.compatible?(nil, 7)
      assert SuiteRunner.compatible?(nil, 2020)
    end

    test "minimum release constraint" do
      refute SuiteRunner.compatible?("7", 6)
      assert SuiteRunner.compatible?("7", 7)
      assert SuiteRunner.compatible?("7", 2019)
      assert SuiteRunner.compatible?("7", 2020)
    end

    test "maximum release constraint" do
      assert SuiteRunner.compatible?("<=2019", 7)
      assert SuiteRunner.compatible?("<=2019", 2019)
      refute SuiteRunner.compatible?("<=2019", 2020)
    end

    test "bounded range constraint" do
      refute SuiteRunner.compatible?("6,<=2019", 4)
      assert SuiteRunner.compatible?("6,<=2019", 6)
      assert SuiteRunner.compatible?("6,<=2019", 7)
      assert SuiteRunner.compatible?("6,<=2019", 2019)
      refute SuiteRunner.compatible?("6,<=2019", 2020)
    end

    test "exact release constraint" do
      refute SuiteRunner.compatible?("=2020", 7)
      refute SuiteRunner.compatible?("=2020", 2019)
      assert SuiteRunner.compatible?("=2020", 2020)
      refute SuiteRunner.compatible?("=2020", 2027)
    end

    test "disjoint multi-constraint expressions" do
      assert SuiteRunner.compatible?("=3,7,<=2020", 3)
      refute SuiteRunner.compatible?("=3,7,<=2020", 4)
      refute SuiteRunner.compatible?("=3,7,<=2020", 6)
      assert SuiteRunner.compatible?("=3,7,<=2020", 7)
      assert SuiteRunner.compatible?("=3,7,<=2020", 2019)
      assert SuiteRunner.compatible?("=3,7,<=2020", 2020)
      refute SuiteRunner.compatible?("=3,7,<=2020", 2027)

      assert SuiteRunner.compatible?("<=3,7", 3)
      refute SuiteRunner.compatible?("<=3,7", 4)
      assert SuiteRunner.compatible?("<=3,7", 7)
      assert SuiteRunner.compatible?("<=3,7", 2020)

      assert SuiteRunner.compatible?("4,<=6,9999", 4)
      assert SuiteRunner.compatible?("4,<=6,9999", 6)
      refute SuiteRunner.compatible?("4,<=6,9999", 7)
      refute SuiteRunner.compatible?("4,<=6,9999", 2020)
      assert SuiteRunner.compatible?("4,<=6,9999", 9999)
    end

    test "unreleased placeholder 9999 is excluded for Draft 7 and 2020-12" do
      refute SuiteRunner.compatible?("9999", 7)
      refute SuiteRunner.compatible?("9999", 2020)
      assert SuiteRunner.compatible?("9999", 9999)
    end

    test "invalid constraint raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        SuiteRunner.compatible?(">=abc", 2020)
      end
    end
  end
end

defmodule JSONSchex.Test.URIUtil do
  use ExUnit.Case, async: true

  alias JSONSchex.URIUtil

  doctest URIUtil, only: [base: 1, split_fragment: 1, fragment: 1, join_fragment: 2]

  test "base distinguishes a missing URI from empty and fragment-only references" do
    assert URIUtil.base(nil) == nil
    assert (URIUtil.base(nil) || "fallback.json") == "fallback.json"
    assert (URIUtil.base("") || "fallback.json") == ""
    assert (URIUtil.base("#named") || "fallback.json") == ""

    for ref <- ["", "#", "#named", "#/definitions/value", "##"] do
      assert URIUtil.base(ref) == ""
    end
  end

  test "base preserves queries, encoded delimiters, and Unicode without normalization" do
    uri = "https://example.com/資料%23schema.json?next=%23value"
    assert URIUtil.base(uri) == uri
    assert URIUtil.base(uri <> "#named#second") == uri
    assert URIUtil.base("schema%23name.json#/value") == "schema%23name.json"
  end

  test "base agrees with split_fragment for supported URI and reference forms" do
    bases = [
      "",
      "schema.json",
      "../schema.json",
      "/tmp/资料.json",
      "https://example.com/schema.json?version=1",
      "urn:example:schema"
    ]

    for expected <- bases, suffix <- ["", "#", "#named", "#/definitions/value", "#first#second"] do
      uri = expected <> suffix
      assert URIUtil.base(uri) == expected
      assert URIUtil.base(uri) == elem(URIUtil.split_fragment(uri), 0)
    end
  end

  test "split_fragment preserves empty-fragment and first-delimiter semantics" do
    cases = [
      {"", {"", nil}},
      {"#", {"", nil}},
      {"##", {"", "#"}},
      {"#named", {"", "named"}},
      {"#/definitions/value", {"", "/definitions/value"}},
      {"schema.json", {"schema.json", nil}},
      {"schema.json#", {"schema.json", nil}},
      {"schema.json##", {"schema.json", "#"}},
      {"schema.json#first#second", {"schema.json", "first#second"}}
    ]

    for {uri, expected} <- cases do
      assert URIUtil.split_fragment(uri) === expected
    end
  end

  test "split_fragment preserves Unicode, query strings, and encoded hashes" do
    uri = "https://example.com/資料%23schema.json?next=%23value"
    assert URIUtil.split_fragment(uri) === {uri, nil}
    assert URIUtil.split_fragment(uri <> "#名称%23value") === {uri, "名称%23value"}
  end

  test "split_fragment matches the previous String.split implementation" do
    bases = [
      "", "schema.json", "../schema.json", "/tmp/资料.json",
      "https://example.com/schema?next=%23value", "urn:example:schema",
      String.duplicate("segment/", 1_024)
    ]
    suffixes = ["", "#", "##", "#named", "#/definitions/value", "#first#second", "#名称", "#%23"]

    for base <- bases, suffix <- suffixes do
      uri = base <> suffix
      expected = legacy_split_fragment(uri)
      assert URIUtil.split_fragment(uri) === expected
      assert URIUtil.base(uri) === elem(expected, 0)
      assert URIUtil.fragment(uri) === elem(expected, 1)
    end

    uri = "schema.json#" <> String.duplicate("fragment/", 8_192)
    assert URIUtil.split_fragment(uri) === legacy_split_fragment(uri)
  end

  test "split_fragment still requires a binary rather than treating nil as an empty URI" do
    assert_raise FunctionClauseError, fn -> URIUtil.split_fragment(nil) end
  end

  test "join_fragment distinguishes nil, empty, and local fragments" do
    cases = [
      {"schema.json", nil, "schema.json"},
      {"schema.json", "", "schema.json#"},
      {"", nil, ""},
      {"", "", "#"},
      {"", "named", "#named"},
      {"", "/definitions/value", "#/definitions/value"},
      {"urn:example:schema", "named", "urn:example:schema#named"}
    ]

    for {base, fragment, expected} <- cases do
      assert URIUtil.join_fragment(base, fragment) === expected
    end
  end

  test "join_fragment requires a binary base and a binary or nil fragment" do
    assert_raise FunctionClauseError, fn -> URIUtil.join_fragment(nil, "named") end
    assert_raise FunctionClauseError, fn -> URIUtil.join_fragment(nil, nil) end
    assert_raise FunctionClauseError, fn -> URIUtil.join_fragment("schema.json", :named) end
  end

  test "external references require a nonempty base" do
    for ref <- [nil, "", "#", "#named", "#/definitions/value"] do
      refute URIUtil.external_ref?(ref)
    end

    for ref <- ["schema.json", "../schema.json#named", "/tmp/schema.json", "urn:example:schema"] do
      assert URIUtil.external_ref?(ref)
    end
  end

  test "filesystem resolution strips an existing base fragment" do
    assert URIUtil.resolve("/tmp/schema.json#old", "#new") == "/tmp/schema.json#new"
    assert URIUtil.resolve("/tmp/schema.json#old", "child.json#value") == "/tmp/child.json#value"
  end

  defp legacy_split_fragment(uri) do
    case String.split(uri, "#", parts: 2) do
      [base, ""] -> {base, nil}
      [base, fragment] -> {base, fragment}
      [base] -> {base, nil}
    end
  end
end

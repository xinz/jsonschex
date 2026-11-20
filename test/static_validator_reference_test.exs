defmodule JSONSchex.StaticValidatorReferenceTest do
  use ExUnit.Case, async: true
  use JSONSchex

  @age_schema ~X|%{
    "$defs" => %{"age" => %{"type" => "integer"}},
    "properties" => %{
      "age" => %{"$ref" => "#/$defs/age"},
      "not_age" => %{"not" => %{"$ref" => "#/$defs/age"}}
    }
  }|
  defvalidator :age, @age_schema

  test "a nested ref uses the root registry, including under not" do
    assert_matches(@age_schema, &age?/1, &age/1, [
      {%{"age" => 20}, true},
      {%{"age" => "20"}, false},
      {%{"not_age" => 20}, false},
      {%{"not_age" => "20"}, true}
    ])
  end

  @scopes ~X|%{
    "$id" => "https://example.org/root",
    "$defs" => %{"value" => %{"type" => "integer"}},
    "properties" => %{
      "a" => %{
        "$id" => "child",
        "$defs" => %{"value" => %{"type" => "string"}},
        "items" => %{"$ref" => "#/$defs/value"}
      },
      "z" => %{"$ref" => "#/$defs/value"}
    }
  }|
  defvalidator :scoped, @scopes

  test "an items helper inherits the child resource, but its sibling uses the root" do
    assert_matches(@scopes, &scoped?/1, &scoped/1, [
      {%{"a" => ["child"], "z" => 1}, true},
      {%{"a" => [1], "z" => 1}, false},
      {%{"a" => ["child"], "z" => "child"}, false}
    ])
  end

  @dynamic ~X|%{
    "$id" => "https://example.org/outer",
    "$defs" => %{"override" => %{"$dynamicAnchor" => "value", "type" => "integer"}},
    "properties" => %{"child" => %{
      "$id" => "inner",
      "$defs" => %{"default" => %{"$dynamicAnchor" => "value", "type" => "string"}},
      "properties" => %{"value" => %{"$dynamicRef" => "#value"}}
    }}
  }|
  defvalidator :dynamic_value, @dynamic

  test "a nested dynamicRef can select the outer resource's dynamic anchor" do
    assert_matches(@dynamic, &dynamic_value?/1, &dynamic_value/1, [
      {%{"child" => %{"value" => 1}}, true},
      {%{"child" => %{"value" => "inner"}}, false}
    ])
  end

  @fallbacks ~X|%{
    "$defs" => %{"age" => %{"type" => "integer"}},
    "properties" => %{
      "list" => %{"contains" => %{"$ref" => "#/$defs/age"}},
      "object" => %{"unevaluatedProperties" => %{"$ref" => "#/$defs/age"}}
    }
  }|
  defvalidator :fallbacks, @fallbacks

  test "both single-rule and annotation-tracking fallbacks preserve reference context" do
    assert_matches(@fallbacks, &fallbacks?/1, &fallbacks/1, [
      {%{"list" => ["x", 1], "object" => %{"key" => 1}}, true},
      {%{"list" => ["x"]}, false},
      {%{"object" => %{"key" => "x"}}, false}
    ])
  end

  @fragment JSONSchex.Schema.compile_fragment!(%{
              "definitions" => %{"name" => %{"type" => "string"}},
              "entry" => %{"items" => %{"$ref" => "#/definitions/name"}}
            }, entry: "#/entry", draft: "draft7")
  defvalidator :fragment, @fragment

  test "a Draft 7 fragment keeps the containing document as the pointer root" do
    assert_matches(@fragment, &fragment?/1, &fragment/1, [{["Ada"], true}, {[42], false}])
  end

  defp assert_matches(schema, predicate, validator, cases) do
    for {data, valid?} <- cases do
      detailed = JSONSchex.validate(schema, data)
      assert (detailed == :ok) == valid?
      assert JSONSchex.valid?(schema, data) == valid?
      assert predicate.(data) == valid?
      assert validator.(data) == detailed
    end
  end
end

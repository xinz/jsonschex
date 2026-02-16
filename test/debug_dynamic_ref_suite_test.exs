defmodule JSONSchex.Test.DebugDynamicRefSuite do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner
  alias JSONSchex.JSON

  # Directly runs ONLY this file, ignoring any global ignore lists
  #run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/dynamicRef.json")

  #test "$ref and $dynamicAnchor are independent of order - $defs first" do
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "http://localhost:1234/draft2020-12/strict-extendible-allof-defs-first.json",
  #      "allOf": [
  #          {
  #              "$ref": "extendible-dynamic-ref.json"
  #          },
  #          {
  #              "$defs": {
  #                  "elements": {
  #                      "$dynamicAnchor": "elements",
  #                      "properties": {
  #                          "a": true
  #                      },
  #                      "required": ["a"],
  #                      "additionalProperties": false
  #                  }
  #              }
  #          }
  #      ]
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1])
  #  assert {:error, _} = JSONSchex.validate(c, %{"a" => true})
  #  assert {:error, _} = JSONSchex.validate(c, %{"elements" => [%{"b" => 1}]})
  #  assert :ok == JSONSchex.validate(c, %{"elements" => [%{"a" => 1}]})

  #end

  #test "A $dynamicRef with intermediate scopes that don't include a matching $dynamicAnchor does not affect dynamic scope resolution" do
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "https://test.json-schema.org/dynamic-resolution-with-intermediate-scopes/root",
  #      "$ref": "intermediate-scope",
  #      "$defs": {
  #          "foo": {
  #              "$dynamicAnchor": "items",
  #              "type": "string"
  #          },
  #          "intermediate-scope": {
  #              "$id": "intermediate-scope",
  #              "$ref": "list"
  #          },
  #          "list": {
  #              "$id": "list",
  #              "type": "array",
  #              "items": { "$dynamicRef": "#items" },
  #              "$defs": {
  #                "items": {
  #                    "$comment": "This is only needed to satisfy the bookending requirement",
  #                    "$dynamicAnchor": "items"
  #                }
  #              }
  #          }
  #      }
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1])
  #  assert :ok = JSONSchex.validate(c, ["foo", "1"])
  #  assert {:error, _} = JSONSchex.validate(c, ["foo", 1])
  #end

  #test "after leaving a dynamic scope, it is not used by a $dynamicRef" do
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "https://test.json-schema.org/dynamic-ref-leaving-dynamic-scope/main",
  #      "if": {
  #          "$id": "first_scope",
  #          "$defs": {
  #              "thingy": {
  #                  "$comment": "this is first_scope#thingy",
  #                  "$dynamicAnchor": "thingy",
  #                  "type": "number"
  #              }
  #          }
  #      },
  #      "then": {
  #          "$id": "second_scope",
  #          "$ref": "start",
  #          "$defs": {
  #              "thingy": {
  #                  "$comment": "this is second_scope#thingy, the final destination of the $dynamicRef",
  #                  "$dynamicAnchor": "thingy",
  #                  "type": "null"
  #              }
  #          }
  #      },
  #      "$defs": {
  #          "start": {
  #              "$comment": "this is the landing spot from $ref",
  #              "$id": "start",
  #              "$dynamicRef": "inner_scope#thingy"
  #          },
  #          "thingy": {
  #              "$comment": "this is the first stop for the $dynamicRef",
  #              "$id": "inner_scope",
  #              "$dynamicAnchor": "thingy",
  #              "type": "string"
  #          }
  #      }
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1])
  #  assert {:error, _} = JSONSchex.validate(c, "a string")
  #  assert {:error, _} = JSONSchex.validate(c, 42)
  #  assert :ok == JSONSchex.validate(c, nil)
  #end

  test "debug - $dynamicRef avoids the root of each schema, but scopes are still registered" do
    schema = """
    {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://test.json-schema.org/dynamic-ref-avoids-root-of-each-schema/base",
        "$ref": "first#/$defs/stuff",
        "$defs": {
            "first": {
                "$id": "first",
                "$defs": {
                    "stuff": {
                        "$ref": "second#/$defs/stuff"
                    },
                    "length": {
                        "$comment": "unused, because there is no $dynamicAnchor here",
                        "maxLength": 1
                    }
                }
            },
            "second": {
                "$id": "second",
                "$defs": {
                    "stuff": {
                        "$ref": "third#/$defs/stuff"
                    },
                    "length": {
                        "$dynamicAnchor": "length",
                        "maxLength": 2
                    }
                }
            },
            "third": {
                "$id": "third",
                "$defs": {
                    "stuff": {
                        "$dynamicRef": "#length"
                    },
                    "length": {
                        "$dynamicAnchor": "length",
                        "maxLength": 3
                    }
                }
            }
        }
    }
    """
    {:ok, a} = JSON.decode(schema)
    {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1])
    assert {:error, _} = JSONSchex.validate(c, "a string")
    assert {:error, _} = JSONSchex.validate(c, "hey")
    assert :ok == JSONSchex.validate(c, "hi")
  end
end

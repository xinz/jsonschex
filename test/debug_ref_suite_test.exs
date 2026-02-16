defmodule JSONSchex.Test.DebugRefSuite do
  use ExUnit.Case
  use JSONSchex.Test.SuiteRunner
  # alias JSONSchex.JSON

  # Directly runs ONLY this file, ignoring any global ignore lists
  run_suite("test/fixtures/JSON-Schema-Test-Suite/tests/draft2020-12/ref.json")

  #test "tmp" do
  #  schema = """
  #  {
  #      "$comment": "$id must be evaluated before $ref to get the proper $ref destination",
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "https://example.com/draft2020-12/ref-and-id2/base.json",
  #      "$ref": "#bigint",
  #      "$defs": {
  #          "bigint": {
  #              "$comment": "canonical uri: /ref-and-id2/base.json#/$defs/bigint; another valid uri for this location: /ref-and-id2/base.json#bigint",
  #              "$anchor": "bigint",
  #              "maximum": 10
  #          },
  #          "smallint": {
  #              "$comment": "canonical uri: https://example.com/ref-and-id2#/$defs/smallint; another valid uri for this location: https://example.com/ref-and-id2/#bigint",
  #              "$id": "https://example.com/draft2020-12/ref-and-id2/",
  #              "$anchor": "bigint",
  #              "maximum": 2
  #          }
  #      }
  #  }
  #  """

  #  schema = """
  #  {
  #      "$comment": "$id must be evaluated before $ref to get the proper $ref destination",
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "https://example.com/draft2020-12/ref-and-id2/base.json",
  #      "$ref": "#bigint",
  #      "$defs": {
  #          "bigint": {
  #              "$comment": "canonical uri: /ref-and-id2/base.json#/$defs/bigint; another valid uri for this location: /ref-and-id2/base.json#bigint",
  #              "$anchor": "bigint",
  #              "maximum": 10
  #          },
  #          "smallint": {
  #              "$comment": "canonical uri: https://example.com/ref-and-id2#/$defs/smallint; another valid uri for this location: https://example.com/ref-and-id2/#bigint",
  #              "$id": "https://example.com/draft2020-12/ref-and-id2/",
  #              "$anchor": "bigint",
  #              "maximum": 2
  #          }
  #      }
  #  }
  #  """
  #
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "http://example.com/a.json",
  #      "$defs": {
  #          "x": {
  #              "$id": "http://example.com/b/c.json",
  #              "not": {
  #                  "$defs": {
  #                      "y": {
  #                          "$id": "d.json",
  #                          "type": "number"
  #                      }
  #                  }
  #              }
  #          }
  #      },
  #      "allOf": [
  #          {
  #              "$ref": "http://example.com/b/d.json"
  #          }
  #      ]
  #  }
  #  """
  #
  #  SpecialCase1
  #  schema = """
  #  {
  #      "$comment": "$id must be evaluated before $ref to get the proper $ref destination",
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "https://example.com/draft2020-12/ref-and-id3/base.json",
  #      "$ref": "nested/foo.json",
  #      "$defs": {
  #          "foo": {
  #              "$comment": "canonical uri: https://example.com/draft2020-12/ref-and-id3/nested/foo.json",
  #              "$id": "nested/foo.json",
  #              "$ref": "./bar.json"
  #          },
  #          "bar": {
  #              "$comment": "canonical uri: https://example.com/draft2020-12/ref-and-id3/nested/bar.json",
  #              "$id": "nested/bar.json",
  #              "type": "number"
  #          }
  #      }
  #  }
  #  """
  #
  #  SpecailCase2 with Case1
  #  schema = """
  #  {
  #    "$schema": "https://json-schema.org/draft/2020-12/schema",
  #    "$ref": "urn:uuid:deadbeef-4321-ffff-ffff-1234feebdaed",
  #    "$defs": {
  #        "foo": {
  #            "$id": "urn:uuid:deadbeef-4321-ffff-ffff-1234feebdaed",
  #            "$defs": {"bar": {"type": "string"}},
  #            "$ref": "#/$defs/bar"
  #        }
  #    }
  #  }
  #  """
  #  #SpecialCase3
  #  schema = """
  #  {
  #      "$comment": "URIs do not have to have HTTP(s) schemes",
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed",
  #      "minimum": 30,
  #      "properties": {
  #          "foo": {"$ref": "urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed"}
  #      }
  #  }
  #  """
  # #SpecialCase4
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "urn:uuid:deadbeef-1234-ff00-00ff-4321feebdaed",
  #      "properties": {
  #          "foo": {"$ref": "urn:uuid:deadbeef-1234-ff00-00ff-4321feebdaed#something"}
  #      },
  #      "$defs": {
  #          "bar": {
  #              "$anchor": "something",
  #              "type": "string"
  #          }
  #      }
  #  }
  #  """
  # #SpecialCase5 with SpecialCase4
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "urn:uuid:deadbeef-1234-0000-0000-4321feebdaed",
  #      "properties": {
  #          "foo": {"$ref": "urn:uuid:deadbeef-1234-0000-0000-4321feebdaed#/$defs/bar"}
  #      },
  #      "$defs": {
  #          "bar": {"type": "string"}
  #      }
  #  }
  #  """
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$ref": "https://json-schema.org/draft/2020-12/schema"
  #  }
  #  """
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$id": "http://example.com/schema-relative-uri-defs1.json",
  #      "properties": {
  #          "foo": {
  #              "$id": "schema-relative-uri-defs2.json",
  #              "$defs": {
  #                  "inner": {
  #                      "properties": {
  #                          "bar": { "type": "string" }
  #                      }
  #                  }
  #              },
  #              "$ref": "#/$defs/inner"
  #          }
  #      },
  #      "$ref": "schema-relative-uri-defs2.json"
  #  }
  #  """
  #  schema = """
  #  {
  #      "$schema": "https://json-schema.org/draft/2020-12/schema",
  #      "$ref": "https://json-schema.org/draft/2020-12/schema"
  #  }
  #  """
  #  {:ok, a} = JSON.decode(schema)
  #  {:ok, c} = JSONSchex.compile(a, [external_loader: &JSONSchex.Test.SuiteLoader.load/1])
  ##  {:ok, c} = JSONSchex.compile(a)
  #  IO.puts "final compiled: #{inspect(c, pretty: true)}"
  #  IO.puts "***start validate***"
  #  JSONSchex.validate(c, %{"minLength" => 1}) |> IO.inspect()
  #end
end

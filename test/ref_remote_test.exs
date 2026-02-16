defmodule JSONSchex.Test.RefRemote do
  use ExUnit.Case

  test "remote HTTP ref with different $id" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$ref" => "http://localhost:1234/different-id-ref-string.json"
    }

    assert {:ok, c} = JSONSchex.compile(schema, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert {:error, _e} = JSONSchex.validate(c, 1)
  end

  test "root ref in remote ref" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/object",
      "type" => "object",
      "properties" => %{
          "name" => %{"$ref" => "name-defs.json#/$defs/orNull"}
      }
    }
    assert {:ok, c} = JSONSchex.compile(schema, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert :ok == JSONSchex.validate(c, %{"name" => "foo"})
    assert :ok == JSONSchex.validate(c, %{"name" => nil})
    assert {:error, _} = JSONSchex.validate(c, 1)
    assert {:error, _} = JSONSchex.validate(c, %{"name" => %{"foo" => "bar"}})
  end

  test "base URI change - change folder in subschema" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/scope_change_defs2.json",
      "type" => "object",
      "properties" => %{
          "list" => %{
              "$ref" => "baseUriChangeFolderInSubschema/#/$defs/bar"
          }
      },
      "$defs" => %{
        "baz"=> %{
           "$id" => "baseUriChangeFolderInSubschema/",
           "$defs" => %{
             "bar" => %{
               "type" => "array",
               "items" => %{"$ref" => "folderInteger.json"}
             }
           }
        }
      }
    }
    assert {:ok, c} = JSONSchex.compile(schema, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert :ok == JSONSchex.validate(c, %{"list" => [1]})
    assert {:error, [e]} = JSONSchex.validate(c, %{"list" => ["1"]})
    assert e.rule == :type
  end

  test "retrieved nested refs resolve relative to their URI not $id" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "http://localhost:1234/draft2020-12/some-id",
      "properties" => %{
          "name" => %{"$ref" => "nested/foo-ref-string.json"}
      }
    }
    assert {:ok, c} = JSONSchex.compile(schema, external_loader: &JSONSchex.Test.SuiteLoader.load/1)
    assert :ok == JSONSchex.validate(c, %{"name" => %{"foo" => "a"}})
    assert {:error, _e} = JSONSchex.validate(c, %{"name" => %{"foo" => 1}})
  end

end

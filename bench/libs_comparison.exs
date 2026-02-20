# Comprehensive JSON Schema Benchmark: JSONSchex, JSV, JsonXema
#
# Covers all major keyword categories with both valid and invalid data.
# Run from the `bench` directory: mix run libs_comparison.exs
#
# To run a specific section only, set BENCH env var:
#   BENCH=all   mix run libs_comparison.exs   # run everything (default)
#   BENCH=simple mix run libs_comparison.exs   # simple type + constraints
#   BENCH=nested mix run libs_comparison.exs   # nested object
#   BENCH=ref    mix run libs_comparison.exs   # recursive $ref / $id
#   BENCH=array  mix run libs_comparison.exs   # array-heavy (items, prefixItems, contains, uniqueItems)
#   BENCH=allof  mix run libs_comparison.exs   # allOf
#   BENCH=anyof  mix run libs_comparison.exs   # anyOf
#   BENCH=oneof  mix run libs_comparison.exs   # oneOf
#   BENCH=not    mix run libs_comparison.exs   # not
#   BENCH=conditional mix run libs_comparison.exs  # if/then/else
#   BENCH=additional  mix run libs_comparison.exs  # additionalProperties + patternProperties
#   BENCH=uneval mix run libs_comparison.exs   # unevaluatedProperties
#   BENCH=dependent mix run libs_comparison.exs # dependentRequired + dependentSchemas
#   BENCH=large  mix run libs_comparison.exs   # large payload scale test
#   BENCH=property_names mix run libs_comparison.exs # propertyNames
#   BENCH=format mix run libs_comparison.exs   # format keyword (email, date, uri-reference, ipv4, iri-reference)
#   BENCH=dependencies mix run libs_comparison.exs # dependencies

{:ok, _} = Application.ensure_all_started(:jsv)
{:ok, _} = Application.ensure_all_started(:jsonschex)
{:ok, _} = Application.ensure_all_started(:json_xema)

bench_filter = System.get_env("BENCH", "all") |> String.downcase()

benchee_opts = [
  warmup: 2,
  time: 5,
  memory_time: 2,
  formatters: [{Benchee.Formatters.Console, comparison: true}]
]

compile_both = fn schema, opts ->
  jsv = JSV.build!(schema)
  {:ok, jx} = JSONSchex.compile(schema)
  xema =
    if Keyword.get(opts, :xema_supported, true) do
      JsonXema.new(schema)
    else
      nil
    end
  {jsv, jx, xema}
end

run_bench = fn name, cases ->
  if bench_filter == "all" or String.contains?(name, bench_filter) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  Benchmark: #{name}")
    IO.puts(String.duplicate("=", 60))
    Benchee.run(cases, benchee_opts)
  end
end

# =============================================================================
# 1. Simple Type + Constraints
#    Baseline overhead of the validation engine — no nesting, no refs.
# =============================================================================

simple_schema = %{
  "type" => "string",
  "minLength" => 3,
  "maxLength" => 50,
  "pattern" => "^[a-z]+$"
}

{jsv_simple, jx_simple, xema_simple} = compile_both.(simple_schema, [])

simple_valid = "hello"
simple_invalid = "hi"

run_bench.("simple_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(simple_valid, jsv_simple) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_simple, simple_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_simple, simple_valid) end
})

run_bench.("simple_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(simple_invalid, jsv_simple) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_simple, simple_invalid) end
})

# =============================================================================
# 2. Nested Object: properties + required
#    The bread-and-butter of real-world API validation.
# =============================================================================

nested_obj_schema = %{
  "type" => "object",
  "properties" => %{
    "id" => %{"type" => "integer"},
    "user" => %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1},
        "email" => %{"type" => "string", "format" => "email"},
        "age" => %{"type" => "integer", "minimum" => 18},
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "minItems" => 1
        }
      },
      "required" => ["name", "email"]
    },
    "status" => %{"type" => "string", "enum" => ["active", "pending", "inactive"]},
    "metadata" => %{
      "type" => "object",
      "additionalProperties" => true
    }
  },
  "required" => ["id", "user", "status"]
}

{jsv_nested, jx_nested, xema_nested} = compile_both.(nested_obj_schema, [])

nested_valid = %{
  "id" => 123,
  "user" => %{
    "name" => "Alice",
    "email" => "alice@example.com",
    "age" => 30,
    "tags" => ["admin", "dev"]
  },
  "status" => "active",
  "metadata" => %{"ip" => "127.0.0.1", "ua" => "test-bot"}
}

nested_invalid = %{
  "id" => "wrong_type",
  "user" => %{
    "name" => "",
    "age" => 10,
    "tags" => []
  },
  "status" => "deleted"
}

run_bench.("nested_object_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(nested_valid, jsv_nested) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_nested, nested_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_nested, nested_valid) end
})

run_bench.("nested_object_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(nested_invalid, jsv_nested) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_nested, nested_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_nested, nested_invalid) end
})

# =============================================================================
# 3. Recursive $ref / $id
#    Tests reference resolution performance on a tree-of-nodes schema.
# =============================================================================

ref_schema = %{
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "$id" => "http://localhost:1234/draft2020-12/tree",
  "description" => "tree of nodes",
  "type" => "object",
  "properties" => %{
    "meta" => %{"type" => "string"},
    "nodes" => %{
      "type" => "array",
      "items" => %{"$ref" => "node"}
    }
  },
  "required" => ["meta", "nodes"],
  "$defs" => %{
    "node" => %{
      "$id" => "http://localhost:1234/draft2020-12/node",
      "description" => "node",
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "number"},
        "subtree" => %{"$ref" => "tree"}
      },
      "required" => ["value"]
    }
  }
}

{jsv_ref, jx_ref, _xema_ref} = compile_both.(ref_schema, [xema_supported: false])

ref_valid = %{
  "meta" => "root",
  "nodes" => [
    %{
      "value" => 1,
      "subtree" => %{
        "meta" => "child",
        "nodes" => [%{"value" => 1.1}, %{"value" => 1.2}]
      }
    },
    %{
      "value" => 2,
      "subtree" => %{
        "meta" => "child",
        "nodes" => [%{"value" => 2.1}, %{"value" => 2.2}]
      }
    }
  ]
}

ref_invalid = %{
  "meta" => "root",
  "nodes" => [
    %{
      "value" => "not a number",
      "subtree" => %{
        "meta" => 123,
        "nodes" => [%{"value" => 1.1}]
      }
    }
  ]
}

run_bench.("ref_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(ref_valid, jsv_ref) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_ref, ref_valid) end
  # JsonXema not supported
})

run_bench.("ref_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(ref_invalid, jsv_ref) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_ref, ref_invalid) end
})

# =============================================================================
# 4. Array-Heavy: items, prefixItems, contains, uniqueItems
#    Tests iteration cost that scales with array length.
# =============================================================================

array_schema = %{
  "type" => "array",
  "items" => %{
    "type" => "object",
    "properties" => %{
      "id" => %{"type" => "integer"},
      "value" => %{"type" => "string", "minLength" => 1}
    },
    "required" => ["id", "value"]
  },
  "minItems" => 1,
  "maxItems" => 200
}

{jsv_array, jx_array, xema_array} = compile_both.(array_schema, [])

array_valid_small = Enum.map(1..10, &%{"id" => &1, "value" => "item-#{&1}"})
array_valid_large = Enum.map(1..100, &%{"id" => &1, "value" => "item-#{&1}"})
array_invalid = Enum.map(1..10, &%{"id" => "bad", "value" => &1})

run_bench.("array_small_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(array_valid_small, jsv_array) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_array, array_valid_small) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_array, array_valid_small) end
})

run_bench.("array_large_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(array_valid_large, jsv_array) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_array, array_valid_large) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_array, array_valid_large) end
})

run_bench.("array_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(array_invalid, jsv_array) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_array, array_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_array, array_invalid) end
})

# --- prefixItems + contains ---

prefix_contains_schema = %{
  "type" => "array",
  "prefixItems" => [
    %{"type" => "string"},
    %{"type" => "integer"},
    %{"type" => "boolean"}
  ],
  "contains" => %{"type" => "integer", "minimum" => 10}
}

{jsv_prefix, jx_prefix, xema_prefix} = compile_both.(prefix_contains_schema, [])

prefix_valid = ["hello", 42, true, "extra", 15]
prefix_invalid = ["hello", "not int", true, 1]

run_bench.("array_prefix_contains_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(prefix_valid, jsv_prefix) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_prefix, prefix_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_prefix, prefix_valid) end
})

run_bench.("array_prefix_contains_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(prefix_invalid, jsv_prefix) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_prefix, prefix_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_prefix, prefix_invalid) end
})

# --- uniqueItems ---

unique_schema = %{"type" => "array", "uniqueItems" => true}
{jsv_unique, jx_unique, xema_unique} = compile_both.(unique_schema, [])

unique_valid = Enum.to_list(1..50)
unique_invalid = Enum.to_list(1..49) ++ [1]

run_bench.("array_unique_items_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(unique_valid, jsv_unique) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_unique, unique_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_unique, unique_valid) end
})

run_bench.("array_unique_items_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(unique_invalid, jsv_unique) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_unique, unique_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_unique, unique_invalid) end
})

# =============================================================================
# 5. Applicators: allOf / anyOf / oneOf / not
#    These require multiple validation passes over the same data.
#    oneOf is the costliest — must check ALL branches.
# =============================================================================

allof_schema = %{
  "allOf" => [
    %{"type" => "object", "properties" => %{"name" => %{"type" => "string", "minLength" => 1}}, "required" => ["name"]},
    %{"type" => "object", "properties" => %{"age" => %{"type" => "integer", "minimum" => 0}}, "required" => ["age"]},
    %{"type" => "object", "properties" => %{"email" => %{"type" => "string"}}, "required" => ["email"]}
  ]
}

{jsv_allof, jx_allof, xema_allof} = compile_both.(allof_schema, [])

allof_valid = %{"name" => "Alice", "age" => 30, "email" => "alice@example.com"}
allof_invalid = %{"name" => "", "age" => -1}

run_bench.("allof_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(allof_valid, jsv_allof) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_allof, allof_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_allof, allof_valid) end
})

run_bench.("allof_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(allof_invalid, jsv_allof) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_allof, allof_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_allof, allof_invalid) end
})

# --- anyOf ---

anyof_schema = %{
  "anyOf" => [
    %{"type" => "object", "properties" => %{"kind" => %{"const" => "person"}, "name" => %{"type" => "string"}}, "required" => ["kind", "name"]},
    %{"type" => "object", "properties" => %{"kind" => %{"const" => "org"}, "title" => %{"type" => "string"}}, "required" => ["kind", "title"]},
    %{"type" => "object", "properties" => %{"kind" => %{"const" => "bot"}, "version" => %{"type" => "integer"}}, "required" => ["kind", "version"]}
  ]
}

{jsv_anyof, jx_anyof, xema_anyof} = compile_both.(anyof_schema, [])

anyof_valid = %{"kind" => "org", "title" => "Acme Corp"}
anyof_invalid = %{"kind" => "unknown", "data" => 123}

run_bench.("anyof_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(anyof_valid, jsv_anyof) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_anyof, anyof_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_anyof, anyof_valid) end
})

run_bench.("anyof_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(anyof_invalid, jsv_anyof) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_anyof, anyof_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_anyof, anyof_invalid) end
})

# --- oneOf (costliest — must always evaluate ALL branches) ---

oneof_schema = %{
  "oneOf" => [
    %{"type" => "object", "properties" => %{"type" => %{"const" => "a"}, "a_field" => %{"type" => "string"}}, "required" => ["type", "a_field"]},
    %{"type" => "object", "properties" => %{"type" => %{"const" => "b"}, "b_field" => %{"type" => "integer"}}, "required" => ["type", "b_field"]},
    %{"type" => "object", "properties" => %{"type" => %{"const" => "c"}, "c_field" => %{"type" => "boolean"}}, "required" => ["type", "c_field"]},
    %{"type" => "object", "properties" => %{"type" => %{"const" => "d"}, "d_field" => %{"type" => "array"}}, "required" => ["type", "d_field"]}
  ]
}

{jsv_oneof, jx_oneof, xema_oneof} = compile_both.(oneof_schema, [])

oneof_valid = %{"type" => "c", "c_field" => true}
oneof_invalid = %{"type" => "x", "x_field" => "nope"}

run_bench.("oneof_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(oneof_valid, jsv_oneof) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_oneof, oneof_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_oneof, oneof_valid) end
})

run_bench.("oneof_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(oneof_invalid, jsv_oneof) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_oneof, oneof_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_oneof, oneof_invalid) end
})

# --- not ---

not_schema = %{
  "not" => %{
    "type" => "object",
    "properties" => %{"role" => %{"const" => "admin"}},
    "required" => ["role"]
  }
}

{jsv_not, jx_not, xema_not} = compile_both.(not_schema, [])

not_valid = %{"role" => "user"}
not_invalid = %{"role" => "admin"}

run_bench.("not_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(not_valid, jsv_not) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_not, not_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_not, not_valid) end
})

run_bench.("not_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(not_invalid, jsv_not) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_not, not_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_not, not_invalid) end
})

# =============================================================================
# 6. if / then / else (Conditional)
#    Requires evaluating `if` branch first, then selectively `then` or `else`.
# =============================================================================

conditional_schema = %{
  "type" => "object",
  "properties" => %{
    "country" => %{"type" => "string"},
    "postal_code" => %{"type" => "string"}
  },
  "required" => ["country", "postal_code"],
  "if" => %{
    "properties" => %{"country" => %{"const" => "US"}}
  },
  "then" => %{
    "properties" => %{"postal_code" => %{"pattern" => "^[0-9]{5}(-[0-9]{4})?$"}}
  },
  "else" => %{
    "properties" => %{"postal_code" => %{"pattern" => "^[A-Z][0-9][A-Z] [0-9][A-Z][0-9]$"}}
  }
}

{jsv_cond, jx_cond, xema_cond} = compile_both.(conditional_schema, [])

cond_valid_us = %{"country" => "US", "postal_code" => "90210"}
cond_valid_ca = %{"country" => "CA", "postal_code" => "K1A 0B1"}
cond_invalid_us = %{"country" => "US", "postal_code" => "ABCDE"}

run_bench.("conditional_valid_then", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(cond_valid_us, jsv_cond) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_cond, cond_valid_us) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_cond, cond_valid_us) end
})

run_bench.("conditional_valid_else", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(cond_valid_ca, jsv_cond) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_cond, cond_valid_ca) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_cond, cond_valid_ca) end
})

run_bench.("conditional_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(cond_invalid_us, jsv_cond) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_cond, cond_invalid_us) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_cond, cond_invalid_us) end
})

# =============================================================================
# 7. additionalProperties + patternProperties
#    Tests the cost of tracking claimed properties and validating the remainder.
# =============================================================================

addl_pattern_schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"},
    "age" => %{"type" => "integer"}
  },
  "patternProperties" => %{
    "^x-" => %{"type" => "string"}
  },
  "additionalProperties" => false
}

{jsv_addl, jx_addl, xema_addl} = compile_both.(addl_pattern_schema, [])

addl_valid = %{"name" => "Alice", "age" => 30, "x-custom" => "value", "x-tag" => "important"}
addl_invalid = %{"name" => "Bob", "age" => 25, "unknown_field" => true}

run_bench.("additional_pattern_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(addl_valid, jsv_addl) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_addl, addl_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_addl, addl_valid) end
})

run_bench.("additional_pattern_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(addl_invalid, jsv_addl) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_addl, addl_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_addl, addl_invalid) end
})

# --- additionalProperties with schema (not just false) ---

addl_schema_schema = %{
  "type" => "object",
  "properties" => %{
    "id" => %{"type" => "integer"}
  },
  "additionalProperties" => %{"type" => "string", "maxLength" => 100}
}

{jsv_addl_s, jx_addl_s, xema_addl_s} = compile_both.(addl_schema_schema, [])

addl_s_valid = %{"id" => 1, "name" => "Alice", "email" => "a@b.com", "city" => "NYC", "role" => "admin"}
addl_s_invalid = %{"id" => 1, "name" => 123, "email" => true}

run_bench.("additional_schema_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(addl_s_valid, jsv_addl_s) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_addl_s, addl_s_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_addl_s, addl_s_valid) end
})

run_bench.("additional_schema_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(addl_s_invalid, jsv_addl_s) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_addl_s, addl_s_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_addl_s, addl_s_invalid) end
})

# =============================================================================
# 8. unevaluatedProperties
#    The most complex tracking in Draft 2020-12 — must collect evaluated keys
#    across allOf, if/then/else, $ref, etc.
# =============================================================================

uneval_schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"}
  },
  "allOf" => [
    %{
      "if" => %{"properties" => %{"name" => %{"const" => "admin"}}},
      "then" => %{"properties" => %{"level" => %{"type" => "integer"}}},
      "else" => %{"properties" => %{"email" => %{"type" => "string"}}}
    }
  ],
  "unevaluatedProperties" => false
}

{jsv_uneval, jx_uneval, _xema_uneval} = compile_both.(uneval_schema, [xema_supported: false])

uneval_valid_admin = %{"name" => "admin", "level" => 5}
uneval_valid_user = %{"name" => "alice", "email" => "a@b.com"}
uneval_invalid = %{"name" => "bob", "email" => "b@c.com", "extra" => true}

run_bench.("unevaluated_valid_then", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(uneval_valid_admin, jsv_uneval) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_uneval, uneval_valid_admin) end
})

run_bench.("unevaluated_valid_else", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(uneval_valid_user, jsv_uneval) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_uneval, uneval_valid_user) end
})

run_bench.("unevaluated_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(uneval_invalid, jsv_uneval) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_uneval, uneval_invalid) end
  # JsonXema not supported
})

# =============================================================================
# 9. dependentRequired + dependentSchemas
# =============================================================================

dependent_schema = %{
  "type" => "object",
  "properties" => %{
    "name" => %{"type" => "string"},
    "credit_card" => %{"type" => "string"},
    "billing_address" => %{"type" => "string"},
    "shipping_address" => %{"type" => "string"}
  },
  "dependentRequired" => %{
    "credit_card" => ["billing_address"]
  },
  "dependentSchemas" => %{
    "credit_card" => %{
      "properties" => %{
        "billing_address" => %{"minLength" => 5}
      }
    }
  }
}

{jsv_dep, jx_dep, _} = compile_both.(dependent_schema, [xema_supported: false])

dep_valid = %{"name" => "Alice", "credit_card" => "1234-5678", "billing_address" => "123 Main St"}
dep_invalid_missing = %{"name" => "Bob", "credit_card" => "1234-5678"}
dep_invalid_schema = %{"name" => "Eve", "credit_card" => "1234", "billing_address" => "Hi"}

run_bench.("dependent_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(dep_valid, jsv_dep) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_dep, dep_valid) end
})

run_bench.("dependent_invalid_missing", %{
  "JSV" => fn -> {:error, _} = JSV.validate(dep_invalid_missing, jsv_dep) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_dep, dep_invalid_missing) end
})

run_bench.("dependent_invalid_schema", %{
  "JSV" => fn -> {:error, _} = JSV.validate(dep_invalid_schema, jsv_dep) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_dep, dep_invalid_schema) end
})

# =============================================================================
# 10. Large Payload Scale Test
#     A moderately complex schema against a 100-item array.
#     Exposes O(n) constant-factor differences invisible with small data.
# =============================================================================

large_item_schema = %{
  "type" => "object",
  "properties" => %{
    "id" => %{"type" => "integer", "minimum" => 1},
    "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
    "email" => %{"type" => "string"},
    "active" => %{"type" => "boolean"},
    "score" => %{"type" => "number", "minimum" => 0, "maximum" => 100},
    "tags" => %{
      "type" => "array",
      "items" => %{"type" => "string"},
      "maxItems" => 10
    },
    "address" => %{
      "type" => "object",
      "properties" => %{
        "street" => %{"type" => "string"},
        "city" => %{"type" => "string"},
        "zip" => %{"type" => "string"}
      },
      "required" => ["street", "city"]
    }
  },
  "required" => ["id", "name", "email", "active"]
}

large_schema = %{
  "type" => "array",
  "items" => large_item_schema,
  "minItems" => 1
}

{jsv_large, jx_large, xema_large} = compile_both.(large_schema, [])

large_valid = Enum.map(1..100, fn i ->
  %{
    "id" => i,
    "name" => "User #{i}",
    "email" => "user#{i}@example.com",
    "active" => rem(i, 3) != 0,
    "score" => rem(i * 7, 101),
    "tags" => ["tag-#{rem(i, 5)}", "tag-#{rem(i, 3)}"],
    "address" => %{
      "street" => "#{i} Main St",
      "city" => "City #{rem(i, 10)}",
      "zip" => String.pad_leading("#{rem(i * 111, 100_000)}", 5, "0")
    }
  }
end)

# Sprinkle errors throughout the array
large_invalid = Enum.map(1..100, fn i ->
  base = %{
    "id" => i,
    "name" => "User #{i}",
    "email" => "user#{i}@example.com",
    "active" => rem(i, 3) != 0,
    "score" => rem(i * 7, 101),
    "tags" => ["tag"],
    "address" => %{"street" => "#{i} St", "city" => "C"}
  }

  case rem(i, 10) do
    0 -> Map.put(base, "id", "not_an_int")
    3 -> Map.put(base, "score", -10)
    7 -> Map.put(base, "active", "not_bool")
    _ -> base
  end
end)

run_bench.("large_payload_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(large_valid, jsv_large) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_large, large_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_large, large_valid) end
})

run_bench.("large_payload_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(large_invalid, jsv_large) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_large, large_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_large, large_invalid) end
})

# =============================================================================
# 11. propertyNames
# =============================================================================

propnames_schema = %{
  "type" => "object",
  "propertyNames" => %{
    "type" => "string",
    "pattern" => "^[a-z][a-z0-9_]*$",
    "maxLength" => 20
  }
}

{jsv_pn, jx_pn, xema_pn} = compile_both.(propnames_schema, [])

pn_valid = Enum.into(1..15, %{}, fn i -> {"field_#{i}", "value"} end)
pn_invalid = Map.put(pn_valid, "INVALID-KEY!", "value")

run_bench.("property_names_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(pn_valid, jsv_pn) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_pn, pn_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_pn, pn_valid) end
})

run_bench.("property_names_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(pn_invalid, jsv_pn) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_pn, pn_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_pn, pn_invalid) end
})

# =============================================================================
# 12. Format Validation (email, date, uri-reference, ipv4)
#     Tests the cost of built-in format checkers.
# =============================================================================

format_email_schema = %{
  "type" => "string",
  "format" => "email"
}

format_date_schema = %{
  "type" => "string",
  "format" => "date"
}

format_uri_ref_schema = %{
  "type" => "string",
  "format" => "uri-reference"
}

format_ipv4_schema = %{
  "type" => "string",
  "format" => "ipv4"
}

format_iri_ref_schema = %{
  "format" => "iri-reference"
}

# JSV requires `formats: true` to enforce format validation (default meta-schema
# treats format as annotation-only per the JSON Schema spec).
compile_both_fmt = fn schema, opts ->
  jsv = JSV.build!(schema, formats: true)
  {:ok, jx} = JSONSchex.compile(schema)
  xema =
    if Keyword.get(opts, :xema_supported, true) do
      JsonXema.new(schema)
    else
      nil
    end
  {jsv, jx, xema}
end

{jsv_fmt_email, jx_fmt_email, xema_fmt_email} = compile_both_fmt.(format_email_schema, [])
{jsv_fmt_date, jx_fmt_date, xema_fmt_date} = compile_both_fmt.(format_date_schema, [])
{jsv_fmt_uri, jx_fmt_uri, xema_fmt_uri} = compile_both_fmt.(format_uri_ref_schema, [])
{jsv_fmt_ipv4, jx_fmt_ipv4, xema_fmt_ipv4} = compile_both_fmt.(format_ipv4_schema, [])
{jsv_fmt_iri_ref, jx_fmt_iri_ref, _xema_fmt_iri_ref} = compile_both_fmt.(format_iri_ref_schema, [xema_supported: false])

# --- email ---

fmt_email_valid = "alice@example.com"
fmt_email_invalid = "not-an-email"

run_bench.("format_email_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(fmt_email_valid, jsv_fmt_email) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_fmt_email, fmt_email_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_fmt_email, fmt_email_valid) end
})

run_bench.("format_email_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(fmt_email_invalid, jsv_fmt_email) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_fmt_email, fmt_email_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_fmt_email, fmt_email_invalid) end
})

# --- date ---

fmt_date_valid = "2024-06-15"
fmt_date_invalid = "2024-13-45"

run_bench.("format_date_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(fmt_date_valid, jsv_fmt_date) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_fmt_date, fmt_date_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_fmt_date, fmt_date_valid) end
})

run_bench.("format_date_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(fmt_date_invalid, jsv_fmt_date) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_fmt_date, fmt_date_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_fmt_date, fmt_date_invalid) end
})

# --- iri-reference ---

fmt_iri_ref_valid = "#ƒrägmênt"
fmt_iri_ref_invalid = "\\\\WINDOWS\\filëßåré"

run_bench.("format_iri_ref_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(fmt_iri_ref_valid, jsv_fmt_iri_ref) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_fmt_iri_ref, fmt_iri_ref_valid) end
})

run_bench.("format_iri_ref_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(fmt_iri_ref_invalid, jsv_fmt_iri_ref) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_fmt_iri_ref, fmt_iri_ref_invalid) end
})

# --- uri ---

fmt_uri_valid = "/api/v2/users?page=1&limit=50"
fmt_uri_invalid = "https://example.org/foobar\\.txt"

run_bench.("format_uri_ref_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(fmt_uri_valid, jsv_fmt_uri) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_fmt_uri, fmt_uri_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_fmt_uri, fmt_uri_valid) end
})

run_bench.("format_uri_ref_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(fmt_uri_invalid, jsv_fmt_uri) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_fmt_uri, fmt_uri_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_fmt_uri, fmt_uri_invalid) end
})

# --- ipv4 ---

fmt_ipv4_valid = "192.168.1.100"
fmt_ipv4_invalid = "999.999.999.999"

run_bench.("format_ipv4_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(fmt_ipv4_valid, jsv_fmt_ipv4) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_fmt_ipv4, fmt_ipv4_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_fmt_ipv4, fmt_ipv4_valid) end
})

run_bench.("format_ipv4_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(fmt_ipv4_invalid, jsv_fmt_ipv4) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_fmt_ipv4, fmt_ipv4_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_fmt_ipv4, fmt_ipv4_invalid) end
})

# --- Combined: object with multiple format fields ---

format_combo_schema = %{
  "type" => "object",
  "properties" => %{
    "email" => %{"type" => "string", "format" => "email"},
    "birth_date" => %{"type" => "string", "format" => "date"},
    "homepage" => %{"type" => "string", "format" => "uri-reference"},
    "server_ip" => %{"type" => "string", "format" => "ipv4"}
  },
  "required" => ["email", "birth_date"]
}

{jsv_fmt_combo, jx_fmt_combo, xema_fmt_combo} = compile_both_fmt.(format_combo_schema, [])

fmt_combo_valid = %{
  "email" => "alice@example.com",
  "birth_date" => "1990-03-25",
  "homepage" => "/profile/alice",
  "server_ip" => "10.0.0.1"
}

fmt_combo_invalid = %{
  "email" => "not-an-email",
  "birth_date" => "not-a-date",
  "homepage" => "/foobar®.txt",
  "server_ip" => "999.0.0.1"
}

run_bench.("format_combo_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(fmt_combo_valid, jsv_fmt_combo) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_fmt_combo, fmt_combo_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_fmt_combo, fmt_combo_valid) end
})

run_bench.("format_combo_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(fmt_combo_invalid, jsv_fmt_combo) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_fmt_combo, fmt_combo_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_fmt_combo, fmt_combo_invalid) end
})

# --- dependencies ---

dependencies_schema = %{
  "dependencies" => %{
      "foo\tbar" => %{"minProperties" => 4},
      "foo'bar" => %{"required" => ["foo\"bar"]}
  }
}

{jsv_deps, jx_deps, xema_deps} = compile_both.(dependencies_schema, [])

deps_valid = %{
  "foo\tbar" => 1,
  "a" => 2,
  "b" => 3,
  "c" => 4
}

deps_invalid = %{"foo'bar" => %{"foo\"bar" => 1}}

run_bench.("dependencies_valid", %{
  "JSV" => fn -> {:ok, _} = JSV.validate(deps_valid, jsv_deps) end,
  "JSONSchex" => fn -> :ok = JSONSchex.validate(jx_deps, deps_valid) end,
  "JsonXema" => fn -> :ok = JsonXema.validate(xema_deps, deps_valid) end
})

run_bench.("dependencies_invalid", %{
  "JSV" => fn -> {:error, _} = JSV.validate(deps_invalid, jsv_deps) end,
  "JSONSchex" => fn -> {:error, _} = JSONSchex.validate(jx_deps, deps_invalid) end,
  "JsonXema" => fn -> {:error, _} = JsonXema.validate(xema_deps, deps_invalid) end
})



IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("  All benchmarks complete!")
IO.puts(String.duplicate("=", 60))

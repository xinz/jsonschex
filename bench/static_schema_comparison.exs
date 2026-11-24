# Static / Module-Based Schema & Short-Circuit Benchmark Suite (Benchee)
#
# Compares compile-time / module-based schemas, short-circuit `valid?/2`, and
# fast-path validation between JSONSchex and JSV across seven sections:
#   1. module        - Compile-time module schemas (`defvalidator` / `~X` vs JSV `defschema` + `@root`)
#   2. short_circuit - Fail-fast `valid?/2` vs full diagnostic `validate/2`
#   3. formats       - Format assertions (`uuid`, `date`, `date-time`, `time`, `duration`, `uri`, `email`)
#   4. patterns      - Predefined ASCII patterns vs complex regex
#   5. annotations   - Annotation-free fast paths vs `unevaluatedProperties`
#   6. ref           - Recursive `$defs` / `$ref` traversal
#   7. compile       - Schema compilation speed & compiled memory footprint (BEAM words)
#
# Run from the `bench` directory:
#   mix run static_schema_comparison.exs
#
# Filter sections or adjust Benchee timings via env vars:
#   BENCH=module mix run static_schema_comparison.exs
#   BENCH=short_circuit mix run static_schema_comparison.exs
#   BENCH=formats mix run static_schema_comparison.exs
#   BENCH_WARMUP=0.5 BENCH_TIME=1 BENCH_MEMORY_TIME=0.5 mix run static_schema_comparison.exs

{:ok, _} = Application.ensure_all_started(:jsv)
{:ok, _} = Application.ensure_all_started(:jsonschex)

parse_float_env = fn key, default ->
  case System.get_env(key) do
    nil -> default
    raw ->
      case Float.parse(raw) do
        {val, ""} when val >= 0 -> val
        _ -> default
      end
  end
end

bench_filter = System.get_env("BENCH", "all") |> String.downcase()

benchee_opts = [
  warmup: parse_float_env.("BENCH_WARMUP", 2.0),
  time: parse_float_env.("BENCH_TIME", 5.0),
  memory_time: parse_float_env.("BENCH_MEMORY_TIME", 2.0),
  formatters: [{Benchee.Formatters.Console, comparison: true}]
]

run_bench = fn name, cases ->
  if bench_filter == "all" or String.contains?(String.downcase(name), bench_filter) do
    IO.puts("\n" <> String.duplicate("=", 72))
    IO.puts("  Benchmark: #{name}")
    IO.puts(String.duplicate("=", 72))
    Benchee.run(cases, benchee_opts)
  end
end

# =============================================================================
# 1. Compile-Time / Module-Based Schemas
#
# JSV:       `use JSV.Schema` + `defschema` modules, with roots pre-built at
#            compile time (`@root JSV.build!(..., formats: true)`).
#            Measured both with `cast: false` (pure validation) and default
#            `cast: true` (validation + struct casting).
# JSONSchex: `use JSONSchex` with `defvalidator` (compiled BEAM clauses) and
#            compile-time embedded `~X` schemas (`valid?/2` & `validate/2`).
# =============================================================================

defmodule BenchJsv.User do
  use JSV.Schema

  defschema %{
    type: :object,
    properties: %{
      name: string(minLength: 1, maxLength: 64),
      email: string(format: :email),
      age: integer(minimum: 0, maximum: 150),
      role: string(enum: ["admin", "member", "guest"]),
      slug: string(pattern: "^[a-z0-9_-]+$")
    },
    required: [:name, :email, :age, :role, :slug],
    additionalProperties: false
  }
end

defmodule BenchJsv.Address do
  use JSV.Schema

  defschema %{
    type: :object,
    properties: %{
      country: string(pattern: "^[A-Z]{2}$"),
      city: string(minLength: 1),
      postal_code: string(pattern: "^\\d{5}$")
    },
    required: [:country, :city, :postal_code],
    additionalProperties: false
  }
end

defmodule BenchJsv.LineItem do
  use JSV.Schema

  defschema %{
    type: :object,
    properties: %{
      sku: string(pattern: "^[A-Z0-9-]{4,16}$"),
      qty: integer(minimum: 1, maximum: 1000),
      price: number(minimum: 0)
    },
    required: [:sku, :qty, :price],
    additionalProperties: false
  }
end

defmodule BenchJsv.Order do
  use JSV.Schema

  defschema %{
    type: :object,
    properties: %{
      order_id: string(format: :uuid),
      created_at: string(format: :"date-time"),
      shipping: BenchJsv.Address,
      items: array_of(BenchJsv.LineItem, minItems: 1)
    },
    required: [:order_id, :created_at, :shipping, :items],
    additionalProperties: false
  }
end

defmodule BenchJsv.CompiledRoots do
  @user_root JSV.build!(BenchJsv.User, formats: true)
  @order_root JSV.build!(BenchJsv.Order, formats: true)
  @batch_users_root JSV.build!(%{type: :array, items: BenchJsv.User}, formats: true)

  def user_root, do: @user_root
  def order_root, do: @order_root
  def batch_users_root, do: @batch_users_root
end

defmodule BenchJsonSchex.Validators do
  use JSONSchex

  @user_schema ~X|%{
    "type" => "object",
    "required" => ["name", "email", "age", "role", "slug"],
    "properties" => %{
      "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
      "email" => %{"type" => "string", "format" => "email"},
      "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
      "role" => %{"type" => "string", "enum" => ["admin", "member", "guest"]},
      "slug" => %{"type" => "string", "pattern" => "^[a-z0-9_-]+$"}
    },
    "additionalProperties" => false
  }|f

  @order_schema ~X|%{
    "type" => "object",
    "required" => ["order_id", "created_at", "shipping", "items"],
    "properties" => %{
      "order_id" => %{"type" => "string", "format" => "uuid"},
      "created_at" => %{"type" => "string", "format" => "date-time"},
      "shipping" => %{
        "type" => "object",
        "required" => ["country", "city", "postal_code"],
        "properties" => %{
          "country" => %{"type" => "string", "pattern" => "^[A-Z]{2}$"},
          "city" => %{"type" => "string", "minLength" => 1},
          "postal_code" => %{"type" => "string", "pattern" => "^\\d{5}$"}
        },
        "additionalProperties" => false
      },
      "items" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{
          "type" => "object",
          "required" => ["sku", "qty", "price"],
          "properties" => %{
            "sku" => %{"type" => "string", "pattern" => "^[A-Z0-9-]{4,16}$"},
            "qty" => %{"type" => "integer", "minimum" => 1, "maximum" => 1000},
            "price" => %{"type" => "number", "minimum" => 0}
          },
          "additionalProperties" => false
        }
      }
    },
    "additionalProperties" => false
  }|f

  @batch_users_schema ~X|%{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "required" => ["name", "email", "age", "role", "slug"],
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
        "email" => %{"type" => "string", "format" => "email"},
        "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
        "role" => %{"type" => "string", "enum" => ["admin", "member", "guest"]},
        "slug" => %{"type" => "string", "pattern" => "^[a-z0-9_-]+$"}
      },
      "additionalProperties" => false
    }
  }|f

  def user_schema, do: @user_schema
  def order_schema, do: @order_schema
  def batch_users_schema, do: @batch_users_schema

  defvalidator :validate_user, @user_schema
  defvalidator :validate_order, @order_schema
  defvalidator :validate_batch_users, @batch_users_schema

  # Format predicates
  defvalidator :valid_uuid?, ~X|%{"type" => "string", "format" => "uuid"}|f
  defvalidator :valid_date?, ~X|%{"type" => "string", "format" => "date"}|f
  defvalidator :valid_datetime?, ~X|%{"type" => "string", "format" => "date-time"}|f
  defvalidator :valid_time?, ~X|%{"type" => "string", "format" => "time"}|f
  defvalidator :valid_duration?, ~X|%{"type" => "string", "format" => "duration"}|f
  defvalidator :valid_uri?, ~X|%{"type" => "string", "format" => "uri"}|f
  defvalidator :valid_email?, ~X|%{"type" => "string", "format" => "email"}|f

  # Pattern predicates
  defvalidator :valid_pat_exact?, ~X|%{"type" => "string", "pattern" => "^active$"}|
  defvalidator :valid_pat_digits?, ~X|%{"type" => "string", "pattern" => "^\\d{4,8}$"}|
  defvalidator :valid_pat_slug?, ~X|%{"type" => "string", "pattern" => "^[a-z0-9_-]+$"}|
  defvalidator :valid_pat_complex?, %{"type" => "string", "pattern" => "^(?:foo|bar)-[0-9]{2,4}$"}

  # Combinators
  defvalidator :valid_anyof_10?, ~X|%{
    "anyOf" => [
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b1"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b2"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b3"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b4"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b5"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b6"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b7"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b8"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b9"}}},
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b10"}}}
    ]
  }|

  defvalidator :valid_oneof_10?, ~X|%{
    "oneOf" => [
      %{"type" => "integer", "minimum" => 0},
      %{"type" => "integer", "maximum" => 100},
      %{"type" => "integer", "minimum" => 200},
      %{"type" => "integer", "minimum" => 300},
      %{"type" => "integer", "minimum" => 400},
      %{"type" => "integer", "minimum" => 500},
      %{"type" => "integer", "minimum" => 600},
      %{"type" => "integer", "minimum" => 700},
      %{"type" => "integer", "minimum" => 800},
      %{"type" => "integer", "minimum" => 900}
    ]
  }|

  # Recursive $ref (hybrid fallback)
  defvalidator :valid_tree?, ~X|%{
    "$defs" => %{
      "node" => %{
        "type" => "object",
        "required" => ["value"],
        "properties" => %{
          "value" => %{"type" => "integer"},
          "left" => %{"$ref" => "#/$defs/node"},
          "right" => %{"$ref" => "#/$defs/node"}
        },
        "additionalProperties" => false
      }
    },
    "$ref" => "#/$defs/node"
  }|
end

user_valid = %{
  "name" => "Ada Lovelace",
  "email" => "ada@example.com",
  "age" => 36,
  "role" => "admin",
  "slug" => "ada_lovelace-01"
}

user_invalid = %{
  "name" => "",
  "email" => "not-an-email",
  "age" => -1,
  "role" => "superuser",
  "slug" => "INVALID!"
}

order_valid = %{
  "order_id" => "550e8400-e29b-41d4-a716-446655440000",
  "created_at" => "2026-04-12T23:20:50.520+08:00",
  "shipping" => %{
    "country" => "US",
    "city" => "Seattle",
    "postal_code" => "98101"
  },
  "items" =>
    for i <- 1..10 do
      %{"sku" => "SKU-#{1000 + i}", "qty" => rem(i, 5) + 1, "price" => i * 9.99}
    end
}

order_invalid = put_in(order_valid, ["items"], [
  %{"sku" => "bad!", "qty" => 0, "price" => -5} | tl(order_valid["items"])
])

batch_100_valid =
  for i <- 1..100 do
    %{
      "name" => "User #{i}",
      "email" => "user#{i}@example.com",
      "age" => 20 + rem(i, 50),
      "role" => Enum.at(["admin", "member", "guest"], rem(i, 3)),
      "slug" => "user_#{i}-profile"
    }
  end

batch_100_first_invalid = [user_invalid | tl(batch_100_valid)]

# Sanity-check parity for Section 1
jsv_user_root = BenchJsv.CompiledRoots.user_root()
jsv_order_root = BenchJsv.CompiledRoots.order_root()
jsv_batch_root = BenchJsv.CompiledRoots.batch_users_root()
jx_user_schema = BenchJsonSchex.Validators.user_schema()
jx_order_schema = BenchJsonSchex.Validators.order_schema()
jx_batch_schema = BenchJsonSchex.Validators.batch_users_schema()

true = BenchJsonSchex.Validators.validate_user?(user_valid)
:ok = BenchJsonSchex.Validators.validate_user(user_valid)
true = JSONSchex.valid?(jx_user_schema, user_valid)
:ok = JSONSchex.validate(jx_user_schema, user_valid)
true = JSV.valid?(user_valid, jsv_user_root, cast: false)
true = JSV.valid?(user_valid, jsv_user_root)
{:ok, _} = JSV.validate(user_valid, jsv_user_root, cast: false)
{:ok, %{__struct__: BenchJsv.User}} = JSV.validate(user_valid, jsv_user_root)

false = BenchJsonSchex.Validators.validate_user?(user_invalid)
{:error, _} = BenchJsonSchex.Validators.validate_user(user_invalid)
false = JSONSchex.valid?(jx_user_schema, user_invalid)
{:error, _} = JSONSchex.validate(jx_user_schema, user_invalid)
false = JSV.valid?(user_invalid, jsv_user_root, cast: false)
false = JSV.valid?(user_invalid, jsv_user_root)
{:error, _} = JSV.validate(user_invalid, jsv_user_root, cast: false)
{:error, _} = JSV.validate(user_invalid, jsv_user_root)

true = BenchJsonSchex.Validators.validate_order?(order_valid)
:ok = BenchJsonSchex.Validators.validate_order(order_valid)
{:ok, %{__struct__: BenchJsv.Order}} = JSV.validate(order_valid, jsv_order_root)
false = BenchJsonSchex.Validators.validate_order?(order_invalid)
false = JSV.valid?(order_invalid, jsv_order_root, cast: false)

true = BenchJsonSchex.Validators.validate_batch_users?(batch_100_valid)
true = JSV.valid?(batch_100_valid, jsv_batch_root, cast: false)
false = BenchJsonSchex.Validators.validate_batch_users?(batch_100_first_invalid)
false = JSV.valid?(batch_100_first_invalid, jsv_batch_root, cast: false)

run_bench.("module_user_valid", %{
  "JSONSchex defvalidator?" => fn -> true = BenchJsonSchex.Validators.validate_user?(user_valid) end,
  "JSONSchex defvalidator" => fn -> :ok = BenchJsonSchex.Validators.validate_user(user_valid) end,
  "JSONSchex ~X valid?" => fn -> true = JSONSchex.valid?(jx_user_schema, user_valid) end,
  "JSONSchex ~X validate" => fn -> :ok = JSONSchex.validate(jx_user_schema, user_valid) end,
  "JSV defschema valid? (cast: false)" => fn -> true = JSV.valid?(user_valid, jsv_user_root, cast: false) end,
  "JSV defschema valid? (cast: true)" => fn -> true = JSV.valid?(user_valid, jsv_user_root) end,
  "JSV defschema validate (cast: false)" => fn -> {:ok, _} = JSV.validate(user_valid, jsv_user_root, cast: false) end,
  "JSV defschema validate (cast: true)" => fn -> {:ok, _} = JSV.validate(user_valid, jsv_user_root) end
})

run_bench.("module_user_invalid", %{
  "JSONSchex defvalidator?" => fn -> false = BenchJsonSchex.Validators.validate_user?(user_invalid) end,
  "JSONSchex defvalidator" => fn -> {:error, _} = BenchJsonSchex.Validators.validate_user(user_invalid) end,
  "JSONSchex ~X valid?" => fn -> false = JSONSchex.valid?(jx_user_schema, user_invalid) end,
  "JSONSchex ~X validate" => fn -> {:error, _} = JSONSchex.validate(jx_user_schema, user_invalid) end,
  "JSV defschema valid? (cast: false)" => fn -> false = JSV.valid?(user_invalid, jsv_user_root, cast: false) end,
  "JSV defschema valid? (cast: true)" => fn -> false = JSV.valid?(user_invalid, jsv_user_root) end,
  "JSV defschema validate (cast: false)" => fn -> {:error, _} = JSV.validate(user_invalid, jsv_user_root, cast: false) end,
  "JSV defschema validate (cast: true)" => fn -> {:error, _} = JSV.validate(user_invalid, jsv_user_root) end
})

run_bench.("module_order_valid", %{
  "JSONSchex defvalidator?" => fn -> true = BenchJsonSchex.Validators.validate_order?(order_valid) end,
  "JSONSchex defvalidator" => fn -> :ok = BenchJsonSchex.Validators.validate_order(order_valid) end,
  "JSONSchex ~X valid?" => fn -> true = JSONSchex.valid?(jx_order_schema, order_valid) end,
  "JSONSchex ~X validate" => fn -> :ok = JSONSchex.validate(jx_order_schema, order_valid) end,
  "JSV defschema valid? (cast: false)" => fn -> true = JSV.valid?(order_valid, jsv_order_root, cast: false) end,
  "JSV defschema valid? (cast: true)" => fn -> true = JSV.valid?(order_valid, jsv_order_root) end,
  "JSV defschema validate (cast: false)" => fn -> {:ok, _} = JSV.validate(order_valid, jsv_order_root, cast: false) end,
  "JSV defschema validate (cast: true)" => fn -> {:ok, _} = JSV.validate(order_valid, jsv_order_root) end
})

run_bench.("module_order_invalid", %{
  "JSONSchex defvalidator?" => fn -> false = BenchJsonSchex.Validators.validate_order?(order_invalid) end,
  "JSONSchex defvalidator" => fn -> {:error, _} = BenchJsonSchex.Validators.validate_order(order_invalid) end,
  "JSONSchex ~X valid?" => fn -> false = JSONSchex.valid?(jx_order_schema, order_invalid) end,
  "JSONSchex ~X validate" => fn -> {:error, _} = JSONSchex.validate(jx_order_schema, order_invalid) end,
  "JSV defschema valid? (cast: false)" => fn -> false = JSV.valid?(order_invalid, jsv_order_root, cast: false) end,
  "JSV defschema validate (cast: false)" => fn -> {:error, _} = JSV.validate(order_invalid, jsv_order_root, cast: false) end,
  "JSV defschema validate (cast: true)" => fn -> {:error, _} = JSV.validate(order_invalid, jsv_order_root) end
})

run_bench.("module_batch_100_users_valid", %{
  "JSONSchex defvalidator?" => fn -> true = BenchJsonSchex.Validators.validate_batch_users?(batch_100_valid) end,
  "JSONSchex defvalidator" => fn -> :ok = BenchJsonSchex.Validators.validate_batch_users(batch_100_valid) end,
  "JSONSchex ~X valid?" => fn -> true = JSONSchex.valid?(jx_batch_schema, batch_100_valid) end,
  "JSONSchex ~X validate" => fn -> :ok = JSONSchex.validate(jx_batch_schema, batch_100_valid) end,
  "JSV defschema valid? (cast: false)" => fn -> true = JSV.valid?(batch_100_valid, jsv_batch_root, cast: false) end,
  "JSV defschema validate (cast: false)" => fn -> {:ok, _} = JSV.validate(batch_100_valid, jsv_batch_root, cast: false) end,
  "JSV defschema validate (cast: true)" => fn -> {:ok, _} = JSV.validate(batch_100_valid, jsv_batch_root) end
})

run_bench.("module_batch_100_users_1st_invalid", %{
  "JSONSchex defvalidator?" => fn -> false = BenchJsonSchex.Validators.validate_batch_users?(batch_100_first_invalid) end,
  "JSONSchex ~X valid?" => fn -> false = JSONSchex.valid?(jx_batch_schema, batch_100_first_invalid) end,
  "JSONSchex ~X validate" => fn -> {:error, _} = JSONSchex.validate(jx_batch_schema, batch_100_first_invalid) end,
  "JSV defschema valid? (cast: false)" => fn -> false = JSV.valid?(batch_100_first_invalid, jsv_batch_root, cast: false) end,
  "JSV defschema validate (cast: false)" => fn -> {:error, _} = JSV.validate(batch_100_first_invalid, jsv_batch_root, cast: false) end
})

# =============================================================================
# 2. Short-Circuit `valid?/2` vs Full Diagnostic `validate/2`
# =============================================================================

obj20_schema = %{
  "type" => "object",
  "required" => Enum.map(1..20, &"field_#{&1}"),
  "properties" =>
    Map.new(1..20, fn i ->
      {"field_#{i}", %{"type" => "integer", "minimum" => 0, "maximum" => 10_000}}
    end)
}

{:ok, jx_obj20} = JSONSchex.compile(obj20_schema)
jsv_obj20 = JSV.build!(obj20_schema)

obj20_valid = Map.new(1..20, fn i -> {"field_#{i}", i * 10} end)
obj20_all_invalid = Map.new(1..20, fn i -> {"field_#{i}", -i} end)

true = JSONSchex.valid?(jx_obj20, obj20_valid)
true = JSV.valid?(obj20_valid, jsv_obj20)
false = JSONSchex.valid?(jx_obj20, obj20_all_invalid)
false = JSV.valid?(obj20_all_invalid, jsv_obj20)

run_bench.("short_circuit_object_20_valid", %{
  "JSONSchex valid?/2" => fn -> true = JSONSchex.valid?(jx_obj20, obj20_valid) end,
  "JSONSchex validate/2" => fn -> :ok = JSONSchex.validate(jx_obj20, obj20_valid) end,
  "JSV valid?/2" => fn -> true = JSV.valid?(obj20_valid, jsv_obj20) end,
  "JSV validate/2" => fn -> {:ok, _} = JSV.validate(obj20_valid, jsv_obj20) end
})

run_bench.("short_circuit_object_20_all_invalid", %{
  "JSONSchex valid?/2" => fn -> false = JSONSchex.valid?(jx_obj20, obj20_all_invalid) end,
  "JSONSchex validate/2" => fn -> {:error, _} = JSONSchex.validate(jx_obj20, obj20_all_invalid) end,
  "JSV valid?/2" => fn -> false = JSV.valid?(obj20_all_invalid, jsv_obj20) end,
  "JSV validate/2" => fn -> {:error, _} = JSV.validate(obj20_all_invalid, jsv_obj20) end
})

arr1000_schema = %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 0}}
{:ok, jx_arr1000} = JSONSchex.compile(arr1000_schema)
jsv_arr1000 = JSV.build!(arr1000_schema)

arr1000_valid = Enum.to_list(1..1000)
arr1000_1st_invalid = ["bad" | Enum.to_list(2..1000)]
arr1000_all_invalid = List.duplicate("bad", 1000)

true = JSONSchex.valid?(jx_arr1000, arr1000_valid)
true = JSV.valid?(arr1000_valid, jsv_arr1000)
false = JSONSchex.valid?(jx_arr1000, arr1000_1st_invalid)
false = JSV.valid?(arr1000_1st_invalid, jsv_arr1000)

run_bench.("short_circuit_array_1000_valid", %{
  "JSONSchex valid?/2" => fn -> true = JSONSchex.valid?(jx_arr1000, arr1000_valid) end,
  "JSONSchex validate/2" => fn -> :ok = JSONSchex.validate(jx_arr1000, arr1000_valid) end,
  "JSV valid?/2" => fn -> true = JSV.valid?(arr1000_valid, jsv_arr1000) end,
  "JSV validate/2" => fn -> {:ok, _} = JSV.validate(arr1000_valid, jsv_arr1000) end
})

run_bench.("short_circuit_array_1000_1st_invalid", %{
  "JSONSchex valid?/2" => fn -> false = JSONSchex.valid?(jx_arr1000, arr1000_1st_invalid) end,
  "JSONSchex validate/2" => fn -> {:error, _} = JSONSchex.validate(jx_arr1000, arr1000_1st_invalid) end,
  "JSV valid?/2" => fn -> false = JSV.valid?(arr1000_1st_invalid, jsv_arr1000) end,
  "JSV validate/2" => fn -> {:error, _} = JSV.validate(arr1000_1st_invalid, jsv_arr1000) end
})

run_bench.("short_circuit_array_1000_all_invalid", %{
  "JSONSchex valid?/2" => fn -> false = JSONSchex.valid?(jx_arr1000, arr1000_all_invalid) end,
  "JSONSchex validate/2" => fn -> {:error, _} = JSONSchex.validate(jx_arr1000, arr1000_all_invalid) end,
  "JSV valid?/2" => fn -> false = JSV.valid?(arr1000_all_invalid, jsv_arr1000) end,
  "JSV validate/2" => fn -> {:error, _} = JSV.validate(arr1000_all_invalid, jsv_arr1000) end
})

anyof10_schema = %{
  "anyOf" =>
    for i <- 1..10 do
      %{"type" => "object", "required" => ["kind"], "properties" => %{"kind" => %{"const" => "b#{i}"}}}
    end
}

{:ok, jx_anyof10} = JSONSchex.compile(anyof10_schema)
jsv_anyof10 = JSV.build!(anyof10_schema)
anyof10_hit1 = %{"kind" => "b1"}

true = BenchJsonSchex.Validators.valid_anyof_10?(anyof10_hit1)
true = JSONSchex.valid?(jx_anyof10, anyof10_hit1)
true = JSV.valid?(anyof10_hit1, jsv_anyof10)

run_bench.("short_circuit_anyof_10_first_hit", %{
  "JSONSchex defvalidator?" => fn -> true = BenchJsonSchex.Validators.valid_anyof_10?(anyof10_hit1) end,
  "JSONSchex valid?/2" => fn -> true = JSONSchex.valid?(jx_anyof10, anyof10_hit1) end,
  "JSONSchex validate/2" => fn -> :ok = JSONSchex.validate(jx_anyof10, anyof10_hit1) end,
  "JSV valid?/2" => fn -> true = JSV.valid?(anyof10_hit1, jsv_anyof10) end,
  "JSV validate/2" => fn -> {:ok, _} = JSV.validate(anyof10_hit1, jsv_anyof10) end
})

oneof10_schema = %{
  "oneOf" =>
    [
      %{"type" => "integer", "minimum" => 0},
      %{"type" => "integer", "maximum" => 100}
    ] ++ for(i <- 2..9, do: %{"type" => "integer", "minimum" => i * 100})
}

{:ok, jx_oneof10} = JSONSchex.compile(oneof10_schema)
jsv_oneof10 = JSV.build!(oneof10_schema)
oneof10_2hits = 50

false = BenchJsonSchex.Validators.valid_oneof_10?(oneof10_2hits)
false = JSONSchex.valid?(jx_oneof10, oneof10_2hits)
false = JSV.valid?(oneof10_2hits, jsv_oneof10)

run_bench.("short_circuit_oneof_10_early_2_hits", %{
  "JSONSchex defvalidator?" => fn -> false = BenchJsonSchex.Validators.valid_oneof_10?(oneof10_2hits) end,
  "JSONSchex valid?/2" => fn -> false = JSONSchex.valid?(jx_oneof10, oneof10_2hits) end,
  "JSONSchex validate/2" => fn -> {:error, _} = JSONSchex.validate(jx_oneof10, oneof10_2hits) end,
  "JSV valid?/2" => fn -> false = JSV.valid?(oneof10_2hits, jsv_oneof10) end,
  "JSV validate/2" => fn -> {:error, _} = JSV.validate(oneof10_2hits, jsv_oneof10) end
})

# =============================================================================
# 3. Format Assertions (`format_assertion: true` vs JSV `formats: true`)
# =============================================================================

format_cases = [
  {"formats_uuid_valid", "uuid", "550e8400-e29b-41d4-a716-446655440000", true,
   &BenchJsonSchex.Validators.valid_uuid?/1},
  {"formats_uuid_invalid", "uuid", "550e8400-e29b-41d4-a716-44665544000g", false,
   &BenchJsonSchex.Validators.valid_uuid?/1},
  {"formats_date_valid", "date", "2024-02-29", true,
   &BenchJsonSchex.Validators.valid_date?/1},
  {"formats_datetime_valid", "date-time", "1985-04-12T23:20:50.520+08:00", true,
   &BenchJsonSchex.Validators.valid_datetime?/1},
  {"formats_time_valid", "time", "14:30:50.125+02:00", true,
   &BenchJsonSchex.Validators.valid_time?/1},
  {"formats_duration_valid", "duration", "P1Y2M3DT4H5M6S", true,
   &BenchJsonSchex.Validators.valid_duration?/1},
  {"formats_uri_valid", "uri", "https://example.com/api/v1/items?q=hello%20world#top", true,
   &BenchJsonSchex.Validators.valid_uri?/1},
  {"formats_email_valid", "email", "alice.smith+tag@example.co.uk", true,
   &BenchJsonSchex.Validators.valid_email?/1}
]

for {label, fmt, input, expected, pred_fn} <- format_cases do
  raw = %{"type" => "string", "format" => fmt}
  {:ok, jx_fmt} = JSONSchex.compile(raw, format_assertion: true)
  jsv_fmt = JSV.build!(raw, formats: true)

  ^expected = pred_fn.(input)
  ^expected = JSONSchex.valid?(jx_fmt, input)
  ^expected = JSONSchex.validate(jx_fmt, input) == :ok
  ^expected = JSV.valid?(input, jsv_fmt)
  ^expected = match?({:ok, _}, JSV.validate(input, jsv_fmt))

  run_bench.(label, %{
    "JSONSchex defvalidator?" => fn -> ^expected = pred_fn.(input) end,
    "JSONSchex valid?/2" => fn -> ^expected = JSONSchex.valid?(jx_fmt, input) end,
    "JSONSchex validate/2" => fn -> ^expected = JSONSchex.validate(jx_fmt, input) == :ok end,
    "JSV valid?/2" => fn -> ^expected = JSV.valid?(input, jsv_fmt) end,
    "JSV validate/2" => fn -> ^expected = match?({:ok, _}, JSV.validate(input, jsv_fmt)) end
  })
end

# =============================================================================
# 4. Pattern Validation (Predefined ASCII Matchers vs Regex Engine)
# =============================================================================

pattern_cases = [
  {"patterns_exact_valid", "^active$", "active", true,
   &BenchJsonSchex.Validators.valid_pat_exact?/1},
  {"patterns_digits_valid", "^\\d{4,8}$", "123456", true,
   &BenchJsonSchex.Validators.valid_pat_digits?/1},
  {"patterns_slug_valid", "^[a-z0-9_-]+$", "my-service_v2-prod", true,
   &BenchJsonSchex.Validators.valid_pat_slug?/1},
  {"patterns_complex_regex_valid", "^(?:foo|bar)-[0-9]{2,4}$", "bar-2026", true,
   &BenchJsonSchex.Validators.valid_pat_complex?/1}
]

for {label, pattern, input, expected, pred_fn} <- pattern_cases do
  raw = %{"type" => "string", "pattern" => pattern}
  {:ok, jx_pat} = JSONSchex.compile(raw)
  jsv_pat = JSV.build!(raw)

  ^expected = pred_fn.(input)
  ^expected = JSONSchex.valid?(jx_pat, input)
  ^expected = JSONSchex.validate(jx_pat, input) == :ok
  ^expected = JSV.valid?(input, jsv_pat)
  ^expected = match?({:ok, _}, JSV.validate(input, jsv_pat))

  run_bench.(label, %{
    "JSONSchex defvalidator?" => fn -> ^expected = pred_fn.(input) end,
    "JSONSchex valid?/2" => fn -> ^expected = JSONSchex.valid?(jx_pat, input) end,
    "JSONSchex validate/2" => fn -> ^expected = JSONSchex.validate(jx_pat, input) == :ok end,
    "JSV valid?/2" => fn -> ^expected = JSV.valid?(input, jsv_pat) end,
    "JSV validate/2" => fn -> ^expected = match?({:ok, _}, JSV.validate(input, jsv_pat)) end
  })
end

# =============================================================================
# 5. Annotation-Free vs Draft 2020-12 `unevaluatedProperties`
# =============================================================================

addl_true_schema = %{
  "type" => "object",
  "properties" => %{"id" => %{"type" => "integer"}},
  "additionalProperties" => true
}

{:ok, jx_addl_true} = JSONSchex.compile(addl_true_schema)
jsv_addl_true = JSV.build!(addl_true_schema)

addl_20_data =
  Map.merge(%{"id" => 1}, Map.new(1..20, fn i -> {"extra_#{i}", "v_#{i}"} end))

true = JSONSchex.valid?(jx_addl_true, addl_20_data)
true = JSV.valid?(addl_20_data, jsv_addl_true)

run_bench.("annotations_free_additional_true_20_keys", %{
  "JSONSchex valid?/2" => fn -> true = JSONSchex.valid?(jx_addl_true, addl_20_data) end,
  "JSONSchex validate/2" => fn -> :ok = JSONSchex.validate(jx_addl_true, addl_20_data) end,
  "JSV valid?/2" => fn -> true = JSV.valid?(addl_20_data, jsv_addl_true) end,
  "JSV validate/2" => fn -> {:ok, _} = JSV.validate(addl_20_data, jsv_addl_true) end
})

uneval_schema = %{
  "type" => "object",
  "anyOf" => [
    %{"properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "string"}}},
    %{"properties" => %{"b" => %{"type" => "string"}, "c" => %{"type" => "boolean"}}}
  ],
  "unevaluatedProperties" => false
}

{:ok, jx_uneval} = JSONSchex.compile(uneval_schema)
jsv_uneval = JSV.build!(uneval_schema)

uneval_valid = %{"a" => 1, "b" => "ok", "c" => true}
uneval_invalid = %{"a" => 1, "b" => "ok", "c" => true, "extra" => 99}

true = JSONSchex.valid?(jx_uneval, uneval_valid)
true = JSV.valid?(uneval_valid, jsv_uneval)
false = JSONSchex.valid?(jx_uneval, uneval_invalid)
false = JSV.valid?(uneval_invalid, jsv_uneval)

run_bench.("annotations_unevaluated_props_valid", %{
  "JSONSchex valid?/2" => fn -> true = JSONSchex.valid?(jx_uneval, uneval_valid) end,
  "JSONSchex validate/2" => fn -> :ok = JSONSchex.validate(jx_uneval, uneval_valid) end,
  "JSV valid?/2" => fn -> true = JSV.valid?(uneval_valid, jsv_uneval) end,
  "JSV validate/2" => fn -> {:ok, _} = JSV.validate(uneval_valid, jsv_uneval) end
})

run_bench.("annotations_unevaluated_props_invalid", %{
  "JSONSchex valid?/2" => fn -> false = JSONSchex.valid?(jx_uneval, uneval_invalid) end,
  "JSONSchex validate/2" => fn -> {:error, _} = JSONSchex.validate(jx_uneval, uneval_invalid) end,
  "JSV valid?/2" => fn -> false = JSV.valid?(uneval_invalid, jsv_uneval) end,
  "JSV validate/2" => fn -> {:error, _} = JSV.validate(uneval_invalid, jsv_uneval) end
})

# =============================================================================
# 6. Recursive `$defs` / `$ref` Traversal
# =============================================================================

tree_schema = %{
  "$defs" => %{
    "node" => %{
      "type" => "object",
      "required" => ["value"],
      "properties" => %{
        "value" => %{"type" => "integer"},
        "left" => %{"$ref" => "#/$defs/node"},
        "right" => %{"$ref" => "#/$defs/node"}
      },
      "additionalProperties" => false
    }
  },
  "$ref" => "#/$defs/node"
}

{:ok, jx_tree} = JSONSchex.compile(tree_schema)
jsv_tree = JSV.build!(tree_schema)

build_tree = fn
  _self, 0, val -> %{"value" => val}
  self, depth, val ->
    %{
      "value" => val,
      "left" => self.(self, depth - 1, val * 2),
      "right" => self.(self, depth - 1, val * 2 + 1)
    }
end

# 31 nodes (depth 4)
tree_valid = build_tree.(build_tree, 4, 1)
tree_invalid = put_in(tree_valid, ["left", "left", "left", "left", "value"], "bad")

true = BenchJsonSchex.Validators.valid_tree?(tree_valid)
true = JSONSchex.valid?(jx_tree, tree_valid)
true = JSV.valid?(tree_valid, jsv_tree)
false = BenchJsonSchex.Validators.valid_tree?(tree_invalid)
false = JSONSchex.valid?(jx_tree, tree_invalid)
false = JSV.valid?(tree_invalid, jsv_tree)

run_bench.("ref_recursive_tree_31_nodes_valid", %{
  "JSONSchex defvalidator?" => fn -> true = BenchJsonSchex.Validators.valid_tree?(tree_valid) end,
  "JSONSchex valid?/2" => fn -> true = JSONSchex.valid?(jx_tree, tree_valid) end,
  "JSONSchex validate/2" => fn -> :ok = JSONSchex.validate(jx_tree, tree_valid) end,
  "JSV valid?/2" => fn -> true = JSV.valid?(tree_valid, jsv_tree) end,
  "JSV validate/2" => fn -> {:ok, _} = JSV.validate(tree_valid, jsv_tree) end
})

run_bench.("ref_recursive_tree_31_nodes_invalid", %{
  "JSONSchex defvalidator?" => fn -> false = BenchJsonSchex.Validators.valid_tree?(tree_invalid) end,
  "JSONSchex valid?/2" => fn -> false = JSONSchex.valid?(jx_tree, tree_invalid) end,
  "JSONSchex validate/2" => fn -> {:error, _} = JSONSchex.validate(jx_tree, tree_invalid) end,
  "JSV valid?/2" => fn -> false = JSV.valid?(tree_invalid, jsv_tree) end,
  "JSV validate/2" => fn -> {:error, _} = JSV.validate(tree_invalid, jsv_tree) end
})

# =============================================================================
# 7. Schema Compilation Throughput & Compiled Memory Footprint
# =============================================================================

order_raw_schema = %{
  "type" => "object",
  "required" => ["order_id", "created_at", "shipping", "items"],
  "properties" => %{
    "order_id" => %{"type" => "string", "format" => "uuid"},
    "created_at" => %{"type" => "string", "format" => "date-time"},
    "shipping" => %{
      "type" => "object",
      "required" => ["country", "city", "postal_code"],
      "properties" => %{
        "country" => %{"type" => "string", "pattern" => "^[A-Z]{2}$"},
        "city" => %{"type" => "string", "minLength" => 1},
        "postal_code" => %{"type" => "string", "pattern" => "^\\d{5}$"}
      },
      "additionalProperties" => false
    },
    "items" => %{
      "type" => "array",
      "minItems" => 1,
      "items" => %{
        "type" => "object",
        "required" => ["sku", "qty", "price"],
        "properties" => %{
          "sku" => %{"type" => "string", "pattern" => "^[A-Z0-9-]{4,16}$"},
          "qty" => %{"type" => "integer", "minimum" => 1, "maximum" => 1000},
          "price" => %{"type" => "number", "minimum" => 0}
        },
        "additionalProperties" => false
      }
    }
  },
  "additionalProperties" => false
}

if bench_filter == "all" or String.contains?("compile", bench_filter) do
  IO.puts("\n" <> String.duplicate("=", 72))
  IO.puts("  Compiled Schema Footprint (BEAM words via :erts_debug.flat_size/1)")
  IO.puts(String.duplicate("=", 72))

  for {label, jx_term, jsv_term} <- [
        {"User (module/compiled)", jx_user_schema, jsv_user_root},
        {"Order (nested + items)", jx_order_schema, jsv_order_root},
        {"Object (20 typed props)", jx_obj20, jsv_obj20},
        {"Recursive Tree ($defs/$ref)", jx_tree, jsv_tree}
      ] do
    jx_words = :erts_debug.flat_size(jx_term)
    jsv_words = :erts_debug.flat_size(jsv_term)
    IO.puts("  #{String.pad_trailing(label, 30)} JSONSchex: #{String.pad_leading("#{jx_words}", 6)} words | JSV: #{String.pad_leading("#{jsv_words}", 6)} words")
  end
end

run_bench.("compile_order_schema", %{
  "JSONSchex.compile/2 (raw map)" => fn -> {:ok, _} = JSONSchex.compile(order_raw_schema, format_assertion: true) end,
  "JSV.build!/2 (raw map)" => fn -> JSV.build!(order_raw_schema, formats: true) end,
  "JSV.build!/2 (defschema module)" => fn -> JSV.build!(BenchJsv.Order, formats: true) end
})

run_bench.("compile_object_20_schema", %{
  "JSONSchex.compile/2" => fn -> {:ok, _} = JSONSchex.compile(obj20_schema) end,
  "JSV.build!/2" => fn -> JSV.build!(obj20_schema) end
})

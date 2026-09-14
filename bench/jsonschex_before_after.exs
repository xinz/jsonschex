# JSONSchex before/after benchmark using the original 52-case snapshot from
# `libs_comparison.exs`. Newer cross-library scale cases are tracked separately.
#
# Run from the `bench` directory:
#   mix run jsonschex_before_after.exs --baseline 0e3e2f40603fa5e57eff20ba8913861b10776572
#
# Select a case group with `BENCH`, as in `libs_comparison.exs`:
#   BENCH=array mix run jsonschex_before_after.exs --baseline REVISION
#   BENCH=inherited mix run jsonschex_before_after.exs --baseline REVISION
#   BENCH=optimization mix run jsonschex_before_after.exs --baseline REVISION
#
# Measurement durations default to the original comparison settings. Shorter
# exploratory runs can override them with BENCH_WARMUP, BENCH_TIME, and
# BENCH_MEMORY_TIME, expressed in seconds. Set BENCH_ORDER to `before_first` or
# `after_first`, and VERSION_BENCH_OUTPUT to persist raw statistics as TSV.

root = Path.expand("..", __DIR__)

baseline_revision =
  case System.argv() do
    ["--baseline", revision] -> revision
    _ -> raise "Usage: mix run jsonschex_before_after.exs --baseline REVISION"
  end

{baseline_commit, 0} =
  System.cmd("git", ["rev-parse", "#{baseline_revision}^{commit}"], cd: root, stderr_to_stdout: true)

{after_commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true)
baseline_commit = String.trim(baseline_commit)
after_commit = String.trim(after_commit)

{baseline_lib_tree, 0} =
  System.cmd("git", ["rev-parse", "#{baseline_commit}:lib"], cd: root, stderr_to_stdout: true)

current_lib_sources =
  root
  |> Path.join("lib/**/*.ex")
  |> Path.wildcard()
  |> Enum.sort()
  |> Enum.map_join(fn path ->
    Path.relative_to(path, root) <> <<0>> <> File.read!(path) <> <<0>>
  end)

current_lib_sha256 =
  current_lib_sources
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

{current_lib_status, 0} =
  System.cmd(
    "git",
    ["--no-optional-locks", "status", "--short", "--untracked-files=all", "--", "lib"],
    cd: root,
    stderr_to_stdout: true
  )

bench_lock_sha256 =
  __DIR__
  |> Path.join("mix.lock")
  |> File.read!()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

baseline_lib_tree = String.trim(baseline_lib_tree)
current_lib_dirty? = String.trim(current_lib_status) != ""

{:ok, _} = Application.ensure_all_started(:jsonschex)

defmodule JSONSchexBeforeAfterBench.Helpers do
  @moduledoc false

  def reorder_rules(schema, names) do
    rules = Map.fetch!(schema, :rules)

    selected =
      Enum.map(names, fn name ->
        Enum.find(rules, &(&1.name == name)) ||
          raise "expected compiled #{inspect(name)} rule"
      end)

    Map.put(schema, :rules, selected ++ Enum.reject(rules, &(&1.name in names)))
  end

  def run_job({operation, _opts}), do: operation.()
  def run_job(operation), do: operation.()

  def normalize_result(%Regex{source: source, opts: opts}), do: {:regex, source, opts}

  def normalize_result(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_result()
  end

  def normalize_result(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_result(key), normalize_result(value)} end)
  end

  def normalize_result(list) when is_list(list), do: Enum.map(list, &normalize_result/1)

  def normalize_result(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_result/1)
    |> List.to_tuple()
  end

  def normalize_result(value), do: value

end

{baseline_paths_output, 0} =
  System.cmd(
    "git",
    ["ls-tree", "-r", "--name-only", baseline_commit, "--", "lib"],
    cd: root,
    stderr_to_stdout: true
  )

baseline_source_paths =
  baseline_paths_output
  |> String.split("\n", trim: true)
  |> Enum.filter(&String.ends_with?(&1, ".ex"))

if baseline_source_paths == [] do
  raise "No Elixir library sources found at baseline #{baseline_revision}"
end

baseline_directory =
  Path.join(
    System.tmp_dir!(),
    "jsonschex-baseline-#{String.slice(baseline_revision, 0, 12)}-#{System.unique_integer([:positive])}"
  )

File.rm_rf!(baseline_directory)
File.mkdir_p!(baseline_directory)

baseline_files =
  Enum.map(baseline_source_paths, fn source_path ->
    case System.cmd("git", ["--no-pager", "show", "#{baseline_commit}:#{source_path}"], cd: root) do
      {source, 0} ->
        # A private namespace lets both complete JSONSchex implementations run in
        # the same BEAM and therefore in the same Benchee scenario.
        namespaced_source = Regex.replace(~r/\bJSONSchex\b/, source, "JSONSchexBaseline")
        destination = Path.join(baseline_directory, source_path)
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, namespaced_source)
        destination

      {output, status} ->
        raise "Cannot load #{source_path} from #{baseline_revision} (exit #{status}): #{output}"
    end
  end)

previous_compiler_options = Code.compiler_options(ignore_already_consolidated: true)

compilation_result =
  try do
    Kernel.ParallelCompiler.compile(baseline_files, return_diagnostics: true)
  after
    Code.compiler_options(previous_compiler_options)
  end

case compilation_result do
  {:ok, _modules, _diagnostics} -> :ok
  {:error, errors, warnings} -> raise "Cannot compile baseline: #{inspect({errors, warnings})}"
end

File.rm_rf!(baseline_directory)


bench_filter = System.get_env("BENCH", "all") |> String.downcase()
benchmark_order = System.get_env("BENCH_ORDER", "before_first") |> String.downcase()
output_path = System.get_env("VERSION_BENCH_OUTPUT")
results_key = {__MODULE__, :jsonschex_before_after_results}
Process.put(results_key, [])

unless benchmark_order in ["before_first", "after_first"] do
  raise "BENCH_ORDER must be either before_first or after_first"
end

IO.puts("Before: #{baseline_commit}")
IO.puts("After:  #{after_commit} plus current lib working-tree changes")
IO.puts("After lib SHA-256: #{current_lib_sha256}; dirty: #{current_lib_dirty?}")
IO.puts("Order:  #{benchmark_order}")

parse_duration = fn variable, default ->
  case System.get_env(variable) do
    nil ->
      default

    value ->
      case Float.parse(value) do
        {seconds, ""} when seconds >= 0 -> seconds
        _ -> raise "#{variable} must be a non-negative number, got: #{inspect(value)}"
      end
  end
end

warmup_seconds = parse_duration.("BENCH_WARMUP", 2)
time_seconds = parse_duration.("BENCH_TIME", 5)
memory_time_seconds = parse_duration.("BENCH_MEMORY_TIME", 2)


benchee_opts = [
  warmup: warmup_seconds,
  time: time_seconds,
  memory_time: memory_time_seconds,
  formatters: [{Benchee.Formatters.Console, comparison: true}]
]

compile_versions = fn schema, opts ->
  case benchmark_order do
    "before_first" ->
      {:ok, before_schema} = JSONSchexBaseline.compile(schema, opts)
      {:ok, after_schema} = JSONSchex.compile(schema, opts)
      {before_schema, after_schema}

    "after_first" ->
      {:ok, after_schema} = JSONSchex.compile(schema, opts)
      {:ok, before_schema} = JSONSchexBaseline.compile(schema, opts)
      {before_schema, after_schema}
  end
end

case_selected? = fn name ->
  optimization_case? = String.starts_with?(name, "optimization_")

  case bench_filter do
    "all" -> true
    "inherited" -> !optimization_case?
    "optimization" -> optimization_case?
    filter -> String.contains?(name, filter)
  end
end

case_metadata = fn name ->
  case String.split(name, "_", parts: 4) do
    ["optimization", operation, focus, _workload] ->
      %{origin: "optimization", operation: operation, focus: focus}

    _inherited ->
      %{origin: "inherited", operation: "validate", focus: "broad"}
  end
end

run_bench = fn name, cases ->
  if case_selected?.(name) do
    metadata = case_metadata.(name)

    if metadata.origin == "inherited" do
      [first_version, second_version] =
        case benchmark_order do
          "before_first" -> ["Before", "After"]
          "after_first" -> ["After", "Before"]
        end

      first_result = cases |> Map.fetch!(first_version) |> JSONSchexBeforeAfterBench.Helpers.run_job()
      second_result = cases |> Map.fetch!(second_version) |> JSONSchexBeforeAfterBench.Helpers.run_job()

      normalized_results = %{
        first_version => JSONSchexBeforeAfterBench.Helpers.normalize_result(first_result),
        second_version => JSONSchexBeforeAfterBench.Helpers.normalize_result(second_result)
      }

      unless normalized_results["Before"] === normalized_results["After"] do
        raise "inherited case #{name} returned different results in Before and After: " <>
                "#{inspect(normalized_results)}"
      end
    end

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("  Benchmark: #{name}")
    IO.puts(String.duplicate("=", 60))

    ordered_versions =
      case benchmark_order do
        "before_first" -> ["Before", "After"]
        "after_first" -> ["After", "Before"]
      end

    jobs = Enum.map(ordered_versions, &{&1, Map.fetch!(cases, &1)})
    suite = Benchee.run(jobs, benchee_opts)

    scenario_results =
      Map.new(suite.scenarios, fn scenario ->
        {scenario.job_name,
         %{
           run_time: scenario.run_time_data.statistics,
           memory: scenario.memory_usage_data.statistics
         }}
      end)

    Process.put(results_key, [{name, metadata, scenario_results} | Process.get(results_key)])
  end
end

run_optimization_bench = fn name, build_cases ->
  if case_selected?.(name) do
    run_bench.(name, build_cases.())
  end
end

prepare_pair = fn before_operation, after_operation, verify_results ->
  {before_result, after_result} =
    case benchmark_order do
      "before_first" ->
        before_result = before_operation.()
        after_result = after_operation.()
        {before_result, after_result}

      "after_first" ->
        after_result = after_operation.()
        before_result = before_operation.()
        {before_result, after_result}
    end

  verify_results.(before_result, after_result)
  %{"Before" => before_operation, "After" => after_operation}
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

{before_simple, after_simple} = compile_versions.(simple_schema, [])

simple_valid = "hello"
simple_invalid = "hi"

run_bench.("simple_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_simple, simple_valid) end,
  "After" => fn -> JSONSchex.validate(after_simple, simple_valid) end,
})

run_bench.("simple_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_simple, simple_invalid) end,
  "After" => fn -> JSONSchex.validate(after_simple, simple_invalid) end
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

{before_nested, after_nested} = compile_versions.(nested_obj_schema, [])

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
  "Before" => fn -> JSONSchexBaseline.validate(before_nested, nested_valid) end,
  "After" => fn -> JSONSchex.validate(after_nested, nested_valid) end,
})

run_bench.("nested_object_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_nested, nested_invalid) end,
  "After" => fn -> JSONSchex.validate(after_nested, nested_invalid) end,
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

{before_ref, after_ref} = compile_versions.(ref_schema, [])

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
  "Before" => fn -> JSONSchexBaseline.validate(before_ref, ref_valid) end,
  "After" => fn -> JSONSchex.validate(after_ref, ref_valid) end
})

run_bench.("ref_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_ref, ref_invalid) end,
  "After" => fn -> JSONSchex.validate(after_ref, ref_invalid) end
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

{before_array, after_array} = compile_versions.(array_schema, [])

array_valid_small = Enum.map(1..10, &%{"id" => &1, "value" => "item-#{&1}"})
array_valid_large = Enum.map(1..100, &%{"id" => &1, "value" => "item-#{&1}"})
array_invalid = Enum.map(1..10, &%{"id" => "bad", "value" => &1})

run_bench.("array_small_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_array, array_valid_small) end,
  "After" => fn -> JSONSchex.validate(after_array, array_valid_small) end,
})

run_bench.("array_large_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_array, array_valid_large) end,
  "After" => fn -> JSONSchex.validate(after_array, array_valid_large) end,
})

run_bench.("array_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_array, array_invalid) end,
  "After" => fn -> JSONSchex.validate(after_array, array_invalid) end,
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

{before_prefix, after_prefix} = compile_versions.(prefix_contains_schema, [])

prefix_valid = ["hello", 42, true, "extra", 15]
prefix_invalid = ["hello", "not int", true, 1]

run_bench.("array_prefix_contains_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_prefix, prefix_valid) end,
  "After" => fn -> JSONSchex.validate(after_prefix, prefix_valid) end,
})

run_bench.("array_prefix_contains_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_prefix, prefix_invalid) end,
  "After" => fn -> JSONSchex.validate(after_prefix, prefix_invalid) end,
})

# --- uniqueItems ---

unique_schema = %{"type" => "array", "uniqueItems" => true}
{before_unique, after_unique} = compile_versions.(unique_schema, [])

unique_valid = Enum.to_list(1..50)
unique_invalid = Enum.to_list(1..49) ++ [1]

run_bench.("array_unique_items_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_unique, unique_valid) end,
  "After" => fn -> JSONSchex.validate(after_unique, unique_valid) end,
})

run_bench.("array_unique_items_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_unique, unique_invalid) end,
  "After" => fn -> JSONSchex.validate(after_unique, unique_invalid) end,
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

{before_allof, after_allof} = compile_versions.(allof_schema, [])

allof_valid = %{"name" => "Alice", "age" => 30, "email" => "alice@example.com"}
allof_invalid = %{"name" => "", "age" => -1}

run_bench.("allof_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_allof, allof_valid) end,
  "After" => fn -> JSONSchex.validate(after_allof, allof_valid) end,
})

run_bench.("allof_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_allof, allof_invalid) end,
  "After" => fn -> JSONSchex.validate(after_allof, allof_invalid) end,
})

# --- anyOf ---

anyof_schema = %{
  "anyOf" => [
    %{"type" => "object", "properties" => %{"kind" => %{"const" => "person"}, "name" => %{"type" => "string"}}, "required" => ["kind", "name"]},
    %{"type" => "object", "properties" => %{"kind" => %{"const" => "org"}, "title" => %{"type" => "string"}}, "required" => ["kind", "title"]},
    %{"type" => "object", "properties" => %{"kind" => %{"const" => "bot"}, "version" => %{"type" => "integer"}}, "required" => ["kind", "version"]}
  ]
}

{before_anyof, after_anyof} = compile_versions.(anyof_schema, [])

anyof_valid = %{"kind" => "org", "title" => "Acme Corp"}
anyof_invalid = %{"kind" => "unknown", "data" => 123}

run_bench.("anyof_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_anyof, anyof_valid) end,
  "After" => fn -> JSONSchex.validate(after_anyof, anyof_valid) end,
})

run_bench.("anyof_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_anyof, anyof_invalid) end,
  "After" => fn -> JSONSchex.validate(after_anyof, anyof_invalid) end,
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

{before_oneof, after_oneof} = compile_versions.(oneof_schema, [])

oneof_valid = %{"type" => "c", "c_field" => true}
oneof_invalid = %{"type" => "x", "x_field" => "nope"}

run_bench.("oneof_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_oneof, oneof_valid) end,
  "After" => fn -> JSONSchex.validate(after_oneof, oneof_valid) end,
})

run_bench.("oneof_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_oneof, oneof_invalid) end,
  "After" => fn -> JSONSchex.validate(after_oneof, oneof_invalid) end,
})

# --- not ---

not_schema = %{
  "not" => %{
    "type" => "object",
    "properties" => %{"role" => %{"const" => "admin"}},
    "required" => ["role"]
  }
}

{before_not, after_not} = compile_versions.(not_schema, [])

not_valid = %{"role" => "user"}
not_invalid = %{"role" => "admin"}

run_bench.("not_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_not, not_valid) end,
  "After" => fn -> JSONSchex.validate(after_not, not_valid) end,
})

run_bench.("not_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_not, not_invalid) end,
  "After" => fn -> JSONSchex.validate(after_not, not_invalid) end,
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

{before_cond, after_cond} = compile_versions.(conditional_schema, [])

cond_valid_us = %{"country" => "US", "postal_code" => "90210"}
cond_valid_ca = %{"country" => "CA", "postal_code" => "K1A 0B1"}
cond_invalid_us = %{"country" => "US", "postal_code" => "ABCDE"}

run_bench.("conditional_valid_then", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_cond, cond_valid_us) end,
  "After" => fn -> JSONSchex.validate(after_cond, cond_valid_us) end,
})

run_bench.("conditional_valid_else", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_cond, cond_valid_ca) end,
  "After" => fn -> JSONSchex.validate(after_cond, cond_valid_ca) end,
})

run_bench.("conditional_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_cond, cond_invalid_us) end,
  "After" => fn -> JSONSchex.validate(after_cond, cond_invalid_us) end,
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

{before_addl, after_addl} = compile_versions.(addl_pattern_schema, [])

addl_valid = %{"name" => "Alice", "age" => 30, "x-custom" => "value", "x-tag" => "important"}
addl_invalid = %{"name" => "Bob", "age" => 25, "unknown_field" => true}

run_bench.("additional_pattern_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_addl, addl_valid) end,
  "After" => fn -> JSONSchex.validate(after_addl, addl_valid) end,
})

run_bench.("additional_pattern_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_addl, addl_invalid) end,
  "After" => fn -> JSONSchex.validate(after_addl, addl_invalid) end,
})

# --- additionalProperties with schema (not just false) ---

addl_schema_schema = %{
  "type" => "object",
  "properties" => %{
    "id" => %{"type" => "integer"}
  },
  "additionalProperties" => %{"type" => "string", "maxLength" => 100}
}

{before_addl_s, after_addl_s} = compile_versions.(addl_schema_schema, [])

addl_s_valid = %{"id" => 1, "name" => "Alice", "email" => "a@b.com", "city" => "NYC", "role" => "admin"}
addl_s_invalid = %{"id" => 1, "name" => 123, "email" => true}

run_bench.("additional_schema_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_addl_s, addl_s_valid) end,
  "After" => fn -> JSONSchex.validate(after_addl_s, addl_s_valid) end,
})

run_bench.("additional_schema_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_addl_s, addl_s_invalid) end,
  "After" => fn -> JSONSchex.validate(after_addl_s, addl_s_invalid) end,
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

{before_uneval, after_uneval} = compile_versions.(uneval_schema, [])

uneval_valid_admin = %{"name" => "admin", "level" => 5}
uneval_valid_user = %{"name" => "alice", "email" => "a@b.com"}
uneval_invalid = %{"name" => "bob", "email" => "b@c.com", "extra" => true}

run_bench.("unevaluated_valid_then", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_uneval, uneval_valid_admin) end,
  "After" => fn -> JSONSchex.validate(after_uneval, uneval_valid_admin) end
})

run_bench.("unevaluated_valid_else", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_uneval, uneval_valid_user) end,
  "After" => fn -> JSONSchex.validate(after_uneval, uneval_valid_user) end
})

run_bench.("unevaluated_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_uneval, uneval_invalid) end,
  "After" => fn -> JSONSchex.validate(after_uneval, uneval_invalid) end
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

{before_dep, after_dep} = compile_versions.(dependent_schema, [])

dep_valid = %{"name" => "Alice", "credit_card" => "1234-5678", "billing_address" => "123 Main St"}
dep_invalid_missing = %{"name" => "Bob", "credit_card" => "1234-5678"}
dep_invalid_schema = %{"name" => "Eve", "credit_card" => "1234", "billing_address" => "Hi"}

run_bench.("dependent_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_dep, dep_valid) end,
  "After" => fn -> JSONSchex.validate(after_dep, dep_valid) end
})

run_bench.("dependent_invalid_missing", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_dep, dep_invalid_missing) end,
  "After" => fn -> JSONSchex.validate(after_dep, dep_invalid_missing) end
})

run_bench.("dependent_invalid_schema", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_dep, dep_invalid_schema) end,
  "After" => fn -> JSONSchex.validate(after_dep, dep_invalid_schema) end
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

{before_large, after_large} = compile_versions.(large_schema, [])

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
  "Before" => fn -> JSONSchexBaseline.validate(before_large, large_valid) end,
  "After" => fn -> JSONSchex.validate(after_large, large_valid) end,
})

run_bench.("large_payload_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_large, large_invalid) end,
  "After" => fn -> JSONSchex.validate(after_large, large_invalid) end,
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

{before_pn, after_pn} = compile_versions.(propnames_schema, [])

pn_valid = Enum.into(1..15, %{}, fn i -> {"field_#{i}", "value"} end)
pn_invalid = Map.put(pn_valid, "INVALID-KEY!", "value")

run_bench.("property_names_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_pn, pn_valid) end,
  "After" => fn -> JSONSchex.validate(after_pn, pn_valid) end,
})

run_bench.("property_names_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_pn, pn_invalid) end,
  "After" => fn -> JSONSchex.validate(after_pn, pn_invalid) end,
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

# Keep a separate helper at the same boundary as the source benchmark; both
# JSONSchex revisions enforce the configured format vocabulary themselves.
compile_format_versions = fn schema, opts ->
  compile_versions.(schema, opts)
end

{before_fmt_email, after_fmt_email} = compile_format_versions.(format_email_schema, [])
{before_fmt_date, after_fmt_date} = compile_format_versions.(format_date_schema, [])
{before_fmt_uri, after_fmt_uri} = compile_format_versions.(format_uri_ref_schema, [])
{before_fmt_ipv4, after_fmt_ipv4} = compile_format_versions.(format_ipv4_schema, [])
{before_fmt_iri_ref, after_fmt_iri_ref} = compile_format_versions.(format_iri_ref_schema, [])

# --- email ---

fmt_email_valid = "alice@example.com"
fmt_email_invalid = "not-an-email"

run_bench.("format_email_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_email, fmt_email_valid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_email, fmt_email_valid) end,
})

run_bench.("format_email_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_email, fmt_email_invalid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_email, fmt_email_invalid) end,
})

# --- date ---

fmt_date_valid = "2024-06-15"
fmt_date_invalid = "2024-13-45"

run_bench.("format_date_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_date, fmt_date_valid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_date, fmt_date_valid) end,
})

run_bench.("format_date_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_date, fmt_date_invalid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_date, fmt_date_invalid) end,
})

# --- iri-reference ---

fmt_iri_ref_valid = "#ƒrägmênt"
fmt_iri_ref_invalid = "\\\\WINDOWS\\filëßåré"

run_bench.("format_iri_ref_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_iri_ref, fmt_iri_ref_valid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_iri_ref, fmt_iri_ref_valid) end
})

run_bench.("format_iri_ref_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_iri_ref, fmt_iri_ref_invalid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_iri_ref, fmt_iri_ref_invalid) end
})

# --- uri ---

fmt_uri_valid = "/api/v2/users?page=1&limit=50"
fmt_uri_invalid = "https://example.org/foobar\\.txt"

run_bench.("format_uri_ref_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_uri, fmt_uri_valid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_uri, fmt_uri_valid) end,
})

run_bench.("format_uri_ref_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_uri, fmt_uri_invalid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_uri, fmt_uri_invalid) end,
})

# --- ipv4 ---

fmt_ipv4_valid = "192.168.1.100"
fmt_ipv4_invalid = "999.999.999.999"

run_bench.("format_ipv4_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_ipv4, fmt_ipv4_valid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_ipv4, fmt_ipv4_valid) end,
})

run_bench.("format_ipv4_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_ipv4, fmt_ipv4_invalid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_ipv4, fmt_ipv4_invalid) end,
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

{before_fmt_combo, after_fmt_combo} = compile_format_versions.(format_combo_schema, [])

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
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_combo, fmt_combo_valid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_combo, fmt_combo_valid) end,
})

run_bench.("format_combo_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_fmt_combo, fmt_combo_invalid) end,
  "After" => fn -> JSONSchex.validate(after_fmt_combo, fmt_combo_invalid) end,
})

# --- dependencies ---

dependencies_schema = %{
  "dependencies" => %{
      "foo\tbar" => %{"minProperties" => 4},
      "foo'bar" => %{"required" => ["foo\"bar"]}
  }
}

{before_deps, after_deps} = compile_versions.(dependencies_schema, [])

deps_valid = %{
  "foo\tbar" => 1,
  "a" => 2,
  "b" => 3,
  "c" => 4
}

deps_invalid = %{"foo'bar" => %{"foo\"bar" => 1}}

run_bench.("dependencies_valid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_deps, deps_valid) end,
  "After" => fn -> JSONSchex.validate(after_deps, deps_valid) end,
})

run_bench.("dependencies_invalid", %{
  "Before" => fn -> JSONSchexBaseline.validate(before_deps, deps_invalid) end,
  "After" => fn -> JSONSchex.validate(after_deps, deps_invalid) end,
})

# =============================================================================
# Optimization-focused cases
#
# These cases isolate the implementation work from 9ab9748 through the current
# main branch. Their setup and correctness checks are outside Benchee timing.
# =============================================================================

run_optimization_bench.("optimization_bundle_p1_structural_depth_400", fn ->
  schema =
    Enum.reduce(1..400, %{"type" => "integer"}, fn _, child ->
      %{"properties" => %{"child" => child}}
    end)

  before_operation = fn -> JSONSchexBaseline.bundle_fragment(schema, entry: "#") end
  after_operation = fn -> JSONSchex.bundle_fragment(schema, entry: "#") end

  prepare_pair.(before_operation, after_operation, fn before_result, after_result ->
    unless before_result === after_result do
      raise "P1 structural bundle output differs between Before and After"
    end
  end)
end)

run_optimization_bench.("optimization_bundle_p2_fallback_anchors_2000", fn ->
  document = %{
    "schema" => %{},
    "x-candidates" => List.duplicate(%{"$anchor" => "same"}, 2_000)
  }

  before_operation = fn -> JSONSchexBaseline.bundle_fragment(document, entry: "#/schema") end
  after_operation = fn -> JSONSchex.bundle_fragment(document, entry: "#/schema") end

  prepare_pair.(before_operation, after_operation, fn before_result, after_result ->
    unless before_result === after_result do
      raise "P2 fallback-anchor bundle output differs between Before and After"
    end
  end)
end)

run_optimization_bench.("optimization_bundle_p3_identity_alias_payload_2000", fn ->
  payload = List.duplicate(%{"nested" => [%{"$ref" => "/api/value.json#value"}]}, 2_000)
  document = %{"$ref" => "/api/value.json", "x-payload" => payload}

  loader = fn "/api/value.json" ->
    {:ok,
     %{
       document: %{"type" => "integer", "x-payload" => payload},
       base_uri: "/api/value.json"
     }}
  end

  opts = [entry: "#", base_uri: "/api/root.json", loader: loader]

  before_operation = fn -> JSONSchexBaseline.bundle_fragment(document, opts) end
  after_operation = fn -> JSONSchex.bundle_fragment(document, opts) end

  prepare_pair.(before_operation, after_operation, fn before_result, after_result ->
    unless before_result === after_result do
      raise "P3 identity-alias bundle output differs between Before and After"
    end
  end)
end)

run_optimization_bench.("optimization_compile_p4_scope_reuse_depth_400", fn ->
  leaf = %{
    "$id" => "https://compiler-reuse.example/leaf",
    "type" => "integer"
  }

  schema =
    Enum.reduce(1..400, leaf, fn index, child ->
      %{
        "$id" => "https://compiler-reuse.example/node/#{index}",
        "properties" => %{"child" => child}
      }
    end)

  valid_data = Enum.reduce(1..400, 1, fn _, child -> %{"child" => child} end)
  invalid_data = Enum.reduce(1..400, "not-an-integer", fn _, child -> %{"child" => child} end)

  before_operation = fn -> JSONSchexBaseline.compile(schema) end
  after_operation = fn -> JSONSchex.compile(schema) end

  prepare_pair.(before_operation, after_operation, fn before_result, after_result ->
    {:ok, before_compiled} = before_result
    {:ok, after_compiled} = after_result

    unless JSONSchexBaseline.validate(before_compiled, valid_data) == :ok &&
             JSONSchex.validate(after_compiled, valid_data) == :ok do
      raise "P4 scope-reuse compiled schemas rejected valid nested data"
    end

    for result <- [
          JSONSchexBaseline.validate(before_compiled, invalid_data),
          JSONSchex.validate(after_compiled, invalid_data)
        ] do
      case result do
        {:error, [%{rule: :type}]} -> :ok
        other -> raise "P4 scope-reuse compiled schema returned #{inspect(other)}"
      end
    end
  end)
end)

run_optimization_bench.("optimization_compile_p4_local_ref_reuse_width_200", fn ->
  definition = %{
    "type" => "object",
    "required" => ["field1"],
    "properties" =>
      Map.new(1..19, fn index ->
        {"field#{index}", %{"type" => "string", "minLength" => 1, "maxLength" => 80}}
      end)
  }

  schema = %{
    "type" => "object",
    "$defs" => Map.new(1..200, fn index -> {"def#{index}", definition} end),
    "properties" =>
      Map.new(1..200, fn index ->
        {"value#{index}", %{"$ref" => "#/$defs/def#{index}"}}
      end)
  }

  valid_data = Map.new(1..200, fn index -> {"value#{index}", %{"field1" => "value"}} end)
  invalid_data = %{"value1" => %{}}

  before_operation = fn -> JSONSchexBaseline.compile(schema) end
  after_operation = fn -> JSONSchex.compile(schema) end

  prepare_pair.(before_operation, after_operation, fn before_result, after_result ->
    {:ok, before_compiled} = before_result
    {:ok, after_compiled} = after_result

    unless JSONSchexBaseline.validate(before_compiled, valid_data) == :ok &&
             JSONSchex.validate(after_compiled, valid_data) == :ok do
      raise "P4 local-ref compiled schemas rejected valid referenced data"
    end

    for result <- [
          JSONSchexBaseline.validate(before_compiled, invalid_data),
          JSONSchex.validate(after_compiled, invalid_data)
        ] do
      case result do
        {:error, [%{rule: :required, context: %{contrast: ["field1"]}}]} -> :ok
        other -> raise "P4 local-ref compiled schema returned #{inspect(other)}"
      end
    end
  end)
end)

run_optimization_bench.("optimization_compile_p6_sibling_regex_width_512", fn ->
  patterns =
    Map.new(1..512, fn index ->
      {"^\\p{Letter}#{index}\\s*$", true}
    end)

  schema = %{
    "patternProperties" => patterns,
    "additionalProperties" => true
  }

  before_operation = fn -> JSONSchexBaseline.compile(schema) end
  after_operation = fn -> JSONSchex.compile(schema) end

  prepare_pair.(before_operation, after_operation, fn before_result, after_result ->
    {:ok, before_compiled} = before_result
    {:ok, after_compiled} = after_result

    normalize_regex_rules = fn compiled ->
      rules = Map.fetch!(compiled, :rules)
      pattern_rule = Enum.find(rules, &(&1.name == :patternProperties))
      additional_rule = Enum.find(rules, &(&1.name == :additionalProperties))

      unless pattern_rule && additional_rule && length(pattern_rule.params) == 512 do
        raise "P6 sibling-regex compilation did not retain both object rules"
      end

      {
        Enum.map(pattern_rule.params, fn {regex, _sub_schema} -> Regex.source(regex) end),
        Enum.map(additional_rule.params.patterns, &Regex.source/1)
      }
    end

    unless normalize_regex_rules.(before_compiled) === normalize_regex_rules.(after_compiled) &&
             JSONSchexBaseline.validate(before_compiled, %{"A1 " => true}) == :ok &&
             JSONSchex.validate(after_compiled, %{"A1 " => true}) == :ok do
      raise "P6 sibling-regex compiled schemas differ in rules or behavior"
    end
  end)
end)

run_optimization_bench.("optimization_validate_p5_unicode_long_valid", fn ->
  data = String.duplicate("😀", 10_000)
  schema = %{"minLength" => 10_000, "maxLength" => 10_000}
  {before_schema, after_schema} = compile_versions.(schema, [])

  prepare_pair.(
    fn -> JSONSchexBaseline.validate(before_schema, data) end,
    fn -> JSONSchex.validate(after_schema, data) end,
    fn before_result, after_result ->
      unless before_result == :ok && after_result == :ok do
        raise "P5 long-Unicode validation must pass in both versions"
      end
    end
  )
end)

run_optimization_bench.("optimization_validate_p7_pattern_cache_width_16", fn ->
  patterns =
    Map.new(1..16, fn index ->
      {"^pattern-#{index}$", %{"type" => "string"}}
    end)

  schema = %{
    "patternProperties" => patterns,
    "additionalProperties" => true,
    "unevaluatedProperties" => false
  }

  data = Map.new(1..16, fn index -> {"field-#{index}", index} end)
  {before_schema, after_schema} = compile_versions.(schema, [])

  before_schema =
    JSONSchexBeforeAfterBench.Helpers.reorder_rules(
      before_schema,
      [:patternProperties, :additionalProperties, :unevaluatedProperties]
    )

  after_schema =
    JSONSchexBeforeAfterBench.Helpers.reorder_rules(
      after_schema,
      [:patternProperties, :additionalProperties, :unevaluatedProperties]
    )

  prepare_pair.(
    fn -> JSONSchexBaseline.validate(before_schema, data) end,
    fn -> JSONSchex.validate(after_schema, data) end,
    fn before_result, after_result ->
      unless before_result == :ok && after_result == :ok do
        raise "P7 pattern-cache validation must pass in both versions"
      end
    end
  )
end)

run_optimization_bench.("optimization_validate_p8_anyof_parent_dominated_width_16", fn ->
  parent_fields = Enum.map(1..16, &"parent-#{&1}")
  branch_fields = Enum.map(1..16, &"branch-#{&1}")

  schema = %{
    "properties" => Map.new(parent_fields, &{&1, true}),
    "anyOf" =>
      Enum.map(branch_fields, fn field ->
        %{"properties" => %{field => true}}
      end),
    "unevaluatedProperties" => false
  }

  data = Map.new(parent_fields ++ branch_fields, &{&1, true})
  {before_schema, after_schema} = compile_versions.(schema, [])

  before_schema =
    JSONSchexBeforeAfterBench.Helpers.reorder_rules(
      before_schema,
      [:properties, :anyOf, :unevaluatedProperties]
    )

  after_schema =
    JSONSchexBeforeAfterBench.Helpers.reorder_rules(
      after_schema,
      [:properties, :anyOf, :unevaluatedProperties]
    )

  prepare_pair.(
    fn -> JSONSchexBaseline.validate(before_schema, data) end,
    fn -> JSONSchex.validate(after_schema, data) end,
    fn before_result, after_result ->
      unless before_result == :ok && after_result == :ok do
        raise "P8 parent-dominated anyOf validation must pass in both versions"
      end
    end
  )
end)

run_optimization_bench.("optimization_validate_p9_flat_item_errors_256", fn ->
  data = Enum.map(1..256, &"bad-#{&1}")
  {before_schema, after_schema} = compile_versions.(%{"items" => %{"type" => "integer"}}, [])

  prepare_pair.(
    fn -> JSONSchexBaseline.validate(before_schema, data) end,
    fn -> JSONSchex.validate(after_schema, data) end,
    fn before_result, after_result ->
      unless JSONSchexBeforeAfterBench.Helpers.normalize_result(before_result) ===
               JSONSchexBeforeAfterBench.Helpers.normalize_result(after_result) do
        raise "P9 flat-item errors differ between Before and After"
      end

      for result <- [before_result, after_result] do
        case result do
          {:error, errors} ->
            unless length(errors) == 256 && Enum.all?(errors, &(&1.rule == :type)) do
              raise "P9 flat-item case must return 256 type errors"
            end

          other ->
            raise "P9 flat-item case unexpectedly returned #{inspect(other)}"
        end
      end
    end
  )
end)

run_optimization_bench.("optimization_validate_p12_required_last_missing_128", fn ->
  required = Enum.map(1..128, &"property-#{&1}")
  missing = List.last(required)
  data = required |> Map.new(&{&1, nil}) |> Map.delete(missing)
  {before_schema, after_schema} = compile_versions.(%{"required" => required}, [])

  prepare_pair.(
    fn -> JSONSchexBaseline.validate(before_schema, data) end,
    fn -> JSONSchex.validate(after_schema, data) end,
    fn before_result, after_result ->
      for result <- [before_result, after_result] do
        case result do
          {:error, [%{rule: :required, context: %{contrast: [^missing]}}]} -> :ok
          other -> raise "P12 required case returned an unexpected result: #{inspect(other)}"
        end
      end
    end
  )
end)

run_optimization_bench.("optimization_scan_p13_wide_properties_1024", fn ->
  schema = %{
    "$id" => "https://scanner.example/wide/root",
    "properties" =>
      Map.new(1..1_024, fn index ->
        {"property-#{index}",
         %{
           "$id" => "child-#{index}",
           "$anchor" => "anchor-#{index}",
           "$ref" => "#local"
         }}
      end)
  }

  prepare_pair.(
    fn -> JSONSchexBaseline.ScopeScanner.scan(schema) end,
    fn -> JSONSchex.ScopeScanner.scan(schema) end,
    fn before_result, after_result ->
      unless before_result === after_result do
        raise "P13 scope-scanner output differs between Before and After"
      end
    end
  )
end)


results = results_key |> Process.get() |> Enum.reverse()

if output_path do
  rows =
    Enum.flat_map(results, fn {case_name, metadata, scenarios} ->
      Enum.map(["Before", "After"], fn version ->
        %{run_time: run_time, memory: memory} = Map.fetch!(scenarios, version)

        Enum.join(
          [
            case_name,
            metadata.origin,
            metadata.operation,
            metadata.focus,
            version,
            run_time.average,
            run_time.median,
            Map.fetch!(run_time.percentiles, 99),
            memory.average
          ],
          "\t"
        )
      end)
    end)

  output =
    [
      "# baseline_commit\t#{baseline_commit}",
      "# baseline_lib_tree\t#{baseline_lib_tree}",
      "# after_commit\t#{after_commit}",
      "# after_lib_sha256\t#{current_lib_sha256}",
      "# after_lib_dirty\t#{current_lib_dirty?}",
      "# bench_lock_sha256\t#{bench_lock_sha256}",
      "# bench_filter\t#{bench_filter}",
      "# benchmark_order\t#{benchmark_order}",
      "# warmup_seconds\t#{warmup_seconds}",
      "# time_seconds\t#{time_seconds}",
      "# memory_time_seconds\t#{memory_time_seconds}",
      "# elixir_version\t#{System.version()}",
      "# otp_release\t#{System.otp_release()}",
      "# erts_version\t#{:erlang.system_info(:version)}",
      "# benchee_version\t#{Application.spec(:benchee, :vsn)}",
      "case\torigin\toperation\tfocus\tversion\taverage_ns\tmedian_ns\tp99_ns\tmemory_bytes"
      | rows
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")

  File.write!(output_path, output)
  IO.puts("Wrote #{length(results)} paired results to #{output_path}")
end

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("  All #{length(results)} paired benchmarks complete!")
IO.puts(String.duplicate("=", 60))

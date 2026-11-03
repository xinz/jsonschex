# Run from bench/: mix run type_check_before_after.exs
# Quick mixed-only run:
#   BENCH=mixed BENCH_WARMUP=0.2 BENCH_TIME=1 BENCH_MEMORY_TIME=0.2 mix run type_check_before_after.exs
#
# Compare literal heads (Before) with experimental data-first guards (After).
# Both copies share the current predicate bodies, whether production uses literal
# or guarded heads. Loading, compilation, fixtures, and verification are untimed.

defmodule JSONSchexTypeCheckBench do
  alias JSONSchex.Types.ErrorContext

  def compile_versions do
    path = Path.expand("../lib/jsonschex/compiler/predicates.ex", __DIR__)
    production_source = File.read!(path)
    heads = [
      {"string", "is_binary"}, {"integer", "is_integer"}, {"integer", "is_float"},
      {"boolean", "is_boolean"}, {"object", "is_map"}, {"array", "is_list"},
      {"null", "is_nil"}, {"number", "is_number"}
    ]

    before_source = Enum.reduce(heads, production_source, fn {type, guard}, source ->
      literal = "def check_type(data, #{inspect(type)}) when #{guard}(data)"
      guarded = "def check_type(data, expected) when #{guard}(data) and expected == #{inspect(type)}"
      case {String.contains?(source, literal), String.contains?(source, guarded)} do
        {true, false} -> source
        {false, true} -> replace_once!(source, guarded, literal)
        _ -> raise "Predicate source changed; expected a literal or guarded head for #{inspect({type, guard})}"
      end
    end)
    after_source = Enum.reduce(heads, before_source, fn {type, guard}, source ->
      replace_once!(source,
        "def check_type(data, #{inspect(type)}) when #{guard}(data)",
        "def check_type(data, expected) when #{guard}(data) and expected == #{inspect(type)}")
    end)
    production_style = cond do
      production_source === before_source -> "literal heads"
      production_source === after_source -> "data-first guards"
      true -> "mixed literal/guard heads"
    end

    for {module, source} <- [{__MODULE__.Before, before_source}, {__MODULE__.After, after_source}] do
      source = replace_once!(source, "defmodule JSONSchex.Compiler.Predicates do", "defmodule #{inspect(module)} do")
      # Compile rather than evaluate, so the measured functions are normal BEAM code.
      Code.compile_string(source, path)
    end

    fingerprint = :crypto.hash(:sha256, production_source) |> Base.encode16(case: :lower)
    IO.puts("Predicates source SHA-256: #{fingerprint}; production: #{production_style}")
    {Function.capture(__MODULE__.Before, :check_type, 2), Function.capture(__MODULE__.After, :check_type, 2)}
  end

  def fixtures do
    balanced = [
      {"value", "string"}, {42, "integer"}, {42.0, "integer"}, {1.5, "number"},
      {true, "boolean"}, {%{"value" => 1}, "object"}, {[1, 2], "array"}, {nil, "null"}
    ]
    # A synthetic string-heavy mix, not a benchmark of full payload validation.
    string_heavy = List.duplicate({"value", "string"}, 7) ++ [
      {42, "integer"}, {70, "number"}, {true, "boolean"},
      {%{"value" => 1}, "object"}, {%{}, "object"}, {["a", "b"], "array"}
    ]

    [
      {"single/string", [{"value", "string"}]},
      {"single/integer", [{42, "integer"}]},
      {"single/integral_float", [{42.0, "integer"}]},
      {"single/number", [{1.5, "number"}]},
      {"single/integer_as_number", [{42, "number"}]},
      {"single/boolean", [{true, "boolean"}]},
      {"single/object", [{%{"value" => 1}, "object"}]},
      {"single/array", [{[1, 2], "array"}]},
      {"single/null", [{nil, "null"}]},
      {"mismatch/scalar", [{"42", "number"}]},
      {"mismatch/fractional_integer", [{1.5, "integer"}]},
      {"union/first_match", [{"value", ["string", "number", "null"]}]},
      {"union/last_match", [{"value", ["null", "number", "string"]}]},
      {"union/no_match", [{1.5, ["null", "integer", "boolean"]}]},
      {"mixed/balanced", balanced},
      {"mixed/string_heavy", string_heavy}
    ]
  end

  def verify!(before_check, after_check, fixtures) do
    samples = [
      "", "héllo", <<0xFF>>, 0, -42, Integer.pow(2, 100), 1.0, -0.0, 1.5, 1.0e100,
      true, false, nil, [], [1, nil], %{}, %{"value" => 1}, %ErrorContext{}, :not_json, {1, 2}
    ]
    types = ~w(string integer number boolean object array null unsupported) ++ [
      [], ["number"], ["integer"], ["null", "integer"], ["integer", "string", "integer"]
    ]
    pairs = (for data <- samples, type <- types, do: {data, type}) ++
      Enum.flat_map(fixtures, fn {_name, pairs} -> pairs end)

    for {data, type} <- pairs do
      before_result = before_check.(data, type)
      after_result = after_check.(data, type)
      production_result = JSONSchex.Compiler.Predicates.check_type(data, type)

      unless before_result === after_result and after_result === production_result do
        raise "Type-check result mismatch for #{inspect({data, type})}: " <>
                inspect({before_result, after_result, production_result})
      end
    end
    IO.puts("Verified #{length(pairs)} input/type pairs against both copies and production.")
  end

  # Reuse the same tail-recursive driver for both versions. Count successful
  # checks rather than allocating a result list that would obscure dispatch costs.
  def run(pairs, check, repetitions), do: repeat(pairs, check, repetitions, 0)

  defp repeat(_pairs, _check, 0, passed), do: passed
  defp repeat(pairs, check, remaining, passed) do
    passed = check_pairs(pairs, check, passed)
    repeat(pairs, check, remaining - 1, passed)
  end

  defp check_pairs([], _check, passed), do: passed
  defp check_pairs([{data, type} | rest], check, passed) do
    case check.(data, type) do
      :ok -> check_pairs(rest, check, passed + 1)
      {:error, _context} -> check_pairs(rest, check, passed)
    end
  end

  def duration!(variable, default) do
    value = System.get_env(variable, default)
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> raise "#{variable} must be a non-negative number, got: #{inspect(value)}"
    end
  end

  def repetitions! do
    value = System.get_env("BENCH_BATCH_SIZE", "1000")
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> raise "BENCH_BATCH_SIZE must be a positive integer, got: #{inspect(value)}"
    end
  end

  def per_check_stats(suite, repetitions) do
    Enum.map(suite.scenarios, fn scenario ->
      count = length(scenario.input) * repetitions
      runtime = scenario.run_time_data.statistics
      memory = case scenario.memory_usage_data.statistics do
        %{average: bytes} when is_number(bytes) -> bytes / count
        _ -> nil
      end
      # Retain only summary values, not every suite's timing and memory samples.
      {scenario.input_name, scenario.job_name, count, runtime.average / count, runtime.median / count, memory}
    end)
  end

  def print_per_check(rows) do
    IO.puts("\nNormalized per top-level check_type/2 call (including the common batch driver):")
    IO.puts("input\tversion\tcalls/op\tmean ns/call\tmedian ns/call\tbytes/call")

    rows
    |> Enum.sort()
    |> Enum.each(fn {name, version, count, mean, median, memory} ->
      IO.puts(Enum.join([name, version, count, format(mean), format(median), format(memory)], "\t"))
    end)
  end

  defp format(nil), do: "n/a"
  defp format(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)

  defp replace_once!(source, old, new) do
    case String.split(source, old) do
      [prefix, suffix] -> prefix <> new <> suffix
      _ -> raise "Predicate source changed; expected exactly one occurrence of: #{old}"
    end
  end
end

filter = System.get_env("BENCH", "all") |> String.downcase()
order = System.get_env("BENCH_ORDER", "before_first") |> String.downcase()
unless order in ["before_first", "after_first"], do: raise("Invalid BENCH_ORDER: #{inspect(order)}")
repetitions = JSONSchexTypeCheckBench.repetitions!()
options = [
  warmup: JSONSchexTypeCheckBench.duration!("BENCH_WARMUP", "0.5"),
  time: JSONSchexTypeCheckBench.duration!("BENCH_TIME", "2"),
  memory_time: JSONSchexTypeCheckBench.duration!("BENCH_MEMORY_TIME", "0.5"),
  parallel: 1,
  formatters: [{Benchee.Formatters.Console, comparison: true}]
]
if options[:time] == 0, do: raise("BENCH_TIME must be greater than zero")

fixtures = JSONSchexTypeCheckBench.fixtures()
inputs = fixtures
  |> Enum.filter(fn {name, _pairs} -> filter == "all" or String.contains?(name, filter) end)
  |> Map.new()
if map_size(inputs) == 0, do: raise("No type-check inputs match BENCH=#{inspect(filter)}")

{before_check, after_check} = JSONSchexTypeCheckBench.compile_versions()
JSONSchexTypeCheckBench.verify!(before_check, after_check, fixtures)
IO.puts("Before: literal-binary heads; After: experimental data-first guards; order: #{order}")
IO.puts("Each Benchee operation repeats its input #{repetitions} times; raw statistics are per batch.")
IO.puts("The final table divides batch statistics by the number of predicate calls.")

jobs = [
  {"Before", fn pairs -> JSONSchexTypeCheckBench.run(pairs, before_check, repetitions) end},
  {"After", fn pairs -> JSONSchexTypeCheckBench.run(pairs, after_check, repetitions) end}
]
jobs = if order == "after_first", do: Enum.reverse(jobs), else: jobs
# Pair the versions separately for each input, rather than measuring every
# Before input before starting any After input in one large Benchee suite.
rows = inputs
  |> Enum.sort_by(fn {name, _pairs} -> name end)
  |> Enum.flat_map(fn {name, pairs} ->
    suite = Benchee.run(jobs, Keyword.put(options, :inputs, %{name => pairs}))
    JSONSchexTypeCheckBench.per_check_stats(suite, repetitions)
  end)
JSONSchexTypeCheckBench.print_per_check(rows)

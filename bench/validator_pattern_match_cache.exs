# Run from the repository root:
#   mix run bench/validator_pattern_match_cache.exs
#   mix run bench/validator_pattern_match_cache.exs --baseline 246fbaf
#
# Validation spans the validator orchestrator, rule dispatcher, and object-keyword
# reducers, so a baseline run reloads all three sources in memory. Input/schema
# construction, source loading, warmup, and explicit GC are outside timed intervals.

root = Path.expand("..", __DIR__)
validator_paths = [
  "lib/jsonschex/validator/keywords.ex",
  "lib/jsonschex/validator/rules.ex",
  "lib/jsonschex/validator.ex"
]

{sources, source_label} =
  case System.argv() do
    [] ->
      {
        Enum.map(validator_paths, fn path -> {Path.join(root, path), File.read!(Path.join(root, path))} end),
        "working tree (snapshot at script startup)"
      }

    ["--baseline", revision] ->
      sources =
        Enum.map(validator_paths, fn path ->
          case System.cmd("git", ["--no-pager", "show", "#{revision}:#{path}"], cd: root) do
            {source, 0} -> {Path.join(root, path), source}
            {output, status} -> raise "Cannot load #{path} (exit #{status}): #{output}"
          end
        end)

      {sources, "git #{revision}: validator sources"}

    _ ->
      raise "Usage: mix run bench/validator_pattern_match_cache.exs [--baseline REVISION]"
  end

previous_options = Code.compiler_options(ignore_module_conflict: true)

try do
  Enum.each(sources, fn {path, source} -> Code.compile_string(source, path) end)
after
  Code.compiler_options(previous_options)
end

fingerprint =
  sources
  |> Enum.map(&elem(&1, 1))
  |> IO.iodata_to_binary()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

IO.puts("Validator: #{source_label}; sha256=#{fingerprint}")
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")
IO.puts("Median ms/op and reductions/op; five adaptive batches targeting 20 ms; construction, source loading, warmup and GC excluded")

defmodule ValidatorPatternMatchCacheBench do
  alias JSONSchex.Types.{Rule, Schema}

  @widths [1, 2, 4, 8, 16, 32, 128, 512]

  def cases do
    Enum.flat_map(@widths, fn width ->
      [
        build_case(width, :pattern_only, :pattern_first),
        build_case(width, :siblings_true, :pattern_first),
        build_case(width, :siblings_true, :additional_first),
        build_case(width, :siblings_false, :pattern_first),
        build_case(width, :mostly_declared, :pattern_first)
      ]
    end)
  end

  def measure({label, schema, data}) do
    validate = fn ->
      case JSONSchex.validate(schema, data) do
        :ok -> :ok
        {:error, _errors} -> :error
      end
    end

    expected = validate.()
    :erlang.garbage_collect()
    {calibration_us, ^expected} = :timer.tc(validate)
    count = min(10_000, max(1, div(20_000, max(1, calibration_us))))

    samples =
      for _ <- 1..5 do
        :erlang.garbage_collect()

        {elapsed_us, :ok} =
          :timer.tc(fn ->
            Enum.each(1..count, fn _ ->
              ^expected = validate.()
            end)
          end)

        elapsed_us / count / 1_000
      end

    reductions = validation_reductions(validate, expected)
    median = samples |> Enum.sort() |> Enum.at(2)

    IO.puts(
      "#{label}: median_ms=#{Float.round(median, 4)} reductions=#{reductions} " <>
        "(count=#{count}; min_ms=#{Float.round(Enum.min(samples), 4)} " <>
        "max_ms=#{Float.round(Enum.max(samples), 4)})"
    )
  end

  defp build_case(width, :pattern_only, _order) do
    schema = %{"patternProperties" => pattern_map(width)}
    {:ok, compiled} = JSONSchex.compile(schema)
    {"patternProperties only, unmatched keys width=#{width}", compiled, unmatched_data(width)}
  end

  defp build_case(width, :siblings_true, order) do
    schema = %{"patternProperties" => pattern_map(width), "additionalProperties" => true}
    {:ok, compiled} = JSONSchex.compile(schema)

    {
      "siblings additionalProperties=true, unmatched keys, #{order} width=#{width}",
      reorder_rules(compiled, order),
      unmatched_data(width)
    }
  end

  defp build_case(width, :siblings_false, order) do
    schema = %{"patternProperties" => pattern_map(width), "additionalProperties" => false}
    {:ok, compiled} = JSONSchex.compile(schema)

    {
      "siblings additionalProperties=false, unmatched keys, #{order} width=#{width}",
      reorder_rules(compiled, order),
      unmatched_data(width)
    }
  end

  defp build_case(width, :mostly_declared, order) do
    properties = Map.new(1..width, fn index -> {"field-" <> Integer.to_string(index), true} end)

    schema = %{
      "properties" => properties,
      "patternProperties" => pattern_map(width),
      "additionalProperties" => true
    }

    {:ok, compiled} = JSONSchex.compile(schema)

    {
      "siblings mostly declared properties, #{order} width=#{width}",
      reorder_rules(compiled, order),
      unmatched_data(width)
    }
  end

  defp pattern_map(width) do
    Map.new(1..width, fn index ->
      {"^pattern-" <> Integer.to_string(index) <> "$", true}
    end)
  end

  defp unmatched_data(width) do
    Map.new(1..width, fn index -> {"field-" <> Integer.to_string(index), index} end)
  end

  defp reorder_rules(%Schema{rules: rules} = schema, :pattern_first) do
    reorder_rules(schema, [:patternProperties, :additionalProperties], rules)
  end

  defp reorder_rules(%Schema{rules: rules} = schema, :additional_first) do
    reorder_rules(schema, [:additionalProperties, :patternProperties], rules)
  end

  defp reorder_rules(%Schema{} = schema, names, rules) do
    selected =
      Enum.map(names, fn name ->
        case Enum.find(rules, &(&1.name == name)) do
          %Rule{} = rule -> rule
          nil -> raise "expected compiled #{inspect(name)} rule"
        end
      end)

    %{schema | rules: selected ++ Enum.reject(rules, &(&1.name in names))}
  end

  defp validation_reductions(validate, expected) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)
    ^expected = validate.()
    {:reductions, after_validation} = Process.info(self(), :reductions)
    after_validation - before
  end
end

task = Task.async(fn -> Enum.each(ValidatorPatternMatchCacheBench.cases(), &ValidatorPatternMatchCacheBench.measure/1) end)

case Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "Benchmark exceeded the 50 s measurement budget; results are incomplete"
end

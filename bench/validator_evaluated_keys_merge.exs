# Run from the repository root:
#   mix run bench/validator_evaluated_keys_merge.exs
#   mix run bench/validator_evaluated_keys_merge.exs --baseline 56190fd
#
# P8 changes only evaluated-key merging in Keywords, so a baseline run reloads
# that source in memory. Schema/data construction, source loading, warmup, and
# explicit GC are outside timed intervals.

root = Path.expand("..", __DIR__)
validator_path = "lib/jsonschex/validator/keywords.ex"

{source, source_label} =
  case System.argv() do
    [] ->
      path = Path.join(root, validator_path)
      {File.read!(path), "working tree (snapshot at script startup)"}

    ["--baseline", revision] ->
      case System.cmd("git", ["--no-pager", "show", "#{revision}:#{validator_path}"], cd: root) do
        {source, 0} -> {source, "git #{revision}:#{validator_path}"}
        {output, status} -> raise "Cannot load #{validator_path} (exit #{status}): #{output}"
      end

    _ ->
      raise "Usage: mix run bench/validator_evaluated_keys_merge.exs [--baseline REVISION]"
  end

previous_options = Code.compiler_options(ignore_module_conflict: true)

try do
  Code.compile_string(source, Path.join(root, validator_path))
after
  Code.compiler_options(previous_options)
end

fingerprint = source |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

IO.puts("Validator keywords: #{source_label}; sha256=#{fingerprint}")
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")

IO.puts(
  "Median ms/op and reductions/op; five adaptive batches targeting 20 ms; construction, source loading, warmup and GC excluded"
)

defmodule ValidatorEvaluatedKeysMergeBench do
  alias JSONSchex.Types.{Rule, Schema}

  @widths [1, 2, 4, 16, 64, 128]
  @dominant_parent_width 16
  @non_dominant_branch_evaluated_key_width 16

  def cases do
    Enum.flat_map(@widths, fn width ->
      [
        all_of_success_case(width),
        all_of_discarded_evaluated_keys_case(width),
        any_of_disjoint_case(width),
        any_of_dominant_parent_case(width),
        any_of_non_dominant_parent_case(width)
      ] ++
        any_of_candidate_fallback_cases(width) ++
        any_of_late_candidate_fallback_cases(width) ++
        [
          dependent_schemas_success_case(width),
          dependent_schemas_discarded_evaluated_keys_case(width),
          legacy_dependencies_success_case(width)
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

  defp all_of_success_case(width) do
    fields = keys("all-of", width)
    schema = compile!(%{"allOf" => Enum.map(fields, &property_schema([&1]))})

    {"allOf disjoint successful evaluated keys width=#{width}", schema, data_for(fields)}
  end

  defp all_of_discarded_evaluated_keys_case(width) do
    fields = keys("all-of", width)
    schema = compile!(%{"allOf" => Enum.map(fields, &property_schema([&1])) ++ [false]})

    {"allOf discarded successful evaluated keys width=#{width}", schema, data_for(fields)}
  end

  defp any_of_disjoint_case(width) do
    fields = keys("any-of", width)
    schema = compile!(%{"anyOf" => Enum.map(fields, &property_schema([&1]))})

    {"anyOf empty parent, disjoint evaluated keys width=#{width}", schema, data_for(fields)}
  end

  defp any_of_dominant_parent_case(width) do
    seed_fields = keys("seed", @dominant_parent_width)
    branch_fields = keys("any-of", width)

    schema =
      compile!(%{
        "properties" => Map.new(seed_fields, &{&1, true}),
        "anyOf" => Enum.map(branch_fields, &property_schema([&1]))
      })
      |> reorder_rules([:properties, :anyOf])

    {
      "anyOf parent=#{@dominant_parent_width}, one new evaluated key/branch width=#{width}",
      schema,
      data_for(seed_fields ++ branch_fields)
    }
  end

  defp any_of_non_dominant_parent_case(width) do
    seed_fields = ["seed"]

    branches =
      Enum.map(1..width, fn branch ->
        keys("any-of-#{branch}", @non_dominant_branch_evaluated_key_width)
      end)

    branch_fields = List.flatten(branches)

    schema =
      compile!(%{
        "properties" => Map.new(seed_fields, &{&1, true}),
        "anyOf" => Enum.map(branches, &property_schema/1)
      })
      |> reorder_rules([:properties, :anyOf])

    {
      "anyOf parent=1, branch evaluated keys=#{@non_dominant_branch_evaluated_key_width} width=#{width}",
      schema,
      data_for(seed_fields ++ branch_fields)
    }
  end

  defp any_of_candidate_fallback_cases(width) when width >= 4 do
    [any_of_candidate_fallback_case(width)]
  end

  defp any_of_candidate_fallback_cases(_width), do: []

  defp any_of_candidate_fallback_case(width) do
    seed_fields = keys("seed", @dominant_parent_width)

    branches =
      Enum.map(1..width, fn branch ->
        keys("any-of-#{branch}", @non_dominant_branch_evaluated_key_width)
      end)

    branch_fields = List.flatten(branches)

    schema =
      compile!(%{
        "properties" => Map.new(seed_fields, &{&1, true}),
        "anyOf" => Enum.map(branches, &property_schema/1)
      })
      |> reorder_rules([:properties, :anyOf])

    {
      "anyOf candidate fallback parent=#{@dominant_parent_width}, branch evaluated keys=#{@non_dominant_branch_evaluated_key_width} width=#{width}",
      schema,
      data_for(seed_fields ++ branch_fields)
    }
  end

  defp any_of_late_candidate_fallback_cases(width) when width >= 4 do
    [any_of_late_candidate_fallback_case(width)]
  end

  defp any_of_late_candidate_fallback_cases(_width), do: []

  defp any_of_late_candidate_fallback_case(width) do
    seed_fields = keys("seed", @dominant_parent_width)
    early_fields = keys("any-of-early", width - 1)
    late_fields = keys("any-of-late", 8 * width)

    branches =
      Enum.map(early_fields, &property_schema([&1])) ++ [property_schema(late_fields)]

    schema =
      compile!(%{
        "properties" => Map.new(seed_fields, &{&1, true}),
        "anyOf" => branches
      })
      |> reorder_rules([:properties, :anyOf])

    {
      "anyOf late fallback parent=#{@dominant_parent_width}, early branches=#{width - 1}, late evaluated keys=#{8 * width}",
      schema,
      data_for(seed_fields ++ early_fields ++ late_fields)
    }
  end

  defp dependent_schemas_success_case(width) do
    {dependencies, fields, trigger_fields} = dependent_schema_inputs(width)
    schema = compile!(%{"dependentSchemas" => dependencies})

    {
      "dependentSchemas disjoint successful evaluated keys width=#{width}",
      schema,
      data_for(trigger_fields ++ fields)
    }
  end

  defp dependent_schemas_discarded_evaluated_keys_case(width) do
    {dependencies, fields, trigger_fields} = dependent_schema_inputs(width)
    schema = compile!(%{"dependentSchemas" => Map.put(dependencies, "failure", false)})

    {
      "dependentSchemas discarded successful evaluated keys width=#{width}",
      schema,
      data_for(["failure" | trigger_fields ++ fields])
    }
  end

  defp legacy_dependencies_success_case(width) do
    {dependencies, fields, trigger_fields} = dependent_schema_inputs(width)
    schema = compile!(%{"dependencies" => dependencies})

    {
      "legacy dependencies disjoint successful evaluated keys width=#{width}",
      schema,
      data_for(trigger_fields ++ fields)
    }
  end

  defp dependent_schema_inputs(width) do
    Enum.reduce(1..width, {%{}, [], []}, fn index, {dependencies, fields, triggers} ->
      field = "dependent-value-#{index}"
      trigger = "dependent-trigger-#{index}"

      {
        Map.put(dependencies, trigger, property_schema([field])),
        [field | fields],
        [trigger | triggers]
      }
    end)
  end

  defp property_schema(fields), do: %{"properties" => Map.new(fields, &{&1, true})}
  defp data_for(fields), do: Map.new(fields, &{&1, true})
  defp keys(prefix, width), do: Enum.map(1..width, &"#{prefix}-#{&1}")

  defp compile!(raw_schema) do
    {:ok, schema} = JSONSchex.compile(raw_schema)
    schema
  end

  defp reorder_rules(%Schema{rules: rules} = schema, names) do
    selected =
      Enum.map(names, fn name ->
        case Enum.find(rules, &(&1.name == name)) do
          %Rule{} = rule -> rule
          nil -> raise "expected compiled #{inspect(name)} rule"
        end
      end)

    remaining = Enum.reject(rules, &(&1.name in names))
    %{schema | rules: selected ++ remaining}
  end

  defp validation_reductions(validate, expected) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)
    ^expected = validate.()
    {:reductions, after_validation} = Process.info(self(), :reductions)
    after_validation - before
  end
end

task =
  Task.async(fn ->
    Enum.each(
      ValidatorEvaluatedKeysMergeBench.cases(),
      &ValidatorEvaluatedKeysMergeBench.measure/1
    )
  end)

case Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "Benchmark exceeded the 50 s measurement budget; results are incomplete"
end

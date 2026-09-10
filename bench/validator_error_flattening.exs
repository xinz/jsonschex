# Run from the repository root:
#   mix run bench/validator_error_flattening.exs
#   mix run bench/validator_error_flattening.exs --baseline 9eab14f
#   P9_BENCH_FILTER=unevaluatedProperties mix run bench/validator_error_flattening.exs
#
# P9 changes only the public Validator error boundary, so a baseline run reloads
# that source in memory. Schema/data construction, source loading, warmup, result
# verification, and explicit GC are outside timed intervals.

root = Path.expand("..", __DIR__)
validator_path = "lib/jsonschex/validator.ex"

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
      raise "Usage: mix run bench/validator_error_flattening.exs [--baseline REVISION]"
  end

previous_options = Code.compiler_options(ignore_module_conflict: true)

try do
  Code.compile_string(source, Path.join(root, validator_path))
after
  Code.compiler_options(previous_options)
end

fingerprint = source |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

IO.puts("Validator: #{source_label}; sha256=#{fingerprint}")
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")

IO.puts(
  "Median ms/op and reductions/op; five adaptive batches targeting 20 ms; construction, source loading, verification, warmup and GC excluded"
)

defmodule ValidatorErrorFlatteningBench do
  @flat_widths [1, 16, 128, 1_024, 8_192]
  @nested_depths [1, 8, 32, 128]
  @branch_widths [4, 32, 128, 512]
  @unevaluated_widths [16, 128, 1_024]

  def cases do
    [valid_control(), single_error_control()] ++
      Enum.map(@flat_widths, &flat_items_case/1) ++
      Enum.map(@nested_depths, &nested_properties_case/1) ++
      Enum.flat_map(@branch_widths, &failed_applicator_cases/1) ++
      Enum.map(@unevaluated_widths, &unevaluated_properties_case/1)
  end

  def measure({label, schema, data, expected_error_count}) do
    expected_result = verify_result!(schema, data, expected_error_count)

    validate = fn ->
      case JSONSchex.validate(schema, data) do
        :ok -> :ok
        {:error, _errors} -> :error
      end
    end

    ^expected_result = validate.()
    :erlang.garbage_collect()
    {calibration_us, ^expected_result} = :timer.tc(validate)
    count = min(10_000, max(1, div(20_000, max(1, calibration_us))))

    samples =
      for _ <- 1..5 do
        :erlang.garbage_collect()

        {elapsed_us, :ok} =
          :timer.tc(fn ->
            Enum.each(1..count, fn _ ->
              ^expected_result = validate.()
            end)
          end)

        elapsed_us / count / 1_000
      end

    reductions = validation_reductions(validate, expected_result)
    median = samples |> Enum.sort() |> Enum.at(2)

    IO.puts(
      "#{label}: median_ms=#{Float.round(median, 4)} reductions=#{reductions} " <>
        "errors=#{expected_error_count} (count=#{count}; " <>
        "min_ms=#{Float.round(Enum.min(samples), 4)} " <>
        "max_ms=#{Float.round(Enum.max(samples), 4)})"
    )
  end

  defp valid_control do
    {"valid primitive control", compile!(%{"type" => "integer"}), 1, 0}
  end

  defp single_error_control do
    {"single primitive error control", compile!(%{"type" => "integer"}), "bad", 1}
  end

  defp flat_items_case(width) do
    schema = compile!(%{"items" => %{"type" => "integer"}})
    data = Enum.map(1..width, &"bad-#{&1}")
    {"flat item errors width=#{width}", schema, data, width}
  end

  defp nested_properties_case(depth) do
    width = 128
    leaf_schema = %{"items" => %{"allOf" => [%{"minimum" => 10}, %{"maximum" => 0}]}}
    leaf_data = List.duplicate(5, width)

    {raw_schema, data} =
      Enum.reduce(1..depth, {leaf_schema, leaf_data}, fn level, {schema, nested_data} ->
        key = "level-#{level}"
        {%{"properties" => %{key => schema}}, %{key => nested_data}}
      end)

    {"nested property errors depth=#{depth} width=#{width}", compile!(raw_schema), data, 2 * width}
  end

  defp failed_applicator_cases(width) do
    branches = Enum.map(1..width, &%{"const" => &1})

    Enum.map(["allOf", "anyOf", "oneOf"], fn keyword ->
      schema = compile!(%{keyword => branches})
      {"all-failed #{keyword} branches=#{width}", schema, -1, width}
    end)
  end

  defp unevaluated_properties_case(width) do
    data = Map.new(1..width, &{"field-#{&1}", &1})
    schema = compile!(%{"unevaluatedProperties" => false})
    {"false unevaluatedProperties width=#{width}", schema, data, width}
  end

  defp verify_result!(schema, data, 0) do
    case JSONSchex.validate(schema, data) do
      :ok -> :ok
      result -> raise "expected successful control, got: #{inspect(result)}"
    end
  end

  defp verify_result!(schema, data, expected_error_count) do
    case JSONSchex.validate(schema, data) do
      {:error, errors} when length(errors) == expected_error_count -> :error
      {:error, errors} -> raise "expected #{expected_error_count} errors, got: #{length(errors)}"
      :ok -> raise "expected #{expected_error_count} errors, validation passed"
    end
  end

  defp compile!(raw_schema) do
    {:ok, schema} = JSONSchex.compile(raw_schema)
    schema
  end

  defp validation_reductions(validate, expected_result) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)
    ^expected_result = validate.()
    {:reductions, after_validation} = Process.info(self(), :reductions)
    after_validation - before
  end
end

cases =
  case System.get_env("P9_BENCH_FILTER") do
    nil ->
      ValidatorErrorFlatteningBench.cases()

    filter ->
      Enum.filter(ValidatorErrorFlatteningBench.cases(), fn {label, _schema, _data, _count} ->
        String.contains?(label, filter)
      end)
  end

task =
  Task.async(fn ->
    Enum.each(cases, &ValidatorErrorFlatteningBench.measure/1)
  end)

case Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "Benchmark exceeded the 50 s measurement budget; results are incomplete"
end

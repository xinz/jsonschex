# Run from the repository root: mix run bench/string_length.exs
# Baseline: mix run bench/string_length.exs --baseline 7d103dc
# Only predicate source is pinned for a baseline; all other modules use the checkout.
root = Path.expand("..", __DIR__)
predicate_path = Path.join(root, "lib/jsonschex/compiler/predicates.ex")

label = case System.argv() do
  [] ->
    "working tree"

  ["--baseline", revision] ->
    {source, 0} = System.cmd("git", ["--no-pager", "show", "#{revision}:lib/jsonschex/compiler/predicates.ex"], cd: root)
    previous_options = Code.compiler_options(ignore_module_conflict: true)
    try do
      Code.compile_string(source, predicate_path)
    after
      Code.compiler_options(previous_options)
    end
    "baseline #{revision}"

  _ ->
    raise "Usage: mix run bench/string_length.exs [--baseline REVISION]"
end

IO.puts("Predicates: #{label}; Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")
IO.puts("Median us/op; five adaptive batches targeting 20 ms (1..100000 calls); construction/compilation/GC excluded")

defmodule StringLengthBench do
  def measure({label, run}) do
    run.()
    :erlang.garbage_collect()
    {calibration, _} = :timer.tc(fn -> Enum.each(1..10, fn _ -> run.() end) end)
    iterations = min(100_000, max(1, div(200_000, max(1, calibration))))
    samples = for _ <- 1..5 do
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> run.() end) end)
      us / iterations
    end
    median = samples |> Enum.sort() |> Enum.at(2)
    IO.puts("#{label}: #{Float.round(median, 3)} us/op")
  end
end

# Include all encoding widths and multi-codepoint graphemes. Each unit's length
# is measured outside timing; validators always receive actual codepoint limits.
inputs = for {name, unit} <- [{"ASCII", "a"}, {"2-byte", "é"}, {"3-byte", "漢"}, {"4-byte", "😀"}, {"combining", "e\u0301"}],
             size <- [16, 1000, 100_000] do
  data = String.duplicate(unit, size)
  count = length(String.to_charlist(unit)) * size
  {:ok, valid_schema} = JSONSchex.compile(%{"minLength" => count, "maxLength" => count})
  {:ok, invalid_schema} = JSONSchex.compile(%{"minLength" => count + 1, "maxLength" => 0})
  {"#{name} codepoints=#{count}", data, count, valid_schema, invalid_schema}
end

jobs = Enum.flat_map(inputs, fn {label, data, count, valid, invalid} ->
  [
    {"#{label} predicate min pass", fn ->
      :ok = JSONSchex.Compiler.Predicates.check_min_length(data, count)
    end},
    {"#{label} predicate max pass", fn ->
      :ok = JSONSchex.Compiler.Predicates.check_max_length(data, count)
    end},
    {"#{label} validate both pass", fn ->
      :ok = JSONSchex.validate(valid, data)
    end},
    {"#{label} validate both fail", fn ->
      {:error, [_, _]} = JSONSchex.validate(invalid, data)
    end}
  ]
end)

# Old revisions raise on malformed UTF-8, so compare valid inputs across versions
# and measure the new structured-error path only on the current implementation.
invalid = String.duplicate("a", 10_000) <> <<0xFF>>
jobs = if System.argv() == [] do
  {:ok, schema} = JSONSchex.compile(%{"minLength" => 0, "maxLength" => byte_size(invalid)})
  jobs ++ [{"malformed UTF-8 after 10000 ASCII codepoints (validate both errors)", fn ->
    {:error, [first, second]} = JSONSchex.validate(schema, invalid)
    "invalid_utf8" = first.context.error_detail
    "invalid_utf8" = second.context.error_detail
  end}]
else
  IO.puts("Skipping malformed-input job: baseline versions use a different error contract")
  jobs
end

task = Task.async(fn -> Enum.each(jobs, &StringLengthBench.measure/1) end)
case Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "String-length benchmark exceeded its 50 s measurement budget"
end

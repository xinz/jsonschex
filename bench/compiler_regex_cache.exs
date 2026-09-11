# Run from the repository root:
#   mix run bench/compiler_regex_cache.exs
#   mix run bench/compiler_regex_cache.exs --baseline d3864cf
#
# Loads only the selected compiler source in memory. Input construction, source
# loading, warmup, and explicit GC are outside the timed intervals.

root = Path.expand("..", __DIR__)
compiler_path = Path.join(root, "lib/jsonschex/compiler.ex")

{source, source_label} =
  case System.argv() do
    [] ->
      {File.read!(compiler_path), "working tree (snapshot at script startup)"}

    ["--baseline", revision] ->
      case System.cmd("git", ["--no-pager", "show", "#{revision}:lib/jsonschex/compiler.ex"], cd: root) do
        {source, 0} -> {source, "git #{revision}:lib/jsonschex/compiler.ex"}
        {output, status} -> raise "Cannot load baseline (exit #{status}): #{output}"
      end

    _ ->
      raise "Usage: mix run bench/compiler_regex_cache.exs [--baseline REVISION]"
  end

previous_options = Code.compiler_options(ignore_module_conflict: true)

try do
  Code.compile_string(source, compiler_path)
after
  Code.compiler_options(previous_options)
end

fingerprint = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

IO.puts("Compiler: #{source_label}; sha256=#{fingerprint}")
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")
IO.puts("Median ms/op; five adaptive batches targeting 20 ms; construction, source loading, warmup and GC excluded")

# Patterns use both ECMA property and whitespace transformations, so the sibling
# pass represents real regex preparation rather than only trivial Regex.compile/2 work.
defmodule CompilerRegexCacheBench do
  alias JSONSchex.Types.Schema

  @widths [0, 1, 16, 32, 33, 128, 512]

  def cases do
    Enum.flat_map(@widths, fn width ->
      [
        {"patternProperties only width=#{width}", schema(width, :none)},
        {"patternProperties + additionalProperties=false width=#{width}", schema(width, false)},
        {"patternProperties + additionalProperties=true width=#{width}", schema(width, true)}
      ]
    end)
  end

  def measure({label, schema}) do
    compile = fn ->
      {:ok, %Schema{}} = JSONSchex.compile(schema)
      :ok
    end

    compile.()
    :erlang.garbage_collect()
    {calibration_us, :ok} = :timer.tc(compile)
    count = min(10_000, max(1, div(20_000, max(1, calibration_us))))

    samples =
      for _ <- 1..5 do
        :erlang.garbage_collect()

        {elapsed_us, :ok} =
          :timer.tc(fn ->
            Enum.each(1..count, fn _ -> compile.() end)
          end)

        elapsed_us / count / 1_000
      end

    median = samples |> Enum.sort() |> Enum.at(2)

    IO.puts(
      "#{label}: median_ms=#{Float.round(median, 4)} " <>
        "(count=#{count}; min_ms=#{Float.round(Enum.min(samples), 4)} " <>
        "max_ms=#{Float.round(Enum.max(samples), 4)})"
    )
  end

  defp schema(width, additional) do
    patterns = pattern_map(width)
    schema = %{"patternProperties" => patterns}

    case additional do
      :none -> schema
      value -> Map.put(schema, "additionalProperties", value)
    end
  end

  defp pattern_map(0), do: %{}

  defp pattern_map(width) do
    Map.new(1..width, fn index ->
      {"^\\p{Letter}" <> Integer.to_string(index) <> "\\s*$", true}
    end)
  end
end

# A hard timeout prevents reporting an incomplete comparison as successful.
task = Task.async(fn -> Enum.each(CompilerRegexCacheBench.cases(), &CompilerRegexCacheBench.measure/1) end)

case Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "Benchmark exceeded the 50 s measurement budget; results are incomplete"
end

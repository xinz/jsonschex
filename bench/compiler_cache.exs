# Run from the repository root: mix run bench/compiler_reuse.exs
# Pin a baseline without changing files: mix run bench/compiler_reuse.exs --baseline HEAD
# No benchmark dependencies; input construction, source loading and GC are not timed.
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
      raise "Usage: mix run bench/compiler_cache.exs [--baseline REVISION]"
  end

# Load immediately, before construction/warmup: later disk edits cannot change this VM.
previous_options = Code.compiler_options(ignore_module_conflict: true)
try do
  Code.compile_string(source, compiler_path)
after
  Code.compiler_options(previous_options)
end

fingerprint = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
IO.puts("Compiler: #{source_label}; sha256=#{fingerprint}")
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, ERTS #{:erlang.system_info(:version)}")
IO.puts("OS #{inspect(:os.type())}; architecture #{:erlang.system_info(:system_architecture)}; schedulers #{System.schedulers_online()}/#{System.schedulers()}; MIX_ENV=#{Mix.env()}")
IO.puts("Five batches; target 20 ms/batch; adaptive count 1..50; 50 s total measurement timeout")

defmodule CompilerReuseBench do
  # Each resource has its own absolute identity, including the terminal node.
  def chain(keyword, depth) do
    leaf = %{"$id" => "https://compiler-reuse.example/leaf", "type" => "integer"}

    Enum.reduce(1..depth, leaf, fn index, child ->
      %{
        "$id" => "https://compiler-reuse.example/node/#{index}",
        keyword => %{"child" => child}
      }
    end)
  end

  def wide_refs(width) do
    # Exactly 20 schema nodes per definition: object plus 19 constrained properties.
    definition = %{
      "type" => "object",
      "required" => ["field1"],
      "properties" => Map.new(1..19, fn index ->
        {"field#{index}", %{"type" => "string", "minLength" => 1, "maxLength" => 80}}
      end)
    }

    # No root $id or base_uri: direct definitions and refs have matching context.
    %{
      "type" => "object",
      "$defs" => Map.new(1..width, fn index -> {"def#{index}", definition} end),
      "properties" => Map.new(1..width, fn index ->
        {"value#{index}", %{"$ref" => "#/$defs/def#{index}"}}
      end)
    }
  end

  def measure({label, schema}) do
    compile = fn ->
      {:ok, %JSONSchex.Types.Schema{}} = JSONSchex.compile(schema)
      :ok
    end

    compile.()
    :erlang.garbage_collect()
    {calibration_us, :ok} = :timer.tc(compile)
    count = min(50, max(1, div(20_000, max(1, calibration_us))))

    samples = for _ <- 1..5 do
      :erlang.garbage_collect()
      {elapsed_us, :ok} = :timer.tc(fn ->
        Enum.each(1..count, fn _ -> compile.() end)
      end)
      elapsed_us / count / 1000
    end

    median = samples |> Enum.sort() |> Enum.at(2)
    IO.puts("#{label}: median_ms=#{Float.round(median, 4)} (5 batches x #{count}; min_ms=#{Float.round(Enum.min(samples), 4)} max_ms=#{Float.round(Enum.max(samples), 4)})")
  end
end

# Build all inputs before starting any measurement, including decoding the fixture.
openapi =
  Path.join(__DIR__, "priv/openapi_spec_schema.json")
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("schema")

ordinary = %{
  "type" => "object",
  "required" => ["name"],
  "additionalProperties" => false,
  "properties" => %{
    "name" => %{"type" => "string", "minLength" => 1},
    "age" => %{"type" => "integer", "minimum" => 0},
    "tags" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 10}
  }
}

cases =
  (for depth <- [100, 200, 400], do: {"properties+ids depth=#{depth}", CompilerReuseBench.chain("properties", depth)}) ++
  (for depth <- [50, 100], do: {"defs+ids depth=#{depth}", CompilerReuseBench.chain("$defs", depth)}) ++
  (for width <- [50, 100, 200], do: {"direct-def refs width=#{width} nodes/def=20", CompilerReuseBench.wide_refs(width)}) ++
  [{"ordinary (no scope)", ordinary}, {"OpenAPI fixture", openapi}]

# A hard timeout also bounds unexpectedly slow single compilations; never report
# an incomplete set of samples as a successful benchmark run.
task = Task.async(fn -> Enum.each(cases, &CompilerReuseBench.measure/1) end)
case Task.yield(task, 50_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "Benchmark exceeded the 50 s measurement budget; results are incomplete"
end

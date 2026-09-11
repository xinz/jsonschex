# Run from the repository root:
#   mix run bench/scope_scanner_traversal.exs
#   mix run bench/scope_scanner_traversal.exs --baseline 8bef311
#
# Compares the selected production ScopeScanner traversal with a benchmark-only
# callback reducer. Inputs, source loading, result verification, warmup, and
# explicit garbage collection are outside timed intervals. Reclaimed words use
# VM-wide GC counters, so run this script in a dedicated VM.

root = Path.expand("..", __DIR__)
source_paths = ["lib/jsonschex/schema_traversal.ex", "lib/jsonschex/scope_scanner.ex"]

{sources, source_label} =
  case System.argv() do
    [] ->
      {
        Enum.map(source_paths, fn path -> {path, File.read!(Path.join(root, path))} end),
        "working tree (snapshot at script startup)"
      }

    ["--baseline", revision] ->
      baseline_sources =
        Enum.map(source_paths, fn path ->
          case System.cmd("git", ["--no-pager", "show", "#{revision}:#{path}"], cd: root) do
            {source, 0} -> {path, source}
            {output, status} -> raise "Cannot load #{path} (exit #{status}): #{output}"
          end
        end)

      {baseline_sources, "git #{revision}"}

    _ ->
      raise "Usage: mix run bench/scope_scanner_traversal.exs [--baseline REVISION]"
  end

previous_options = Code.compiler_options(ignore_module_conflict: true)

try do
  Enum.each(sources, fn {path, source} ->
    Code.compile_string(source, Path.join(root, path))
  end)
after
  Code.compiler_options(previous_options)
end

fingerprint =
  sources
  |> Enum.map_join(fn {path, source} -> path <> <<0>> <> source end)
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

IO.puts("Scanner sources: #{source_label}; combined_sha256=#{fingerprint}")
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, ERTS #{:erlang.system_info(:version)}")
IO.puts("schedulers #{System.schedulers_online()}/#{System.schedulers()}; MIX_ENV=#{Mix.env()}")
IO.puts("Median ms/op, reductions/op, and reclaimed words/op; five adaptive batches targeting 20 ms")

defmodule ScopeScannerReducerPrototype do
  alias JSONSchex.URIUtil

  @single_schema_keywords [
    "additionalProperties",
    "contains",
    "contentSchema",
    "items",
    "not",
    "propertyNames",
    "unevaluatedItems",
    "unevaluatedProperties",
    "if",
    "then",
    "else"
  ]
  @schema_map_keywords [
    "dependentSchemas",
    "patternProperties",
    "properties",
    "$defs",
    "definitions"
  ]
  @schema_list_keywords ["allOf", "anyOf", "oneOf", "prefixItems"]

  def scan(schema), do: do_scan(schema, nil, {%{}, MapSet.new()})

  defp do_scan(schema, base_uri, {registry, refs}) when is_map(schema) do
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    registry =
      if current_id do
        Map.put(registry, new_base_uri, schema)
      else
        registry
      end

    registry =
      registry
      |> register_anchor(schema, "$anchor", new_base_uri)
      |> register_anchor(schema, "$dynamicAnchor", new_base_uri)

    refs =
      Enum.reduce(["$ref", "$dynamicRef"], refs, fn key, acc ->
        case Map.get(schema, key) do
          "#" <> _ = value -> MapSet.put(acc, value)
          _ -> acc
        end
      end)

    reduce_scope_subschemas(schema, {registry, refs}, fn subschema, acc ->
      do_scan(subschema, new_base_uri, acc)
    end)
  end

  defp do_scan(_value, _base_uri, acc), do: acc

  defp reduce_scope_subschemas(schema, acc, reducer) do
    acc =
      Enum.reduce(@schema_list_keywords, acc, fn keyword, inner_acc ->
        reduce_schema_list(Map.get(schema, keyword), inner_acc, reducer)
      end)

    acc =
      Enum.reduce(@schema_map_keywords, acc, fn keyword, inner_acc ->
        reduce_schema_map(Map.get(schema, keyword), inner_acc, reducer)
      end)

    acc =
      Enum.reduce(@single_schema_keywords, acc, fn keyword, inner_acc ->
        reduce_schema(Map.get(schema, keyword), inner_acc, reducer)
      end)

    acc = reduce_schema_map(Map.get(schema, "dependencies"), acc, reducer)

    case Map.get(schema, "items") do
      items when is_list(items) -> reduce_schema_list(items, acc, reducer)
      _ -> acc
    end
  end

  defp reduce_schema_map(value, acc, reducer) when is_map(value) do
    value
    |> Map.values()
    |> Enum.reduce(acc, fn subschema, inner_acc ->
      reduce_schema(subschema, inner_acc, reducer)
    end)
  end

  defp reduce_schema_map(_value, acc, _reducer), do: acc

  defp reduce_schema_list(value, acc, reducer) when is_list(value) do
    Enum.reduce(value, acc, fn subschema, inner_acc ->
      reduce_schema(subschema, inner_acc, reducer)
    end)
  end

  defp reduce_schema_list(_value, acc, _reducer), do: acc

  defp reduce_schema(subschema, acc, reducer) when is_map(subschema) or is_boolean(subschema),
    do: reducer.(subschema, acc)

  defp reduce_schema(_value, acc, _reducer), do: acc

  defp register_anchor(acc, schema, keyword, base_uri) do
    case Map.get(schema, keyword) do
      anchor when is_binary(anchor) -> Map.put(acc, base_uri <> "#" <> anchor, schema)
      _ -> acc
    end
  end
end

defmodule ScopeScannerTraversalBench do
  alias JSONSchex.Draft202012.Schemas
  alias JSONSchex.ScopeScanner

  @base_uri "https://json-schema.org/draft/2020-12"
  @family_uris [
    @base_uri <> "/schema",
    @base_uri <> "/meta/core",
    @base_uri <> "/meta/applicator",
    @base_uri <> "/meta/unevaluated",
    @base_uri <> "/meta/validation",
    @base_uri <> "/meta/meta-data",
    @base_uri <> "/meta/format-annotation",
    @base_uri <> "/meta/format-assertion",
    @base_uri <> "/meta/content"
  ]

  def cases do
    family = Enum.map(@family_uris, fn uri -> {:ok, schema} = Schemas.fetch(uri); schema end)

    [
      {"built-in family (9 resources)", family, &scan_family/2},
      {"wide properties (1024 schemas)", wide_schema(1_024), &scan_one/2},
      {"nested properties (depth 1024)", nested_schema(1_024), &scan_one/2},
      {"inactive extension values (4096 entries)", inactive_values_schema(4_096), &scan_one/2}
    ]
  end

  def measure({label, input, runner}) do
    current = fn -> runner.(input, &ScopeScanner.scan/1) end
    reducer = fn -> runner.(input, &ScopeScannerReducerPrototype.scan/1) end

    expected = current.()
    unless reducer.() === expected, do: raise("prototype changed scanner output for #{label}")

    current.()
    reducer.()
    {calibration_us, ^expected} = :timer.tc(current)
    count = min(1_000, max(1, div(20_000, max(1, calibration_us))))

    current_stats = measure_implementation(current, count)
    reducer_stats = measure_implementation(reducer, count)

    IO.puts(label)
    print_stats("  production", current_stats, count)
    print_stats("  reducer prototype", reducer_stats, count)
  end

  def scan_family(schemas, scanner), do: Enum.map(schemas, scanner)
  def scan_one(schema, scanner), do: scanner.(schema)

  defp measure_implementation(operation, count) do
    times =
      for _ <- 1..5 do
        :erlang.garbage_collect()

        {elapsed_us, :ok} =
          :timer.tc(fn ->
            Enum.each(1..count, fn _ -> operation.() end)
          end)

        elapsed_us / count / 1000
      end

    :erlang.garbage_collect()
    {:reductions, before_reductions} = Process.info(self(), :reductions)
    Enum.each(1..count, fn _ -> operation.() end)
    {:reductions, after_reductions} = Process.info(self(), :reductions)
    reductions_per_op = (after_reductions - before_reductions) / count

    :erlang.garbage_collect()
    {_collections, before_reclaimed, _} = :erlang.statistics(:garbage_collection)
    Enum.each(1..count, fn _ -> operation.() end)
    :erlang.garbage_collect()
    {_collections, after_reclaimed, _} = :erlang.statistics(:garbage_collection)
    reclaimed_words_per_op = (after_reclaimed - before_reclaimed) / count

    {Enum.sort(times), reductions_per_op, reclaimed_words_per_op}
  end

  defp print_stats(name, {times, reductions, reclaimed_words}, count) do
    IO.puts(
      "#{name}: median_ms=#{Float.round(Enum.at(times, 2), 4)} " <>
        "min_ms=#{Float.round(hd(times), 4)} max_ms=#{Float.round(List.last(times), 4)} " <>
        "reductions=#{Float.round(reductions, 1)} " <>
        "reclaimed_words=#{Float.round(reclaimed_words, 1)} count=#{count}"
    )
  end

  defp wide_schema(width) do
    %{
      "$id" => "https://scanner.example/wide/root",
      "properties" =>
        Map.new(1..width, fn index ->
          {"property-#{index}",
           %{
             "$id" => "child-#{index}",
             "$anchor" => "anchor-#{index}",
             "$ref" => "#local"
           }}
        end)
    }
  end

  defp nested_schema(depth) do
    Enum.reduce(1..depth, %{"type" => "integer"}, fn index, child ->
      %{
        "$id" => "level-#{index}/",
        "$dynamicAnchor" => "node-#{index}",
        "properties" => %{"child" => child}
      }
    end)
  end

  defp inactive_values_schema(width) do
    extensions =
      Map.new(1..width, fn index ->
        {"x-literal-#{index}", %{"$id" => "inactive-#{index}", "$anchor" => "ignored"}}
      end)

    Map.put(extensions, "$id", "https://scanner.example/inactive/root")
  end
end

task = Task.async(fn -> Enum.each(ScopeScannerTraversalBench.cases(), &ScopeScannerTraversalBench.measure/1) end)

case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
  {:ok, :ok} -> :ok
  _ -> raise "Benchmark exceeded the 60 s measurement budget; results are incomplete"
end

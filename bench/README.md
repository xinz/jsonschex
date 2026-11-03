# Benchmark

Performance testing is for reference and verification of this implementation only. It does not imply exclusivity over other approaches. Choosing the appropriate tool for your scenario is the right approach.

Thanks to all Elixir open source projects that make this ecosystem great.

## How to Run

### Prerequisites

Install dependencies from the project root:

```bash
mix deps.get
```

### Library Comparison

Compare JSONSchex against other Elixir JSON Schema libraries. The suite contains 52 broad validation cases plus four user-facing scale cases derived from the focused optimization work:

```bash
# Run the full 56-case comparison suite in the bench directory
mix run libs_comparison.exs

# Measure a specific section only (e.g., ref, format, or usage-scale workloads)
BENCH=ref mix run libs_comparison.exs
BENCH=format mix run libs_comparison.exs
BENCH=scale mix run libs_comparison.exs
```

Results are printed to stdout via [Benchee](https://github.com/bencheeorg/benchee), and some benchmark results from my local are [here](./results.txt).

### JSONSchex Version Comparison

Compare the current JSONSchex working tree with a complete source snapshot from a Git revision. The benchmark reports only `Before` and `After` JSONSchex jobs. It retains the original 52-case `libs_comparison.exs` snapshot plus 12 focused bundle, compile, scan, and validation cases for the optimizations from `9ab9748` through the current `main`; the four newer cross-library scale cases are intentionally tracked only by `libs_comparison.exs`:

```bash
mix run jsonschex_before_after.exs \
  --baseline 0e3e2f40603fa5e57eff20ba8913861b10776572
```

Use `BENCH=inherited` for only the original 52 validation cases, `BENCH=optimization` for only the 12 focused cases, or another substring such as `array`, `p8`, or `scope_reuse` for a narrower selection. The default `BENCH=all` runs all 64 cases. `BENCH_ORDER` controls the version order inside each Benchee suite, allowing two opposite-order runs to expose and reduce ordering bias:

```bash
BENCH=optimization BENCH_ORDER=after_first \
mix run jsonschex_before_after.exs --baseline <revision>

BENCH=optimization BENCH_ORDER=before_first \
mix run jsonschex_before_after.exs --baseline <revision>
```

Set `VERSION_BENCH_OUTPUT` to write raw per-case statistics as TSV. The output includes each case's origin, operation, and optimization focus, together with revision/source fingerprints, dirty state, measurement durations, filter, and runtime versions needed to audit the run.

See this [PR](https://github.com/xinz/jsonschex/pull/13) for the current methodology and results.

### Type-Check Dispatch Before/After

Compare only `JSONSchex.Compiler.Predicates.check_type/2` dispatch, using Benchee from the `bench` directory:

```bash
mix run type_check_before_after.exs

# Shorter runs for the two synthetic mixed workloads
BENCH=mixed BENCH_WARMUP=0.2 BENCH_TIME=1 BENCH_MEMORY_TIME=0.2 \
  mix run type_check_before_after.exs

# Repeat with the opposite version order
BENCH=mixed BENCH_ORDER=after_first \
  mix run type_check_before_after.exs
```

Each input gets its own paired Benchee suite, keeping its Before/After measurements close together instead of measuring all Before inputs first. The script compiles two in-memory copies of the current predicate source:

- **Before:** restores the eight literal-binary type-name function heads.
- **After:** retains the data-first guards from the working tree.

Union handling, type inference, and error construction are identical in both copies. No Git revision, preserved benchmark artifact, source rewrite on disk, or new dependency is required. The script fails if the expected guarded heads change, rather than silently comparing the wrong code. It verifies exact results against both copies and production before measurement, including integral floats, malformed binary strings, mismatches, and union diagnostics.

The 16 inputs cover individual matching types (`BENCH=single`), mismatches (`BENCH=mismatch`), union positions/failures (`BENCH=union`), and balanced/string-heavy mixes (`BENCH=mixed`). `BENCH` otherwise selects by input-name substring; the default is `all`.

| Setting | Default | Meaning |
|---|---:|---|
| `BENCH_WARMUP` | `0.5` | Warmup seconds per scenario |
| `BENCH_TIME` | `2` | Timing seconds per scenario; must be positive |
| `BENCH_MEMORY_TIME` | `0.5` | Memory measurement seconds; `0` disables it |
| `BENCH_BATCH_SIZE` | `1000` | Repetitions of each input per Benchee operation |
| `BENCH_ORDER` | `before_first` | Job order; also accepts `after_first` |

Batching makes these very short predicates easier to measure. Each operation runs `input length × BENCH_BATCH_SIZE` predicate calls through the same allocation-free driver, returning a success count instead of building a result list. Standard Benchee output is **per batch**; the final table also reports normalized mean/median **nanoseconds per top-level `check_type/2` call** and **bytes per call**, including the shared driver overhead. Each union call includes its member checks. Normalized medians describe batch averages, not independently timed individual calls. Memory figures use Benchee's accounting, not retained memory or a complete allocation census.

Run on an otherwise idle machine and compare both orders. Type mix and runtime/compiler versions can affect the trade-off; lower allocation does not establish an overall validation latency improvement. This benchmark excludes schema compilation, reference resolution, error formatting, and the rest of validation.

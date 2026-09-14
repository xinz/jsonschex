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


See [`jsonschex_before_after_overview.md`](./jsonschex_before_after_overview.md) for the current methodology and results.

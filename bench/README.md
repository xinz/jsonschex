# Benchmarks

Performance testing is for reference and verification of this implementation only. It does not imply exclusivity over other approaches. Choosing the appropriate tool for your scenario is the right approach.

Thanks to all Elixir open source projects that make this ecosystem great.

## How to Run

### Prerequisites

Install dependencies from the project root:

```bash
mix deps.get
```

### Library Comparison

Compare JSONSchex against other Elixir JSON Schema libraries:

```bash
# Run the full comparison suite in the bench directory
mix run libs_comparison.exs

# Run a specific section only (e.g., ref, type, format, composition, etc.)
BENCH=ref mix run libs_comparison.exs
BENCH=format mix run libs_comparison.exs
```

Results are printed to stdout via [Benchee](https://github.com/bencheeorg/benchee), and my local benchmark results are [here](./results.md).

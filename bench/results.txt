============================================================
  Benchmark: simple_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.87 M      534.64 ns  ±1115.74%         500 ns         667 ns
JsonXema         1.44 M      692.16 ns   ±674.99%         666 ns         834 ns
JSV              0.91 M     1096.41 ns   ±623.15%        1041 ns        1417 ns

Comparison:
JSONSchex        1.87 M
JsonXema         1.44 M - 1.29x slower +157.52 ns
JSV              0.91 M - 2.05x slower +561.77 ns

Memory usage statistics:

Name         Memory usage
JSONSchex           352 B
JsonXema            816 B - 2.32x memory usage +464 B
JSV                2304 B - 6.55x memory usage +1952 B

**All measurements for memory usage were the same**

============================================================
  Benchmark: simple_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.80 M        0.56 μs  ±1354.63%        0.50 μs        0.67 μs
JSV              0.91 M        1.10 μs   ±599.63%        1.04 μs        1.42 μs

Comparison:
JSONSchex        1.80 M
JSV              0.91 M - 1.99x slower +0.55 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         0.46 KB
JSV               2.39 KB - 5.19x memory usage +1.93 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: nested_object_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      661.40 K        1.51 μs   ±343.86%        1.42 μs        2.33 μs
JsonXema       231.32 K        4.32 μs   ±278.52%        3.71 μs        8.83 μs
JSV            180.55 K        5.54 μs   ±113.06%        5.33 μs       11.67 μs

Comparison:
JSONSchex      661.40 K
JsonXema       231.32 K - 2.86x slower +2.81 μs
JSV            180.55 K - 3.66x slower +4.03 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         3.14 KB
JsonXema          1.96 KB - 0.62x memory usage -1.17969 KB
JSV              19.80 KB - 6.30x memory usage +16.66 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: nested_object_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1244.43 K        0.80 μs   ±819.85%        0.75 μs        1.04 μs
JsonXema       895.54 K        1.12 μs   ±622.38%        1.04 μs        1.46 μs
JSV            243.01 K        4.12 μs   ±198.06%        3.42 μs       16.75 μs

Comparison:
JSONSchex     1244.43 K
JsonXema       895.54 K - 1.39x slower +0.31 μs
JSV            243.01 K - 5.12x slower +3.31 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.52 KB
JsonXema          2.84 KB - 1.12x memory usage +0.31 KB
JSV              12.30 KB - 4.88x memory usage +9.78 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: ref_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      253.67 K        3.94 μs   ±214.66%        2.96 μs       16.42 μs
JSV             64.52 K       15.50 μs    ±25.13%       15.04 μs       24.79 μs

Comparison:
JSONSchex      253.67 K
JSV             64.52 K - 3.93x slower +11.56 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         6.48 KB
JSV              49.91 KB - 7.71x memory usage +43.43 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: ref_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      547.91 K        1.83 μs   ±517.21%        1.17 μs       13.88 μs
JSV            154.01 K        6.49 μs    ±84.85%        6.25 μs       12.96 μs

Comparison:
JSONSchex      547.91 K
JSV            154.01 K - 3.56x slower +4.67 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         3.05 KB
JSV              21.63 KB - 7.08x memory usage +18.57 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: array_small_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      391.68 K        2.55 μs   ±293.30%        2.42 μs        3.50 μs
JsonXema       171.43 K        5.83 μs   ±130.05%        5.67 μs        9.46 μs
JSV             76.69 K       13.04 μs    ±24.72%       12.63 μs       22.83 μs

Comparison:
JSONSchex      391.68 K
JsonXema       171.43 K - 2.28x slower +3.28 μs
JSV             76.69 K - 5.11x slower +10.49 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         7.64 KB
JsonXema          7.34 KB - 0.96x memory usage -0.29688 KB
JSV              55.98 KB - 7.33x memory usage +48.34 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: array_large_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex       31.58 K       31.67 μs    ±22.56%       27.67 μs       48.88 μs
JsonXema        16.19 K       61.78 μs    ±11.34%       58.21 μs       80.73 μs
JSV              5.41 K      184.73 μs     ±9.69%      184.50 μs      238.24 μs

Comparison:
JSONSchex       31.58 K
JsonXema        16.19 K - 1.95x slower +30.11 μs
JSV              5.41 K - 5.83x slower +153.06 μs

Memory usage statistics:

Name              average  deviation         median         99th %
JSONSchex        76.41 KB     ±0.00%       76.41 KB       76.41 KB
JsonXema         72.73 KB     ±0.00%       72.73 KB       72.73 KB
JSV             545.85 KB     ±0.00%      545.85 KB      545.85 KB

Comparison:
JSONSchex        76.41 KB
JsonXema         72.73 KB - 0.95x memory usage -3.67188 KB
JSV             545.85 KB - 7.14x memory usage +469.45 KB

============================================================
  Benchmark: array_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      432.83 K        2.31 μs   ±326.03%        2.17 μs        3.50 μs
JsonXema       150.52 K        6.64 μs   ±114.97%        6.38 μs       15.33 μs
JSV             85.29 K       11.72 μs    ±23.32%       11.25 μs       21.46 μs

Comparison:
JSONSchex      432.83 K
JsonXema       150.52 K - 2.88x slower +4.33 μs
JSV             85.29 K - 5.07x slower +9.41 μs

Memory usage statistics:

Name         Memory usage
JSONSchex        10.14 KB
JsonXema         21.84 KB - 2.15x memory usage +11.70 KB
JSV              55.66 KB - 5.49x memory usage +45.52 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: array_prefix_contains_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        2.33 M      429.84 ns   ±904.14%         416 ns         583 ns
JsonXema         1.82 M      550.38 ns  ±1007.87%         500 ns         667 ns
JSV              0.33 M     3035.60 ns   ±207.92%        2875 ns        6959 ns

Comparison:
JSONSchex        2.33 M
JsonXema         1.82 M - 1.28x slower +120.54 ns
JSV              0.33 M - 7.06x slower +2605.76 ns

Memory usage statistics:

Name         Memory usage
JSONSchex         2.21 KB
JsonXema          0.61 KB - 0.28x memory usage -1.60156 KB
JSV              16.29 KB - 7.37x memory usage +14.08 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: array_prefix_contains_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     2684.72 K        0.37 μs  ±1617.62%        0.33 μs        0.54 μs
JsonXema       719.19 K        1.39 μs   ±444.03%        1.29 μs        1.88 μs
JSV            363.86 K        2.75 μs   ±198.99%        2.58 μs        4.21 μs

Comparison:
JSONSchex     2684.72 K
JsonXema       719.19 K - 3.73x slower +1.02 μs
JSV            363.86 K - 7.38x slower +2.38 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.22 KB
JsonXema          4.48 KB - 2.02x memory usage +2.27 KB
JSV              14.45 KB - 6.51x memory usage +12.23 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: array_unique_items_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JsonXema       291.44 K        3.43 μs    ±33.91%        3.33 μs           5 μs
JSONSchex      271.08 K        3.69 μs   ±186.85%        3.50 μs           8 μs
JSV            214.19 K        4.67 μs   ±132.80%        4.46 μs       12.50 μs

Comparison:
JsonXema       291.44 K
JSONSchex      271.08 K - 1.08x slower +0.26 μs
JSV            214.19 K - 1.36x slower +1.24 μs

Memory usage statistics:

Name         Memory usage
JsonXema          0.38 KB
JSONSchex        14.98 KB - 39.12x memory usage +14.59 KB
JSV              17.74 KB - 46.35x memory usage +17.36 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: array_unique_items_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      270.96 K        3.69 μs   ±152.49%        3.50 μs        8.04 μs
JsonXema       231.19 K        4.33 μs   ±166.11%        3.83 μs       17.25 μs
JSV            213.38 K        4.69 μs   ±127.49%        4.50 μs        9.58 μs

Comparison:
JSONSchex      270.96 K
JsonXema       231.19 K - 1.17x slower +0.63 μs
JSV            213.38 K - 1.27x slower +1.00 μs

Memory usage statistics:

Name         Memory usage
JSONSchex        15.12 KB
JsonXema          2.50 KB - 0.17x memory usage -12.61719 KB
JSV              17.30 KB - 1.14x memory usage +2.18 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: allof_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1458.25 K        0.69 μs   ±851.42%        0.63 μs        0.88 μs
JsonXema       699.37 K        1.43 μs   ±441.77%        1.38 μs        1.79 μs
JSV            371.78 K        2.69 μs   ±228.80%        2.54 μs        4.29 μs

Comparison:
JSONSchex     1458.25 K
JsonXema       699.37 K - 2.09x slower +0.74 μs
JSV            371.78 K - 3.92x slower +2.00 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.66 KB
JsonXema          1.22 KB - 0.74x memory usage -0.43750 KB
JSV               9.82 KB - 5.93x memory usage +8.16 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: allof_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     2027.72 K        0.49 μs  ±1185.79%        0.46 μs        0.63 μs
JSV            496.98 K        2.01 μs   ±374.64%        1.92 μs        2.83 μs
JsonXema       455.03 K        2.20 μs   ±355.31%        2.08 μs        3.08 μs

Comparison:
JSONSchex     2027.72 K
JSV            496.98 K - 4.08x slower +1.52 μs
JsonXema       455.03 K - 4.46x slower +1.70 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.63 KB
JSV               7.83 KB - 4.79x memory usage +6.20 KB
JsonXema          5.74 KB - 3.52x memory usage +4.11 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: anyof_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JsonXema      1019.81 K        0.98 μs   ±796.36%        0.92 μs        1.21 μs
JSONSchex      932.98 K        1.07 μs   ±493.11%        0.79 μs       12.83 μs
JSV            358.03 K        2.79 μs   ±223.67%        2.63 μs        4.71 μs

Comparison:
JsonXema      1019.81 K
JSONSchex      932.98 K - 1.09x slower +0.0913 μs
JSV            358.03 K - 2.85x slower +1.81 μs

Memory usage statistics:

Name         Memory usage
JsonXema          0.77 KB
JSONSchex         2.16 KB - 2.79x memory usage +1.38 KB
JSV              10.55 KB - 13.64x memory usage +9.77 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: anyof_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1290.19 K        0.78 μs   ±840.67%        0.71 μs           1 μs
JsonXema       833.95 K        1.20 μs   ±696.56%        1.13 μs        1.54 μs
JSV            408.20 K        2.45 μs   ±313.19%        2.33 μs        3.75 μs

Comparison:
JSONSchex     1290.19 K
JsonXema       833.95 K - 1.55x slower +0.42 μs
JSV            408.20 K - 3.16x slower +1.67 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.39 KB
JsonXema          2.52 KB - 1.06x memory usage +0.133 KB
JSV               9.56 KB - 4.00x memory usage +7.17 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: oneof_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1085.78 K        0.92 μs   ±817.99%        0.83 μs        1.25 μs
JsonXema       726.11 K        1.38 μs   ±432.09%        1.29 μs        1.75 μs
JSV            284.67 K        3.51 μs   ±172.37%        3.29 μs        9.25 μs

Comparison:
JSONSchex     1085.78 K
JsonXema       726.11 K - 1.50x slower +0.46 μs
JSV            284.67 K - 3.81x slower +2.59 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.62 KB
JsonXema          1.65 KB - 0.63x memory usage -0.96875 KB
JSV                 13 KB - 4.97x memory usage +10.38 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: oneof_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1097.66 K        0.91 μs   ±776.77%        0.83 μs        1.17 μs
JsonXema       605.65 K        1.65 μs   ±364.14%        1.58 μs        2.13 μs
JSV            333.47 K        3.00 μs   ±210.19%        2.83 μs        4.96 μs

Comparison:
JSONSchex     1097.66 K
JsonXema       605.65 K - 1.81x slower +0.74 μs
JSV            333.47 K - 3.29x slower +2.09 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         3.14 KB
JsonXema          3.93 KB - 1.25x memory usage +0.79 KB
JSV              12.13 KB - 3.86x memory usage +8.99 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: not_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        5.51 M      181.54 ns  ±3378.57%         166 ns         292 ns
JsonXema         1.48 M      674.36 ns   ±876.35%         625 ns         834 ns
JSV              0.97 M     1033.17 ns   ±693.89%         958 ns        1459 ns

Comparison:
JSONSchex        5.51 M
JsonXema         1.48 M - 3.71x slower +492.83 ns
JSV              0.97 M - 5.69x slower +851.63 ns

Memory usage statistics:

Name         Memory usage
JSONSchex           560 B
JsonXema            656 B - 1.17x memory usage +96 B
JSV                3432 B - 6.13x memory usage +2872 B

**All measurements for memory usage were the same**

============================================================
  Benchmark: not_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        4.62 M      216.54 ns  ±2439.81%         208 ns         334 ns
JsonXema         1.13 M      881.95 ns   ±559.83%         833 ns        1125 ns
JSV              0.94 M     1061.98 ns   ±559.96%        1000 ns        1417 ns

Comparison:
JSONSchex        4.62 M
JsonXema         1.13 M - 4.07x slower +665.42 ns
JSV              0.94 M - 4.90x slower +845.44 ns

Memory usage statistics:

Name         Memory usage
JSONSchex         0.63 KB
JsonXema          1.34 KB - 2.14x memory usage +0.71 KB
JSV               3.58 KB - 5.72x memory usage +2.95 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: conditional_valid_then
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      975.61 K        1.02 μs   ±618.12%        0.96 μs        1.25 μs
JsonXema       582.14 K        1.72 μs   ±336.06%        1.63 μs        2.08 μs
JSV            336.30 K        2.97 μs   ±265.01%        2.88 μs        4.13 μs

Comparison:
JSONSchex      975.61 K
JsonXema       582.14 K - 1.68x slower +0.69 μs
JSV            336.30 K - 2.90x slower +1.95 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.54 KB
JsonXema          0.72 KB - 0.47x memory usage -0.82031 KB
JSV               8.64 KB - 5.61x memory usage +7.10 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: conditional_valid_else
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1114.74 K        0.90 μs   ±484.18%        0.83 μs        1.08 μs
JsonXema       574.59 K        1.74 μs   ±342.84%        1.67 μs        2.13 μs
JSV            348.15 K        2.87 μs   ±271.30%        2.79 μs        4.33 μs

Comparison:
JSONSchex     1114.74 K
JsonXema       574.59 K - 1.94x slower +0.84 μs
JSV            348.15 K - 3.20x slower +1.98 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.41 KB
JsonXema             1 KB - 0.71x memory usage -0.41406 KB
JSV               8.38 KB - 5.93x memory usage +6.97 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: conditional_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1153.07 K        0.87 μs   ±648.83%        0.79 μs        1.08 μs
JsonXema       518.61 K        1.93 μs   ±350.41%        1.83 μs        2.46 μs
JSV            349.85 K        2.86 μs   ±223.46%        2.75 μs        4.21 μs

Comparison:
JSONSchex     1153.07 K
JsonXema       518.61 K - 2.22x slower +1.06 μs
JSV            349.85 K - 3.30x slower +1.99 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.45 KB
JsonXema          2.84 KB - 1.95x memory usage +1.38 KB
JSV               8.59 KB - 5.91x memory usage +7.13 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: additional_pattern_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      353.67 K        2.83 μs   ±278.64%        2.50 μs       15.17 μs
JsonXema       335.25 K        2.98 μs   ±233.55%        2.88 μs        3.75 μs
JSV            289.86 K        3.45 μs   ±233.73%        3.33 μs        5.08 μs

Comparison:
JSONSchex      353.67 K
JsonXema       335.25 K - 1.05x slower +0.155 μs
JSV            289.86 K - 1.22x slower +0.62 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.72 KB
JsonXema          1.46 KB - 0.85x memory usage -0.25781 KB
JSV               7.16 KB - 4.17x memory usage +5.45 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: additional_pattern_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      603.31 K        1.66 μs   ±479.57%        1.58 μs           2 μs
JSV            386.26 K        2.59 μs   ±245.31%        2.46 μs        3.96 μs
JsonXema       318.15 K        3.14 μs   ±215.05%        3.04 μs        4.25 μs

Comparison:
JSONSchex      603.31 K
JSV            386.26 K - 1.56x slower +0.93 μs
JsonXema       318.15 K - 1.90x slower +1.49 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.30 KB
JSV               5.46 KB - 4.21x memory usage +4.16 KB
JsonXema          4.95 KB - 3.81x memory usage +3.65 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: additional_schema_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1084.90 K        0.92 μs   ±741.00%        0.63 μs       12.96 μs
JsonXema       791.71 K        1.26 μs   ±494.27%        1.21 μs        1.58 μs
JSV            364.77 K        2.74 μs   ±172.17%        2.63 μs        4.25 μs

Comparison:
JSONSchex     1084.90 K
JsonXema       791.71 K - 1.37x slower +0.34 μs
JSV            364.77 K - 2.97x slower +1.82 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.71 KB
JsonXema          2.43 KB - 1.42x memory usage +0.72 KB
JSV               9.42 KB - 5.51x memory usage +7.71 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: additional_schema_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        2.88 M      347.21 ns  ±1714.54%         292 ns         459 ns
JsonXema         1.15 M      873.26 ns   ±867.66%         833 ns        1125 ns
JSV              0.63 M     1589.94 ns   ±416.22%        1500 ns        2333 ns

Comparison:
JSONSchex        2.88 M
JsonXema         1.15 M - 2.52x slower +526.06 ns
JSV              0.63 M - 4.58x slower +1242.73 ns

Memory usage statistics:

Name         Memory usage
JSONSchex         1.33 KB
JsonXema          2.26 KB - 1.70x memory usage +0.93 KB
JSV               5.77 KB - 4.35x memory usage +4.45 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: unevaluated_valid_then
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.08 M        0.93 μs   ±811.33%        0.67 μs       12.88 μs
JSV              0.38 M        2.62 μs   ±243.91%        2.50 μs        3.75 μs

Comparison:
JSONSchex        1.08 M
JSV              0.38 M - 2.82x slower +1.69 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.72 KB
JSV               9.02 KB - 5.25x memory usage +7.30 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: unevaluated_valid_else
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.82 M        0.55 μs  ±1416.65%        0.50 μs        0.71 μs
JSV              0.40 M        2.53 μs   ±256.87%        2.38 μs        3.67 μs

Comparison:
JSONSchex        1.82 M
JSV              0.40 M - 4.59x slower +1.98 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.59 KB
JSV               8.80 KB - 5.55x memory usage +7.21 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: unevaluated_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.56 M        0.64 μs  ±1127.36%        0.58 μs        0.79 μs
JSV              0.37 M        2.70 μs   ±224.10%        2.54 μs        3.79 μs

Comparison:
JSONSchex        1.56 M
JSV              0.37 M - 4.21x slower +2.06 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.03 KB
JSV               9.29 KB - 4.57x memory usage +7.26 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: dependent_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.13 M        0.89 μs   ±860.92%        0.63 μs       12.67 μs
JSV              0.43 M        2.32 μs   ±187.57%        2.21 μs        3.50 μs

Comparison:
JSONSchex        1.13 M
JSV              0.43 M - 2.62x slower +1.44 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.61 KB
JSV               7.98 KB - 4.96x memory usage +6.37 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: dependent_invalid_missing
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.66 M        0.60 μs  ±1168.24%        0.42 μs       12.08 μs
JSV              0.62 M        1.60 μs   ±485.29%        1.50 μs        2.29 μs

Comparison:
JSONSchex        1.66 M
JSV              0.62 M - 2.66x slower +1.00 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.10 KB
JSV               5.63 KB - 5.11x memory usage +4.52 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: dependent_invalid_schema
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        1.98 M        0.50 μs  ±1232.89%        0.46 μs        0.63 μs
JSV              0.44 M        2.30 μs   ±250.93%        2.17 μs        3.58 μs

Comparison:
JSONSchex        1.98 M
JSV              0.44 M - 4.55x slower +1.79 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.34 KB
JSV               7.91 KB - 5.88x memory usage +6.56 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: large_payload_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        9.42 K      106.17 μs     ±4.37%      105.04 μs      117.71 μs
JsonXema         4.75 K      210.59 μs     ±7.01%      204.54 μs      250.79 μs
JSV              1.53 K      653.51 μs     ±4.66%      644.63 μs      747.48 μs

Comparison:
JSONSchex        9.42 K
JsonXema         4.75 K - 1.98x slower +104.42 μs
JSV              1.53 K - 6.16x slower +547.34 μs

Memory usage statistics:

Name         Memory usage
JSONSchex       277.52 KB
JsonXema        194.61 KB - 0.70x memory usage -82.91406 KB
JSV            2254.39 KB - 8.12x memory usage +1976.87 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: large_payload_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex       10.52 K       95.06 μs     ±6.26%       93.75 μs      108.96 μs
JsonXema         4.56 K      219.22 μs   ±382.20%      200.42 μs      264.00 μs
JSV              1.68 K      595.43 μs    ±24.23%      569.96 μs      898.99 μs

Comparison:
JSONSchex       10.52 K
JsonXema         4.56 K - 2.31x slower +124.16 μs
JSV              1.68 K - 6.26x slower +500.37 μs

Memory usage statistics:

Name         Memory usage
JSONSchex       243.89 KB
JsonXema        229.59 KB - 0.94x memory usage -14.29688 KB
JSV            1914.99 KB - 7.85x memory usage +1671.10 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: property_names_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      147.70 K        6.77 μs   ±101.98%        6.42 μs          19 μs
JsonXema       116.15 K        8.61 μs    ±75.94%        8.33 μs       15.33 μs
JSV            104.57 K        9.56 μs    ±38.51%        9.38 μs       13.17 μs

Comparison:
JSONSchex      147.70 K
JsonXema       116.15 K - 1.27x slower +1.84 μs
JSV            104.57 K - 1.41x slower +2.79 μs

Memory usage statistics:

Name         Memory usage
JSONSchex            4 KB
JsonXema          5.78 KB - 1.45x memory usage +1.78 KB
JSV              18.55 KB - 4.64x memory usage +14.55 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: property_names_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      141.32 K        7.08 μs    ±92.95%        6.88 μs       10.92 μs
JSV             99.85 K       10.02 μs    ±42.12%        9.79 μs       15.13 μs
JsonXema        97.20 K       10.29 μs    ±45.22%       10.08 μs       16.04 μs

Comparison:
JSONSchex      141.32 K
JSV             99.85 K - 1.42x slower +2.94 μs
JsonXema        97.20 K - 1.45x slower +3.21 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         4.59 KB
JSV              16.09 KB - 3.51x memory usage +11.50 KB
JsonXema         10.79 KB - 2.35x memory usage +6.20 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_email_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1407.03 K        0.71 μs   ±914.28%        0.54 μs        2.25 μs
JsonXema       371.24 K        2.69 μs  ±1226.79%           2 μs        6.17 μs
JSV            342.78 K        2.92 μs   ±212.56%        2.71 μs           7 μs

Comparison:
JSONSchex     1407.03 K
JsonXema       371.24 K - 3.79x slower +1.98 μs
JSV            342.78 K - 4.10x slower +2.21 μs

Memory usage statistics:

Name         Memory usage
JSONSchex           720 B
JsonXema            560 B - 0.78x memory usage -160 B
JSV               17048 B - 23.68x memory usage +16328 B

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_email_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     4541.94 K        0.22 μs  ±3525.16%       0.167 μs        0.33 μs
JSV            412.48 K        2.42 μs   ±292.82%        2.29 μs        3.83 μs
JsonXema       387.04 K        2.58 μs   ±778.70%        1.92 μs        6.33 μs

Comparison:
JSONSchex     4541.94 K
JSV            412.48 K - 11.01x slower +2.20 μs
JsonXema       387.04 K - 11.74x slower +2.36 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         0.40 KB
JSV              11.30 KB - 28.37x memory usage +10.91 KB
JsonXema          1.24 KB - 3.12x memory usage +0.84 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_date_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        6.49 M      154.02 ns  ±5187.02%         125 ns         250 ns
JSV              1.55 M      646.92 ns  ±1147.01%         583 ns         834 ns
JsonXema         0.59 M     1705.06 ns   ±650.13%        1333 ns        5541 ns

Comparison:
JSONSchex        6.49 M
JSV              1.55 M - 4.20x slower +492.90 ns
JsonXema         0.59 M - 11.07x slower +1551.04 ns

Memory usage statistics:

Name         Memory usage
JSONSchex         0.52 KB
JSV               1.78 KB - 3.45x memory usage +1.27 KB
JsonXema          1.06 KB - 2.06x memory usage +0.55 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_date_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        4.45 M      224.73 ns  ±3621.99%         125 ns         250 ns
JSV              1.42 M      706.24 ns  ±1087.72%         666 ns         875 ns
JsonXema         0.68 M     1473.82 ns   ±805.07%        1125 ns        4667 ns

Comparison:
JSONSchex        4.45 M
JSV              1.42 M - 3.14x slower +481.51 ns
JsonXema         0.68 M - 6.56x slower +1249.09 ns

Memory usage statistics:

Name         Memory usage
JSONSchex         0.44 KB
JSV               1.77 KB - 4.05x memory usage +1.34 KB
JsonXema          1.05 KB - 2.41x memory usage +0.62 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_iri_ref_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      301.05 K        3.32 μs   ±240.67%        2.83 μs        7.38 μs
JSV            262.54 K        3.81 μs   ±257.99%        3.29 μs       10.08 μs

Comparison:
JSONSchex      301.05 K
JSV            262.54 K - 1.15x slower +0.49 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.87 KB
JSV              13.47 KB - 4.70x memory usage +10.60 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_iri_ref_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 18 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSV            959.63 K        1.04 μs   ±713.27%        0.96 μs        1.54 μs
JSONSchex      261.92 K        3.82 μs   ±223.58%        3.21 μs        9.17 μs

Comparison:
JSV            959.63 K
JSONSchex      261.92 K - 3.66x slower +2.78 μs

Memory usage statistics:

Name         Memory usage
JSV               4.29 KB
JSONSchex         3.28 KB - 0.77x memory usage -1.00781 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_uri_ref_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1694.54 K        0.59 μs  ±1285.57%        0.54 μs        0.71 μs
JsonXema       181.60 K        5.51 μs   ±275.70%        4.83 μs       10.25 μs
JSV            166.49 K        6.01 μs   ±223.07%        5.38 μs       19.42 μs

Comparison:
JSONSchex     1694.54 K
JsonXema       181.60 K - 9.33x slower +4.92 μs
JSV            166.49 K - 10.18x slower +5.42 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         0.90 KB
JsonXema          1.34 KB - 1.50x memory usage +0.45 KB
JSV              29.32 KB - 32.63x memory usage +28.42 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_uri_ref_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1215.76 K        0.82 μs   ±811.32%        0.75 μs           1 μs
JSV            214.95 K        4.65 μs   ±165.33%        4.38 μs       12.96 μs
JsonXema        98.59 K       10.14 μs   ±163.53%        8.75 μs       22.75 μs

Comparison:
JSONSchex     1215.76 K
JSV            214.95 K - 5.66x slower +3.83 μs
JsonXema        98.59 K - 12.33x slower +9.32 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         1.11 KB
JSV              27.01 KB - 24.35x memory usage +25.90 KB
JsonXema          3.70 KB - 3.33x memory usage +2.59 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_ipv4_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        4.80 M      208.24 ns  ±3733.68%         167 ns         250 ns
JSV              1.34 M      748.01 ns   ±806.30%         667 ns        1041 ns
JsonXema         0.81 M     1240.47 ns  ±1081.18%        1000 ns        3916 ns

Comparison:
JSONSchex        4.80 M
JSV              1.34 M - 3.59x slower +539.77 ns
JsonXema         0.81 M - 5.96x slower +1032.22 ns

Memory usage statistics:

Name         Memory usage
JSONSchex           552 B
JSV                2328 B - 4.22x memory usage +1776 B
JsonXema            240 B - 0.43x memory usage -312 B

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_ipv4_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     7350.76 K       0.136 μs  ±6204.54%      0.0840 μs        0.21 μs
JSV            960.01 K        1.04 μs   ±539.24%        0.96 μs        1.42 μs
JsonXema       796.30 K        1.26 μs   ±842.43%        0.96 μs        4.04 μs

Comparison:
JSONSchex     7350.76 K
JSV            960.01 K - 7.66x slower +0.91 μs
JsonXema       796.30 K - 9.23x slower +1.12 μs

Memory usage statistics:

Name         Memory usage
JSONSchex           448 B
JSV                2992 B - 6.68x memory usage +2544 B
JsonXema            928 B - 2.07x memory usage +480 B

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_combo_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex      693.35 K        1.44 μs   ±520.80%        1.38 μs        1.92 μs
JSV            117.79 K        8.49 μs    ±72.35%        7.63 μs       22.71 μs
JsonXema       100.48 K        9.95 μs   ±284.71%        8.33 μs       21.63 μs

Comparison:
JSONSchex      693.35 K
JSV            117.79 K - 5.89x slower +7.05 μs
JsonXema       100.48 K - 6.90x slower +8.51 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.76 KB
JSV              35.10 KB - 12.73x memory usage +32.34 KB
JsonXema          2.91 KB - 1.06x memory usage +0.156 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: format_combo_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex     1079.65 K        0.93 μs   ±831.94%        0.88 μs        1.17 μs
JSV            172.46 K        5.80 μs   ±115.24%        5.50 μs       14.71 μs
JsonXema        86.57 K       11.55 μs    ±88.61%       10.21 μs       31.58 μs

Comparison:
JSONSchex     1079.65 K
JSV            172.46 K - 6.26x slower +4.87 μs
JsonXema        86.57 K - 12.47x slower +10.63 μs

Memory usage statistics:

Name         Memory usage
JSONSchex         2.33 KB
JSV              25.05 KB - 10.76x memory usage +22.73 KB
JsonXema          6.09 KB - 2.61x memory usage +3.76 KB

**All measurements for memory usage were the same**

============================================================
  Benchmark: dependencies_valid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        4.99 M      200.46 ns  ±2918.84%         167 ns         292 ns
JsonXema         1.58 M      634.44 ns   ±906.38%         584 ns         792 ns
JSV              1.39 M      719.56 ns   ±766.17%         667 ns         917 ns

Comparison:
JSONSchex        4.99 M
JsonXema         1.58 M - 3.16x slower +433.98 ns
JSV              1.39 M - 3.59x slower +519.10 ns

Memory usage statistics:

Name         Memory usage
JSONSchex           384 B
JsonXema            504 B - 1.31x memory usage +120 B
JSV                2272 B - 5.92x memory usage +1888 B

**All measurements for memory usage were the same**

============================================================
  Benchmark: dependencies_invalid
============================================================
Operating System: macOS
CPU Information: Apple M2 Pro
Number of Available Cores: 10
Available memory: 16 GB
Elixir 1.19.5
Erlang 28.2
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: none specified
Estimated total run time: 27 s
Excluding outliers: false

Benchmarking JSONSchex ...
Benchmarking JSV ...
Benchmarking JsonXema ...
Calculating statistics...
Formatting results...

Name                ips        average  deviation         median         99th %
JSONSchex        3.85 M      259.92 ns  ±2191.59%         166 ns         333 ns
JSV              1.34 M      748.41 ns   ±971.92%         708 ns         958 ns
JsonXema         0.79 M     1261.79 ns   ±583.59%        1208 ns        1625 ns

Comparison:
JSONSchex        3.85 M
JSV              1.34 M - 2.88x slower +488.49 ns
JsonXema         0.79 M - 4.85x slower +1001.88 ns

Memory usage statistics:

Name         Memory usage
JSONSchex         0.52 KB
JSV               2.16 KB - 4.20x memory usage +1.65 KB
JsonXema          3.37 KB - 6.53x memory usage +2.85 KB

**All measurements for memory usage were the same**

============================================================
  All benchmarks complete!
============================================================

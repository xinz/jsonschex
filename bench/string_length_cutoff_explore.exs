# Run from the repository root:
#   mix run bench/string_length_cutoff_explore.exs --quick
#   mix run bench/string_length_cutoff_explore.exs --extended
#
# Optional modes:
#   mix run bench/string_length_cutoff_explore.exs --focus
#   mix run bench/string_length_cutoff_explore.exs --all-raw
#
# --quick retains the exhaustive 0..256-byte generated scan with a bounded
# sampling configuration. --extended uses a sparse grid through 16 KiB and
# emits compact direct-counter results suitable for cutoff decisions.
#
# This explores the cutoff only. It deliberately duplicates the two existing
# counting implementations so neither benchmark path is selected by byte size.

defmodule StringLengthCutoffExplore do
  alias JSONSchex.Compiler.Predicates

  @production_cutoff 256
  @full_sizes Enum.to_list(0..256)
  @focus_sizes [
    0,
    1,
    16,
    30,
    31,
    32,
    33,
    46,
    47,
    48,
    49,
    62,
    63,
    64,
    65,
    66,
    79,
    80,
    81,
    95,
    96,
    97,
    127,
    128,
    129,
    130,
    131,
    132,
    133,
    134,
    135,
    136,
    137,
    138,
    139,
    140,
    141,
    142,
    143,
    144,
    255,
    256,
    257
  ]
  @extended_sizes [
    0,
    16,
    32,
    48,
    64,
    96,
    128,
    256,
    384,
    512,
    768,
    1_024,
    1_536,
    2_048,
    4_096,
    8_192,
    16_384
  ]
  @families [
    {:ascii, "ASCII", "a"},
    {:two_byte, "2-byte", "é"},
    {:three_byte, "3-byte", "漢"},
    {:four_byte, "4-byte", "😀"},
    {:mixed, "mixed", "aé漢😀"}
  ]
  @quick_config %{
    calibration_iterations: 128,
    warmup_iterations: 64,
    sample_count: 3,
    target_microseconds: 2_000,
    max_iterations: 100_000
  }
  @focus_config %{
    calibration_iterations: 256,
    warmup_iterations: 128,
    sample_count: 5,
    target_microseconds: 5_000,
    max_iterations: 100_000
  }
  @extended_config %{
    calibration_iterations: 64,
    warmup_iterations: 16,
    sample_count: 5,
    target_microseconds: 5_000,
    max_iterations: 20_000
  }
  @benchmark_timeout_ms 55_000

  def main(argv) do
    options = parse_args(argv)
    config = options.config
    cases = build_cases(options.sizes)
    {valid_count, malformed_count} = validate_cases!(cases)

    IO.puts(
      "String-length cutoff exploration (#{options.mode}); Elixir #{System.version()}, " <>
        "OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}"
    )

    IO.puts(
      "Validated #{valid_count} valid exact-byte inputs and #{malformed_count} malformed inputs " <>
        "against String.valid?/1 before timing."
    )

    IO.puts(
      "Timing: median of #{config.sample_count} samples; each sample targets " <>
        "#{config.target_microseconds} us; #{config.calibration_iterations} direct-call calibration " <>
        "iterations; GC before each sample."
    )

    IO.puts(
      "The timed paths are compiled tail-recursive loops invoked through :timer.tc/3; " <>
        "no anonymous function runs once per counted string."
    )

    results = bounded_benchmark(cases, options)

    case options.mode do
      :extended ->
        print_extended_rows(results)
        print_family_crossovers(results, options.sizes)
        print_extended_cutoff_scores(results)
        print_allocation_context()

      _ ->
        if options.print_focus? do
          print_focus_rows(results)
        end

        if options.print_all? do
          print_all_rows(results)
        end

        print_family_crossovers(results, options.sizes)

        if options.sizes == @full_sizes do
          print_cutoff_scores(results)
        else
          IO.puts("\nCutoff score table skipped: this mode does not contain every byte size from 0 through 256.")
        end
    end
  end

  # This is the former short-string implementation, including its malformed
  # UTF-8 result contract.
  def original_charlist_count(binary) do
    binary |> String.to_charlist() |> length()
  rescue
    UnicodeConversionError -> :error
  end

  # This is the current long-string implementation, intentionally independent
  # of the production cutoff so it can be timed at every input size.
  def current_unrolled_count(binary), do: count_codepoints(binary, 0)

  def run_charlist(binary, iterations), do: repeat_charlist(binary, iterations, 0)
  def run_unrolled(binary, iterations), do: repeat_unrolled(binary, iterations, 0)
  def run_public_min(binary, minimum, iterations), do: repeat_public_min(binary, minimum, iterations, 0)
  def run_benchmark(cases, config, public_sizes), do: benchmark(cases, config, public_sizes)

  defp bounded_benchmark(cases, options) do
    task = Task.async(__MODULE__, :run_benchmark, [cases, options.config, options.public_sizes])

    case Task.yield(task, @benchmark_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, results} -> results
      _ -> raise "Benchmark exceeded the #{@benchmark_timeout_ms} ms measurement budget"
    end
  end

  defp parse_args([]), do: quick_options(false)
  defp parse_args(["--quick"]), do: quick_options(false)
  defp parse_args(["--all-raw"]), do: quick_options(true)

  defp parse_args(["--focus"]) do
    %{
      mode: :focus,
      sizes: @focus_sizes,
      config: @focus_config,
      public_sizes: @focus_sizes,
      print_focus?: true,
      print_all?: false
    }
  end

  defp parse_args(["--extended"]) do
    %{
      mode: :extended,
      sizes: @extended_sizes,
      config: @extended_config,
      public_sizes: [],
      print_focus?: false,
      print_all?: false
    }
  end

  defp parse_args(_) do
    raise "Usage: mix run bench/string_length_cutoff_explore.exs [--quick | --extended | --focus | --all-raw]"
  end

  defp quick_options(print_all?) do
    %{
      mode: :quick,
      sizes: @full_sizes,
      config: @quick_config,
      public_sizes: if(print_all?, do: @focus_sizes, else: []),
      print_focus?: print_all?,
      print_all?: print_all?
    }
  end

  defp build_cases(sizes) do
    for bytes <- sizes, {family, label, unit} <- @families do
      data = exact_bytes(unit, bytes)

      %{
        family: family,
        label: label,
        bytes: bytes,
        data: data,
        codepoints: length(String.to_charlist(data))
      }
    end
  end

  # Exact arbitrary byte sizes require ASCII padding whenever a requested size
  # is not divisible by the selected multibyte unit's encoded width.
  defp exact_bytes(unit, bytes) do
    whole_units = div(bytes, byte_size(unit))
    padding_bytes = rem(bytes, byte_size(unit))
    String.duplicate(unit, whole_units) <> String.duplicate("a", padding_bytes)
  end

  defp validate_cases!(cases) do
    Enum.each(cases, &validate_valid_case!/1)

    malformed = malformed_cases()
    Enum.each(malformed, &validate_malformed_case!/1)

    {length(cases), length(malformed)}
  end

  defp validate_valid_case!(%{label: label, bytes: bytes, data: data, codepoints: expected}) do
    unless byte_size(data) == bytes do
      raise "#{label} input has #{byte_size(data)} bytes, expected #{bytes}"
    end

    unless String.valid?(data) do
      raise "#{label} input at #{bytes} bytes is not valid UTF-8"
    end

    charlist_count = original_charlist_count(data)
    unrolled_count = current_unrolled_count(data)

    unless charlist_count == expected and unrolled_count == expected do
      raise(
        "#{label} input at #{bytes} bytes disagrees with String.to_charlist/1: " <>
          "charlist=#{inspect(charlist_count)} unrolled=#{inspect(unrolled_count)} expected=#{expected}"
      )
    end

    case Predicates.check_min_length(data, expected) do
      :ok -> :ok
      result -> raise "public check_min_length/2 rejected valid #{label} input: #{inspect(result)}"
    end
  end

  defp validate_malformed_case!({label, data}) do
    if String.valid?(data) do
      raise "#{label} unexpectedly passes String.valid?/1"
    end

    charlist_count = original_charlist_count(data)
    unrolled_count = current_unrolled_count(data)

    unless charlist_count == :error and unrolled_count == :error do
      raise(
        "#{label} malformed result mismatch: " <>
          "charlist=#{inspect(charlist_count)} unrolled=#{inspect(unrolled_count)}"
      )
    end

    case Predicates.check_min_length(data, 0) do
      {:error, %{contrast: 0, input: ^data, error_detail: "invalid_utf8"}} -> :ok
      result -> raise "#{label} public malformed result mismatch: #{inspect(result)}"
    end
  end

  defp malformed_cases do
    [
      {"lone continuation", <<0x80>>},
      {"invalid leader", <<0xFF>>},
      {"overlong sequence", <<0xC0, 0x80>>},
      {"bad continuation", <<0xE2, 0x82, 0x41>>},
      {"surrogate encoding", <<0xED, 0xA0, 0x80>>},
      {"out-of-range scalar", <<0xF4, 0x90, 0x80, 0x80>>},
      {"truncated scalar", <<0xF0, 0x90, 0x80>>},
      {"255-byte malformed tail", String.duplicate("a", 254) <> <<0xFF>>},
      {"256-byte malformed tail", String.duplicate("a", 255) <> <<0xFF>>},
      {"257-byte malformed tail", String.duplicate("a", 256) <> <<0xFF>>},
      {"long mixed malformed tail", String.duplicate("aé漢😀", 7) <> <<0xFF>>}
    ]
  end

  defp benchmark(cases, config, public_sizes) do
    for input <- cases do
      benchmark_case(input, config, public_sizes)
    end
  end

  defp benchmark_case(%{bytes: bytes, data: data, codepoints: codepoints} = input, config, public_sizes) do
    {charlist, unrolled} =
      if rem(bytes, 2) == 0 do
        {measure_charlist(data, codepoints, config), measure_unrolled(data, codepoints, config)}
      else
        unrolled = measure_unrolled(data, codepoints, config)
        charlist = measure_charlist(data, codepoints, config)
        {charlist, unrolled}
      end

    public =
      if bytes in public_sizes do
        measure_public_min(data, codepoints, config)
      else
        nil
      end

    Map.merge(input, %{charlist: charlist, unrolled: unrolled, public: public})
  end

  defp measure_charlist(binary, expected, config) do
    warmup_iterations = config.warmup_iterations
    expected_total = expected * warmup_iterations

    unless run_charlist(binary, warmup_iterations) == expected_total do
      raise "charlist warmup did not preserve the expected count"
    end

    :erlang.garbage_collect()
    calibration_us = time_charlist(binary, expected, config.calibration_iterations)
    iterations = iterations_for(calibration_us, config)
    samples = charlist_samples(binary, expected, iterations, config.sample_count, [])
    measurement(samples, iterations, config.sample_count)
  end

  defp measure_unrolled(binary, expected, config) do
    warmup_iterations = config.warmup_iterations
    expected_total = expected * warmup_iterations

    unless run_unrolled(binary, warmup_iterations) == expected_total do
      raise "unrolled warmup did not preserve the expected count"
    end

    :erlang.garbage_collect()
    calibration_us = time_unrolled(binary, expected, config.calibration_iterations)
    iterations = iterations_for(calibration_us, config)
    samples = unrolled_samples(binary, expected, iterations, config.sample_count, [])
    measurement(samples, iterations, config.sample_count)
  end

  defp measure_public_min(binary, minimum, config) do
    warmup_iterations = config.warmup_iterations

    unless run_public_min(binary, minimum, warmup_iterations) == warmup_iterations do
      raise "public predicate warmup did not preserve the expected result"
    end

    :erlang.garbage_collect()
    calibration_us = time_public_min(binary, minimum, config.calibration_iterations)
    iterations = iterations_for(calibration_us, config)
    samples = public_min_samples(binary, minimum, iterations, config.sample_count, [])
    measurement(samples, iterations, config.sample_count)
  end

  defp iterations_for(calibration_us, config) do
    estimated = div(config.target_microseconds * config.calibration_iterations, max(calibration_us, 1))
    min(max(estimated, 1), config.max_iterations)
  end

  defp charlist_samples(_binary, _expected, _iterations, 0, samples), do: Enum.reverse(samples)

  defp charlist_samples(binary, expected, iterations, remaining, samples) do
    :erlang.garbage_collect()
    microseconds = time_charlist(binary, expected, iterations)
    sample = nanoseconds_per_operation(microseconds, iterations)
    charlist_samples(binary, expected, iterations, remaining - 1, [sample | samples])
  end

  defp unrolled_samples(_binary, _expected, _iterations, 0, samples), do: Enum.reverse(samples)

  defp unrolled_samples(binary, expected, iterations, remaining, samples) do
    :erlang.garbage_collect()
    microseconds = time_unrolled(binary, expected, iterations)
    sample = nanoseconds_per_operation(microseconds, iterations)
    unrolled_samples(binary, expected, iterations, remaining - 1, [sample | samples])
  end

  defp public_min_samples(_binary, _minimum, _iterations, 0, samples), do: Enum.reverse(samples)

  defp public_min_samples(binary, minimum, iterations, remaining, samples) do
    :erlang.garbage_collect()
    microseconds = time_public_min(binary, minimum, iterations)
    sample = nanoseconds_per_operation(microseconds, iterations)
    public_min_samples(binary, minimum, iterations, remaining - 1, [sample | samples])
  end

  defp time_charlist(binary, expected, iterations) do
    {microseconds, total} = :timer.tc(__MODULE__, :run_charlist, [binary, iterations])
    expected_total = expected * iterations

    unless total == expected_total do
      raise "charlist timed loop returned #{inspect(total)}, expected #{expected_total}"
    end

    microseconds
  end

  defp time_unrolled(binary, expected, iterations) do
    {microseconds, total} = :timer.tc(__MODULE__, :run_unrolled, [binary, iterations])
    expected_total = expected * iterations

    unless total == expected_total do
      raise "unrolled timed loop returned #{inspect(total)}, expected #{expected_total}"
    end

    microseconds
  end

  defp time_public_min(binary, minimum, iterations) do
    {microseconds, total} = :timer.tc(__MODULE__, :run_public_min, [binary, minimum, iterations])

    unless total == iterations do
      raise "public timed loop returned #{inspect(total)}, expected #{iterations}"
    end

    microseconds
  end

  defp nanoseconds_per_operation(microseconds, iterations), do: microseconds * 1_000.0 / iterations

  defp measurement(samples, iterations, sample_count) do
    sorted = Enum.sort(samples)

    %{
      samples: samples,
      median: Enum.at(sorted, div(sample_count, 2)),
      iterations: iterations
    }
  end

  defp repeat_charlist(_binary, 0, total), do: total

  defp repeat_charlist(binary, remaining, total) do
    count = original_charlist_count(binary)
    repeat_charlist(binary, remaining - 1, total + count)
  end

  defp repeat_unrolled(_binary, 0, total), do: total

  defp repeat_unrolled(binary, remaining, total) do
    count = current_unrolled_count(binary)
    repeat_unrolled(binary, remaining - 1, total + count)
  end

  defp repeat_public_min(_binary, _minimum, 0, total), do: total

  defp repeat_public_min(binary, minimum, remaining, total) do
    case Predicates.check_min_length(binary, minimum) do
      :ok -> repeat_public_min(binary, minimum, remaining - 1, total + 1)
      result -> raise "public predicate unexpectedly returned #{inspect(result)}"
    end
  end

  # Match the production long-input counter exactly: four decoded codepoints per
  # recursive step, then a one-codepoint tail, an empty binary, or an error.
  defp count_codepoints(<<_::utf8, _::utf8, _::utf8, _::utf8, rest::binary>>, count),
    do: count_codepoints(rest, count + 4)

  defp count_codepoints(<<_codepoint::utf8, rest::binary>>, count),
    do: count_codepoints(rest, count + 1)

  defp count_codepoints(<<>>, count), do: count
  defp count_codepoints(_invalid, _count), do: :error

  defp print_focus_rows(results) do
    IO.puts("\nFocused raw measurements (ns/op; samples are raw timed-loop samples)")
    IO.puts(
      "family,bytes,codepoints,charlist median [samples] n,unrolled median [samples] n," <>
        "public check_min_length median [samples] n,winner"
    )

    results
    |> Enum.filter(&(&1.bytes in @focus_sizes))
    |> Enum.each(fn result ->
      IO.puts(
        "#{result.label},#{result.bytes},#{result.codepoints}," <>
          "#{measurement_text(result.charlist)},#{measurement_text(result.unrolled)}," <>
          "#{measurement_text(result.public)},#{winner(result)}"
      )
    end)
  end

  defp print_all_rows(results) do
    IO.puts("\nAll scan medians (ns/op; use the focused rows above for raw samples)")
    IO.puts("family,bytes,codepoints,charlist median,unrolled median,winner")

    Enum.each(results, fn result ->
      IO.puts(
        "#{result.label},#{result.bytes},#{result.codepoints}," <>
          "#{format_ns(result.charlist.median)},#{format_ns(result.unrolled.median)},#{winner(result)}"
      )
    end)
  end

  defp print_extended_rows(results) do
    IO.puts("\nExtended direct-counter medians (ns/op; C/U means charlist/unrolled)")
    IO.puts("bytes,ASCII,2-byte,3-byte,4-byte,mixed")

    Enum.each(@extended_sizes, fn bytes ->
      measurements =
        Enum.map(@families, fn {family, _label, _unit} ->
          result = Enum.find(results, &(&1.bytes == bytes and &1.family == family))

          "#{result.codepoints}cp #{format_ns(result.charlist.median)}/" <>
            format_ns(result.unrolled.median)
        end)

      IO.puts(Enum.join([Integer.to_string(bytes) | measurements], ","))
    end)
  end

  defp print_extended_cutoff_scores(results) do
    cutoffs = [-1, 64, 128, 256, 384, 512, 768, 1_024]
    candidates =
      Enum.map(cutoffs, fn cutoff ->
        %{cutoff: cutoff, mean: strategy_score(results, cutoff) / length(results)}
      end)

    best = Enum.min_by(candidates, & &1.mean)

    IO.puts("\nEqual-weight fixed-cutoff score on this sparse extended grid (mean ns/op; lower is better)")
    IO.puts("cutoff,mean ns/op,from best")

    Enum.each(candidates, fn candidate ->
      IO.puts(
        "#{cutoff_label(candidate.cutoff)},#{format_ns(candidate.mean)}," <>
          "#{format_percent(candidate.mean / best.mean - 1.0)}"
      )
    end)
  end

  defp print_allocation_context do
    IO.puts(
      "\nAllocation context: charlist counting allocates one list element per code point; " <>
        "the unrolled counter avoids that allocation. This timing comparison does not measure heap words."
    )
  end

  defp print_family_crossovers(results, sizes) do
    IO.puts("\nPer-family crossover scan")

    IO.puts(
      "family,first unrolled median win,first charlist median win,last charlist median win," <>
        "stable charlist win through final selected byte,stable unrolled win through final selected byte"
    )

    Enum.each(@families, fn {family, label, _unit} ->
      family_results = Enum.filter(results, &(&1.family == family))
      first_unrolled = first_unrolled_win(family_results)
      first_charlist = first_charlist_win(family_results)
      last_charlist = last_charlist_win(family_results)
      stable_charlist = stable_charlist_win(family_results, sizes)
      stable_unrolled = stable_unrolled_win(family_results, sizes)

      IO.puts(
        "#{label},#{format_byte(first_unrolled)},#{format_byte(first_charlist)}," <>
          "#{format_byte(last_charlist)},#{format_byte(stable_charlist)},#{format_byte(stable_unrolled)}"
      )
    end)
  end

  defp first_unrolled_win(results) do
    results
    |> Enum.find(fn result -> result.unrolled.median <= result.charlist.median end)
    |> byte_or_nil()
  end

  defp first_charlist_win(results) do
    results
    |> Enum.find(fn result -> result.charlist.median <= result.unrolled.median end)
    |> byte_or_nil()
  end

  defp last_charlist_win(results) do
    results
    |> Enum.filter(fn result -> result.charlist.median < result.unrolled.median end)
    |> List.last()
    |> byte_or_nil()
  end

  defp stable_charlist_win(results, sizes) do
    Enum.find(sizes, fn bytes ->
      Enum.all?(results, fn result ->
        result.bytes < bytes or result.charlist.median <= result.unrolled.median
      end)
    end)
  end

  defp stable_unrolled_win(results, sizes) do
    Enum.find(sizes, fn bytes ->
      Enum.all?(results, fn result ->
        result.bytes < bytes or result.unrolled.median <= result.charlist.median
      end)
    end)
  end

  defp byte_or_nil(nil), do: nil
  defp byte_or_nil(result), do: result.bytes
  defp format_byte(nil), do: "none"
  defp format_byte(bytes), do: Integer.to_string(bytes)

  defp print_cutoff_scores(results) do
    candidates =
      for cutoff <- [-1 | @full_sizes] do
        %{cutoff: cutoff, mean: strategy_score(results, cutoff) / length(results)}
      end

    best = Enum.min_by(candidates, & &1.mean)
    current = Enum.find(candidates, &(&1.cutoff == @production_cutoff))
    charlist_only = Enum.find(candidates, &(&1.cutoff == 256))
    unrolled_only = Enum.find(candidates, &(&1.cutoff == -1))

    IO.puts("\nEqual-weight fixed-cutoff score across all families and byte sizes (mean ns/op; lower is better)")
    IO.puts("best measured cutoff: #{cutoff_label(best.cutoff)} at #{format_ns(best.mean)} ns/op")
    IO.puts(
      "current cutoff <= #{@production_cutoff}: #{format_ns(current.mean)} ns/op " <>
        "(#{format_percent(current.mean / best.mean - 1.0)} from best)"
    )
    IO.puts(
      "charlist only: #{format_ns(charlist_only.mean)} ns/op " <>
        "(#{format_percent(charlist_only.mean / best.mean - 1.0)} from best)"
    )
    IO.puts(
      "unrolled only: #{format_ns(unrolled_only.mean)} ns/op " <>
        "(#{format_percent(unrolled_only.mean / best.mean - 1.0)} from best)"
    )

    selected_cutoffs =
      [-1, 0, 16, 31, 32, 47, 48, 63, 64, 65, 80, 96, 128, 256, best.cutoff]
      |> Enum.uniq()
      |> Enum.sort()

    IO.puts("cutoff,mean ns/op,from best")

    Enum.each(selected_cutoffs, fn cutoff ->
      candidate = Enum.find(candidates, &(&1.cutoff == cutoff))
      IO.puts(
        "#{cutoff_label(cutoff)},#{format_ns(candidate.mean)}," <>
          "#{format_percent(candidate.mean / best.mean - 1.0)}"
      )
    end)
  end

  defp strategy_score(results, cutoff) do
    Enum.reduce(results, 0.0, fn result, total ->
      measurement = if result.bytes <= cutoff, do: result.charlist, else: result.unrolled
      total + measurement.median
    end)
  end

  defp winner(result) do
    if result.charlist.median <= result.unrolled.median, do: "charlist", else: "unrolled"
  end

  defp measurement_text(nil), do: "-"

  defp measurement_text(%{median: median, samples: samples, iterations: iterations}) do
    raw = samples |> Enum.map(&format_ns/1) |> Enum.join(" ")
    "#{format_ns(median)} [#{raw}] n=#{iterations}"
  end

  defp format_ns(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_percent(value), do: :erlang.float_to_binary(value * 100.0, decimals: 2) <> "%"
  defp cutoff_label(-1), do: "unrolled-only"
  defp cutoff_label(cutoff), do: "<= #{cutoff}"
end

StringLengthCutoffExplore.main(System.argv())

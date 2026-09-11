# Run from the repository root:
#   mix run bench/string_length_cutoff_validation.exs --focus
#   mix run bench/string_length_cutoff_validation.exs --cutoffs 64,256 --bytes 64,65,128,256,257
#
# Compares fixed byte cutoffs through the public predicate and JSONSchex.validate/2.
# The predicate source is compiled in memory per candidate; no source file changes.
# `--focus` uses the current and proposed cutoffs at their relevant boundaries.

root = Path.expand("..", __DIR__)
predicate_path = Path.join(root, "lib/jsonschex/compiler/predicates.ex")
predicate_source = File.read!(predicate_path)

IO.puts(
  "String-length cutoff validation; Elixir #{System.version()}, OTP #{System.otp_release()}, " <>
    "schedulers #{System.schedulers_online()}"
)



defmodule StringLengthCutoffValidation do
  alias JSONSchex.Compiler.Predicates

  @default_cutoffs [64, 128, 256, 512]
  @default_bytes [64, 65, 128, 256, 257, 384, 512, 513, 768]
  @focus_cutoffs [64, 256]
  @focus_bytes [64, 65, 128, 256, 257]
  @default_timing %{sample_count: 3, target_microseconds: 5_000, max_iterations: 100_000}
  @focus_timing %{sample_count: 3, target_microseconds: 5_000, max_iterations: 100_000}
  @families [
    {:ascii, "ASCII", "a"},
    {:two_byte, "2-byte", "é"},
    {:three_byte, "3-byte", "漢"},
    {:four_byte, "4-byte", "😀"},
    {:mixed, "mixed", "aé漢😀"}
  ]

  def run(source, path, argv) do
    options = parse_args(argv)
    cases = build_cases(options.bytes)

    IO.puts(
      "Median us/op; #{options.timing.sample_count} adaptive batches targeting " <>
        "#{options.timing.target_microseconds} us; input/schema construction, candidate compilation, " <>
        "warmup and explicit GC excluded"
    )

    IO.puts(
      "Cutoffs: #{Enum.join(options.cutoffs, ", ")}; bytes: #{Enum.join(options.bytes, ", ")}"
    )

    for cutoff <- options.cutoffs do
      load_candidate!(source, path, cutoff)

      Enum.each(cases, fn %{label: label, bytes: bytes, codepoints: codepoints, data: data, schema: schema} ->
        predicate = measure(fn -> :ok = Predicates.check_min_length(data, codepoints) end, options.timing)
        validation = measure(fn -> :ok = JSONSchex.validate(schema, data) end, options.timing)

        IO.puts(
          "cutoff=#{cutoff},#{label},bytes=#{bytes},codepoints=#{codepoints}," <>
            "predicate_us=#{Float.round(predicate, 3)},validate_both_us=#{Float.round(validation, 3)}"
        )
      end)
    end
  end

  defp parse_args(argv) do
    {options, arguments, invalid} =
      OptionParser.parse(argv, strict: [focus: :boolean, cutoffs: :string, bytes: :string])

    if arguments != [] or invalid != [] do
      raise "Usage: mix run bench/string_length_cutoff_validation.exs [--focus | --cutoffs 64,256 --bytes 64,65]"
    end

    if Keyword.get(options, :focus, false) do
      if Keyword.has_key?(options, :cutoffs) or Keyword.has_key?(options, :bytes) do
        raise "--focus cannot be combined with --cutoffs or --bytes"
      end

      %{cutoffs: @focus_cutoffs, bytes: @focus_bytes, timing: @focus_timing}
    else
      %{
        cutoffs: parse_integer_list(Keyword.get(options, :cutoffs), @default_cutoffs, "cutoffs"),
        bytes: parse_integer_list(Keyword.get(options, :bytes), @default_bytes, "bytes"),
        timing: @default_timing
      }
    end
  end

  defp parse_integer_list(nil, default, _name), do: default

  defp parse_integer_list(value, _default, name) do
    values = String.split(value, ",", trim: true)

    if values == [] do
      raise "--#{name} must contain at least one non-negative integer"
    end

    Enum.map(values, fn text ->
      case Integer.parse(text) do
        {integer, ""} when integer >= 0 -> integer
        _ -> raise "--#{name} must contain comma-separated non-negative integers"
      end
    end)
  end

  defp build_cases(bytes_list) do
    for bytes <- bytes_list, {_family, label, unit} <- @families do
      data = exact_bytes(unit, bytes)
      codepoints = length(String.to_charlist(data))
      {:ok, schema} = JSONSchex.compile(%{"minLength" => codepoints, "maxLength" => codepoints})
      %{label: label, bytes: byte_size(data), codepoints: codepoints, data: data, schema: schema}
    end
  end

  defp exact_bytes(unit, bytes) do
    String.duplicate(unit, div(bytes, byte_size(unit))) <>
      String.duplicate("a", rem(bytes, byte_size(unit)))
  end

  defp load_candidate!(source, path, cutoff) do
    source = Regex.replace(~r/@charlist_byte_cutoff \d+/, source, "@charlist_byte_cutoff #{cutoff}")
    previous_options = Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_string(source, path)
    after
      Code.compiler_options(previous_options)
    end
  end

  defp measure(run, %{sample_count: sample_count, target_microseconds: target, max_iterations: max_iterations}) do
    run.()
    :erlang.garbage_collect()
    {calibration, _} = :timer.tc(fn -> Enum.each(1..10, fn _ -> run.() end) end)
    iterations = min(max_iterations, max(1, div(target * 10, max(1, calibration))))

    samples = for _ <- 1..sample_count do
      :erlang.garbage_collect()
      {us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> run.() end) end)
      us / iterations
    end

    samples |> Enum.sort() |> Enum.at(div(sample_count, 2))
  end
end

StringLengthCutoffValidation.run(predicate_source, predicate_path, System.argv())

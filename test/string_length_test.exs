defmodule JSONSchex.Test.StringLengthTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Compiler.Predicates
  alias JSONSchex.Types.{Error, ErrorContext}

  test "public min/max predicates count codepoints rather than bytes or graphemes" do
    for {data, count} <- valid_strings() do
      assert_predicate_bounds(data, bounds(count))
    end
  end

  test "compiled min/max validation counts codepoints rather than bytes or graphemes" do
    for {data, count} <- valid_strings() do
      assert_compiled_bounds(data, bounds(count))
      assert {:ok, compiled} = JSONSchex.compile(%{"minLength" => count, "maxLength" => count})
      assert JSONSchex.validate(compiled, data) == :ok
    end
  end

  test "UTF-8 scalar boundaries, NUL, and noncharacters remain valid codepoints" do
    # Cover encoding-width transitions and both sides of the surrogate gap.
    boundaries = [0x00, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF]
    noncharacters = Enum.to_list(0xFDD0..0xFDEF) ++
      for plane <- 0..16, suffix <- [0xFFFE, 0xFFFF], do: plane * 0x10000 + suffix
    codepoints = Enum.uniq(boundaries ++ noncharacters)
    combined = List.to_string(codepoints)

    for {data, count} <- [{combined, length(codepoints)} | Enum.map(codepoints, &{<<&1::utf8>>, 1})] do
      assert_predicate_bounds(data, bounds(count))
      assert_compiled_bounds(data, bounds(count))
    end
  end

  test "integral float limits accepted by the compiler preserve exact contexts" do
    for {data, count} <- valid_strings() ++ [{String.duplicate("aé€😀", 1024), 4096}] do
      float_bounds = Enum.map(bounds(count), fn {rule, limit, result} ->
        float_limit = limit * 1.0
        float_result = case result do
          :ok -> :ok
          {:error, context} -> {:error, %{context | contrast: float_limit}}
        end

        {rule, float_limit, float_result}
      end)

      assert_predicate_bounds(data, float_bounds)
      assert_compiled_bounds(data, float_bounds)
    end
  end

  test "both failing constraints report the full long-string length, not a cap" do
    data = String.duplicate("aé€😀", 4096)
    count = 16384

    for {min, max} <- [{count + 100, 1}, {(count + 100) * 1.0, 1.0}] do
      min_context = %ErrorContext{contrast: min, input: count}
      max_context = %ErrorContext{contrast: max, input: count}

      assert Predicates.check_min_length(data, min) === {:error, min_context}
      assert Predicates.check_max_length(data, max) === {:error, max_context}
      assert {:ok, compiled} = JSONSchex.compile(%{"minLength" => min, "maxLength" => max})
      assert {:error, errors} = JSONSchex.validate(compiled, data)
      assert length(errors) == 2
      assert Enum.find(errors, &(&1.rule == :minLength)) ===
               %Error{rule: :minLength, path: [], value: data, context: min_context}
      assert Enum.find(errors, &(&1.rule == :maxLength)) ===
               %Error{rule: :maxLength, path: [], value: data, context: max_context}
    end
  end

  test "length constraints remain no-ops for non-strings" do
    # No type constraint: even contradictory lengths must ignore non-strings.
    assert {:ok, compiled} = JSONSchex.compile(%{"minLength" => 10, "maxLength" => 0})

    for data <- [nil, true, false, 0, 1.5, [], [97, 98], %{}, %{"a" => "text"}, :atom, {1, 2}, <<1::size(1)>>] do
      assert Predicates.check_min_length(data, 10) == :ok
      assert Predicates.check_max_length(data, 0) == :ok
      assert JSONSchex.validate(compiled, data) == :ok
    end
  end

  test "public predicates return invalid_utf8 contexts for malformed UTF-8" do
    for {_label, data} <- invalid_strings() do
      for {rule, limit} <- invalid_bounds(data) do
        assert check_length(rule, data, limit) === {:error, invalid_context(data, limit)}
      end
    end
  end

  test "compiled validation reports malformed UTF-8 even with zero or loose bounds" do
    for {_label, data} <- invalid_strings() do
      for {rule, limit} <- invalid_bounds(data) do
        assert {:ok, compiled} = JSONSchex.compile(%{Atom.to_string(rule) => limit})
        assert JSONSchex.validate(compiled, data) ===
                 {:error, [%Error{rule: rule, path: [], value: data, context: invalid_context(data, limit)}]}
      end

      max = byte_size(data) + 1
      assert {:ok, compiled} = JSONSchex.compile(%{"minLength" => 0, "maxLength" => max})
      assert {:error, errors} = JSONSchex.validate(compiled, data)
      assert length(errors) == 2

      for {rule, limit} <- [{:minLength, 0}, {:maxLength, max}] do
        assert Enum.find(errors, &(&1.rule == rule)) ===
                 %Error{rule: rule, path: [], value: data, context: invalid_context(data, limit)}
      end
    end
  end

  test "malformed UTF-8 errors retain nested property and item paths" do
    data = "aé€" <> <<0xFF>>

    for {rule, limit} <- [{:minLength, 0}, {:maxLength, 100}] do
      schema = %{
        "properties" => %{
          "names" => %{"items" => %{Atom.to_string(rule) => limit}}
        }
      }

      assert {:ok, compiled} = JSONSchex.compile(schema)
      assert JSONSchex.validate(compiled, %{"names" => ["valid", data]}) ===
               {:error, [%Error{rule: rule, path: [1, "names"], value: data, context: invalid_context(data, limit)}]}
    end
  end

  test "malformed UTF-8 length errors format safely at root and property paths" do
    for {_label, data} <- invalid_strings(),
        {rule, limit} <- [{:minLength, 0}, {:maxLength, byte_size(data) + 1}] do
      length_schema = %{Atom.to_string(rule) => limit}
      message = "Cannot check #{rule}: string is not valid UTF-8"

      for {schema, input, path, expected_message} <- [
            {length_schema, data, [], message},
            {%{"properties" => %{"name" => length_schema}}, %{"name" => data}, ["name"], "At /name: " <> message}
          ] do
        assert {:ok, compiled} = JSONSchex.compile(schema)
        assert {:error, [error]} = JSONSchex.validate(compiled, input)
        assert error === %Error{rule: rule, path: path, value: data, context: invalid_context(data, limit)}
        formatted = JSONSchex.format_error(error)
        assert formatted == expected_message
        assert String.valid?(formatted)
        assert :binary.match(formatted, data) == :nomatch
      end
    end
  end

  test "all one-byte and two-byte binaries agree with the UTF-8 oracle" do
    for first <- 0..255 do
      assert_utf8_length_oracle(<<first>>)

      for second <- 0..255 do
        assert_utf8_length_oracle(<<first, second>>)
      end
    end
  end

  test "exact codepoint lengths span the short byte threshold and longer mixed widths" do
    for size <- [63, 64, 65, 127, 128, 129, 1023, 1024, 1025],
        unit <- ["a", "é", "€", "😀", "aé€😀", "😀€éa"] do
      repetitions = div(size, byte_size(unit))
      padding = String.duplicate("a", rem(size, byte_size(unit)))
      data = String.duplicate(unit, repetitions) <> padding

      assert byte_size(data) == size
      assert String.valid?(data)
      assert_utf8_length_oracle(data)
    end
  end

  test "restricted three-byte and four-byte leaders validate every second byte" do
    # Later continuation boundaries distinguish malformed tails from restrictions
    # on E0/ED/F0/F4's second byte (overlong, surrogate, and out-of-range scalars).
    continuations = [0x7F, 0x80, 0xBF, 0xC0]

    for second <- 0..255 do
      for leader <- [0xE0, 0xED], third <- continuations do
        assert_utf8_length_oracle(<<leader, second, third>>)
      end

      for leader <- [0xF0, 0xF4], third <- continuations, fourth <- continuations do
        assert_utf8_length_oracle(<<leader, second, third, fourth>>)
      end
    end
  end

  test "restricted and truncated sequences retain validation across the byte threshold" do
    continuations = [0x7F, 0x80, 0xBF, 0xC0]

    # Build prefixes once; changing their codepoint widths also changes the
    # remainder seen by the long counter's four-codepoint loop.
    prefixes = for size <- 59..64, unit <- ["a", "é", "€", "😀", "aé€😀"] do
      prefix = String.duplicate(unit, div(size, byte_size(unit))) <>
        String.duplicate("a", rem(size, byte_size(unit)))
      {size, prefix}
    end

    for leader <- [0xE0, 0xED, 0xF0, 0xF4], second <- 0..255 do
      tails = if leader in [0xE0, 0xED] do
        for third <- continuations, do: <<leader, second, third>>
      else
        for third <- continuations, fourth <- continuations,
          do: <<leader, second, third, fourth>>
      end

      truncated = if leader in [0xE0, 0xED] do
        [<<leader>>, <<leader, second>>]
      else
        [<<leader>>, <<leader, second>> | (for third <- continuations, do: <<leader, second, third>>)]
      end

      for bytes <- tails ++ truncated, {size, prefix} <- prefixes,
          size + byte_size(bytes) in [63, 64, 65] do
        assert_utf8_length_oracle(prefix <> bytes)
      end
    end
  end

  defp assert_utf8_length_oracle(data) do
    # Only convert valid UTF-8: invalid inputs must preserve the binary, not a
    # partially counted length, even when a zero bound could otherwise succeed.
    if String.valid?(data) do
      count = length(String.to_charlist(data))
      assert Predicates.check_min_length(data, count) === :ok
      assert Predicates.check_max_length(data, count) === :ok
      assert Predicates.check_min_length(data, count + 1) ===
               {:error, %ErrorContext{contrast: count + 1, input: count}}

      if count > 0 do
        assert Predicates.check_max_length(data, count - 1) ===
                 {:error, %ErrorContext{contrast: count - 1, input: count}}
      end
    else
      expected = {:error, %ErrorContext{contrast: 0, input: data, error_detail: "invalid_utf8"}}
      assert Predicates.check_min_length(data, 0) === expected
      assert Predicates.check_max_length(data, 0) === expected
    end
  end

  defp valid_strings do
    [
      {"", 0},
      {"a", 1},
      {"plain ASCII", 11},
      {"é", 1},
      {"€", 1},
      {"😀", 1},
      {"aé€😀", 4},
      {"e\u0301", 2},
      {"a\u0301\u0327", 3},
      {"\u{1F1FA}\u{1F1F8}", 2},
      {"\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}", 7},
      {"\u{1F469}\u{1F3FD}\u200D\u{1F4BB}", 4}
    ]
  end

  defp bounds(count) do
    [
      {:minLength, 0, :ok},
      {:minLength, count, :ok},
      {:minLength, count + 1, {:error, %ErrorContext{contrast: count + 1, input: count}}},
      {:maxLength, count, :ok},
      {:maxLength, count + 1, :ok}
    ] ++ if count > 0 do
      [
        {:maxLength, count - 1, {:error, %ErrorContext{contrast: count - 1, input: count}}},
        {:maxLength, 0, {:error, %ErrorContext{contrast: 0, input: count}}}
      ]
    else
      []
    end
  end

  defp assert_predicate_bounds(data, cases) do
    for {rule, limit, expected} <- cases do
      assert check_length(rule, data, limit) === expected
    end
  end

  defp assert_compiled_bounds(data, cases) do
    for {rule, limit, expected} <- cases do
      assert {:ok, compiled} = JSONSchex.compile(%{Atom.to_string(rule) => limit})
      result = JSONSchex.validate(compiled, data)

      case expected do
        :ok -> assert result == :ok
        {:error, context} ->
          assert result === {:error, [%Error{rule: rule, path: [], value: data, context: context}]}
      end
    end
  end

  defp check_length(:minLength, data, limit), do: Predicates.check_min_length(data, limit)
  defp check_length(:maxLength, data, limit), do: Predicates.check_max_length(data, limit)

  defp invalid_strings do
    malformed = [
      {:overlong_two, <<0xC0, 0x80>>},
      {:overlong_two_alt, <<0xC1, 0xBF>>},
      {:overlong_three, <<0xE0, 0x9F, 0xBF>>},
      {:overlong_four, <<0xF0, 0x8F, 0xBF, 0xBF>>},
      {:lone_continuation_low, <<0x80>>},
      {:lone_continuation_high, <<0xBF>>},
      {:bad_continuation_two, <<0xC2, 0x41>>},
      {:bad_continuation_three, <<0xE2, 0x82, 0x41>>},
      {:bad_continuation_four, <<0xF0, 0x90, 0x80, 0x41>>},
      {:surrogate_low, <<0xED, 0xA0, 0x80>>},
      {:surrogate_high, <<0xED, 0xBF, 0xBF>>},
      {:too_high, <<0xF4, 0x90, 0x80, 0x80>>},
      {:invalid_leader_f5, <<0xF5, 0x80, 0x80, 0x80>>},
      {:invalid_leader_fe, <<0xFE>>},
      {:invalid_leader_ff, <<0xFF>>},
      {:truncated_two, <<0xC2>>},
      {:truncated_three_one, <<0xE2>>},
      {:truncated_three_two, <<0xE2, 0x82>>},
      {:truncated_four_one, <<0xF0>>},
      {:truncated_four_two, <<0xF0, 0x90>>},
      {:truncated_four_three, <<0xF0, 0x90, 0x80>>}
    ]

    # Preserve the full input in error contexts, including the valid prefix.
    # Prefixes of one to three codepoints also exercise the unrolled loop's tail.
    for prefix <- ["", "a", "aé", "aé€", "aé€😀", String.duplicate("aé€😀", 2048)],
        {label, bytes} <- malformed do
      {label, prefix <> bytes}
    end
  end

  defp invalid_bounds(data) do
    # Exercise early success and failure paths, including minLength = 0.
    [
      {:minLength, 0},
      {:minLength, 1},
      {:minLength, byte_size(data) + 1},
      {:maxLength, byte_size(data) + 1},
      {:maxLength, 0},
      {:maxLength, 1}
    ]
  end

  defp invalid_context(data, limit) do
    %ErrorContext{contrast: limit, input: data, error_detail: "invalid_utf8"}
  end
end

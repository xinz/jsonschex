# Fast-path validation benchmark suite for JSONSchex.
#
# Measures the specialized execution paths introduced alongside the full
# diagnostic validator: short-circuit boolean validation (`JSONSchex.valid?/2`),
# hot-path rule dispatch and annotation-free evaluation, pure binary format
# parsing, compile-time predefined pattern matching, JSON decode + validate
# breakdown, and compile-time generated validators (`defvalidator`).
#
# Run from the repository root:
#   mix run bench/fast_path_comparison.exs
#
# Run a specific section (short_circuit, dispatch, formats, patterns, decode, defvalidator, or all):
#   BENCH=short_circuit mix run bench/fast_path_comparison.exs
#   BENCH=formats BENCH_BATCH_MS=30 mix run bench/fast_path_comparison.exs

defmodule FastPathBench.UnboxedRulesPrototype do
  @moduledoc false
  # Prototype unboxed tuple-instruction compiler & error-collecting validator
  # used as a reference baseline against `%Rule{}` hot-path dispatch.
  alias JSONSchex.Types.{Error, ErrorContext, Rule, Schema}
  alias JSONSchex.Compiler.Predicates

  def lower(%Schema{rules: rules}) do
    Enum.map(rules, &lower_rule/1)
  end

  defp lower_rule(%Rule{name: :type, params: "string"}), do: :type_string
  defp lower_rule(%Rule{name: :type, params: "integer"}), do: :type_integer
  defp lower_rule(%Rule{name: :type, params: "number"}), do: :type_number
  defp lower_rule(%Rule{name: :type, params: "boolean"}), do: :type_boolean
  defp lower_rule(%Rule{name: :type, params: "object"}), do: :type_object
  defp lower_rule(%Rule{name: :type, params: "array"}), do: :type_array
  defp lower_rule(%Rule{name: :type, params: "null"}), do: :type_null
  defp lower_rule(%Rule{name: :type, params: types}), do: {:type, types}
  defp lower_rule(%Rule{name: :minimum, params: min}), do: {:minimum, min}
  defp lower_rule(%Rule{name: :maximum, params: max}), do: {:maximum, max}
  defp lower_rule(%Rule{name: :exclusiveMinimum, params: min}), do: {:exclusive_minimum, min}
  defp lower_rule(%Rule{name: :exclusiveMaximum, params: max}), do: {:exclusive_maximum, max}
  defp lower_rule(%Rule{name: :multipleOf, params: factor}), do: {:multiple_of, factor}
  defp lower_rule(%Rule{name: :minLength, params: min}), do: {:min_length, min}
  defp lower_rule(%Rule{name: :maxLength, params: max}), do: {:max_length, max}
  defp lower_rule(%Rule{name: :required, params: req}), do: {:required, req}

  defp lower_rule(%Rule{name: :properties, params: compiled_props}) do
    {:properties, Enum.map(compiled_props, fn {k, s} -> {k, lower(s)} end)}
  end

  defp lower_rule(%Rule{name: :items, params: %{start_index: 0, schema: sub}}) do
    {:items, lower(sub)}
  end

  def validate(rules, data) do
    case run_rules(rules, data, [], []) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp run_rules([], _data, _path, errors), do: errors

  defp run_rules([rule | rest], data, path, errors) do
    case apply_rule(rule, data, path) do
      :ok ->
        run_rules(rest, data, path, errors)

      {:error, new_errs} when is_list(new_errs) ->
        run_rules(rest, data, path, new_errs ++ errors)

      {:error, ctx} ->
        run_rules(rest, data, path, [%Error{path: path, rule: rule_tag(rule), context: ctx, value: data} | errors])
    end
  end

  defp rule_tag(atom) when is_atom(atom), do: :type
  defp rule_tag({tag, _}), do: tag

  defp apply_rule(:type_string, data, _path) when is_binary(data), do: :ok
  defp apply_rule(:type_string, data, _path), do: Predicates.check_type(data, "string")

  defp apply_rule(:type_integer, data, _path) when is_integer(data), do: :ok
  defp apply_rule(:type_integer, data, _path), do: Predicates.check_type(data, "integer")

  defp apply_rule(:type_number, data, _path) when is_number(data), do: :ok
  defp apply_rule(:type_number, data, _path), do: Predicates.check_type(data, "number")

  defp apply_rule(:type_boolean, data, _path) when is_boolean(data), do: :ok
  defp apply_rule(:type_boolean, data, _path), do: Predicates.check_type(data, "boolean")

  defp apply_rule(:type_object, data, _path) when is_map(data), do: :ok
  defp apply_rule(:type_object, data, _path), do: Predicates.check_type(data, "object")

  defp apply_rule(:type_array, data, _path) when is_list(data), do: :ok
  defp apply_rule(:type_array, data, _path), do: Predicates.check_type(data, "array")

  defp apply_rule(:type_null, nil, _path), do: :ok
  defp apply_rule(:type_null, data, _path), do: Predicates.check_type(data, "null")

  defp apply_rule({:type, types}, data, _path), do: Predicates.check_type(data, types)

  defp apply_rule({:minimum, min}, data, _path) when is_number(data) and data >= min, do: :ok
  defp apply_rule({:minimum, min}, data, _path) when is_number(data), do: {:error, %ErrorContext{contrast: min, input: data}}
  defp apply_rule({:minimum, _}, _data, _path), do: :ok

  defp apply_rule({:maximum, max}, data, _path) when is_number(data) and data <= max, do: :ok
  defp apply_rule({:maximum, max}, data, _path) when is_number(data), do: {:error, %ErrorContext{contrast: max, input: data}}
  defp apply_rule({:maximum, _}, _data, _path), do: :ok

  defp apply_rule({:exclusive_minimum, min}, data, _path) when is_number(data) and data > min, do: :ok
  defp apply_rule({:exclusive_minimum, min}, data, _path) when is_number(data), do: {:error, %ErrorContext{contrast: min, input: data}}
  defp apply_rule({:exclusive_minimum, _}, _data, _path), do: :ok

  defp apply_rule({:exclusive_maximum, max}, data, _path) when is_number(data) and data < max, do: :ok
  defp apply_rule({:exclusive_maximum, max}, data, _path) when is_number(data), do: {:error, %ErrorContext{contrast: max, input: data}}
  defp apply_rule({:exclusive_maximum, _}, _data, _path), do: :ok

  defp apply_rule({:multiple_of, factor}, data, _path), do: Predicates.check_multiple_of(data, factor)
  defp apply_rule({:min_length, min}, data, _path), do: Predicates.check_min_length(data, min)
  defp apply_rule({:max_length, max}, data, _path), do: Predicates.check_max_length(data, max)

  defp apply_rule({:required, required}, data, path) when is_map(data) do
    case missing_keys(required, data, []) do
      [] -> :ok
      missing -> {:error, [%Error{path: path, rule: :required, context: %ErrorContext{contrast: missing}}]}
    end
  end

  defp apply_rule({:required, _}, _data, _path), do: :ok

  defp apply_rule({:properties, props}, data, path) when is_map(data) do
    case reduce_props(props, data, path, []) do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  defp apply_rule({:properties, _}, _data, _path), do: :ok

  defp apply_rule({:items, sub_rules}, data, path) when is_list(data) do
    case reduce_items(data, sub_rules, path, 0, []) do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  defp apply_rule({:items, _}, _data, _path), do: :ok

  defp missing_keys([], _data, acc), do: acc

  defp missing_keys([key | rest], data, acc) do
    if :maps.is_key(key, data), do: missing_keys(rest, data, acc), else: missing_keys(rest, data, [key | acc])
  end

  defp reduce_props([], _data, _path, errs), do: errs

  defp reduce_props([{key, sub_rules} | rest], data, path, errs) do
    case data do
      %{^key => val} ->
        errs = run_rules(sub_rules, val, [key | path], errs)
        reduce_props(rest, data, path, errs)

      _ ->
        reduce_props(rest, data, path, errs)
    end
  end

  defp reduce_items([], _sub_rules, _path, _idx, errs), do: errs

  defp reduce_items([item | rest], sub_rules, path, idx, errs) do
    errs = run_rules(sub_rules, item, [idx | path], errs)
    reduce_items(rest, sub_rules, path, idx + 1, errs)
  end
end

defmodule FastPathBench.LegacyFormatsBaseline do
  @moduledoc false
  # Regex / `DateTime.from_iso8601` / `Date.from_iso8601` format baseline
  # matching pre-optimization behavior, used to measure `JSONSchex.Formats`
  # binary pattern-matching speedups in the same VM.
  alias JSONSchex.Types.ErrorContext

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @dt_re ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})\z/
  @dur_week_re ~r/\AP[0-9]+W\z/
  @dur_main_re ~r/\AP(?:(?:[0-9]+Y(?:[0-9]+M(?:[0-9]+D)?)?|[0-9]+M(?:[0-9]+D)?|[0-9]+D)(?:T(?:[0-9]+H(?:[0-9]+M(?:[0-9]+S)?)?|[0-9]+M(?:[0-9]+S)?|[0-9]+S))?|T(?:[0-9]+H(?:[0-9]+M(?:[0-9]+S)?)?|[0-9]+M(?:[0-9]+S)?|[0-9]+S))\z/
  @bad_pct_re ~r/%(?![0-9A-Fa-f]{2})/

  def validate(format, data) when is_binary(data) do
    if valid?(format, data), do: :ok, else: {:error, %ErrorContext{contrast: format, input: data}}
  end

  def validate(_, _), do: :ok

  defp valid?("uuid", data), do: Regex.match?(@uuid_re, data)

  defp valid?("date", <<y1, y2, y3, y4, ?-, m1, m2, ?-, d1, d2>> = data)
       when y1 in ?0..?9 and y2 in ?0..?9 and y3 in ?0..?9 and y4 in ?0..?9 and
              m1 in ?0..?9 and m2 in ?0..?9 and d1 in ?0..?9 and d2 in ?0..?9 do
    match?({:ok, _}, Date.from_iso8601(data))
  end

  defp valid?("date", _), do: false

  defp valid?("date-time", data) do
    with true <- Regex.match?(@dt_re, data),
         normalized <- String.replace(data, ["t", "z"], fn <<c>> -> <<c - 32>> end),
         {{:ok, _, _}, _} <- {DateTime.from_iso8601(normalized), normalized} do
      true
    else
      {{:error, :invalid_time}, normalized} ->
        maybe_leap_second?(normalized)

      _ ->
        false
    end
  end

  defp valid?("time", data) do
    if String.contains?(data, ",") do
      false
    else
      normalized =
        if String.ends_with?(data, "-00:00"),
          do: String.replace_suffix(data, "-00:00", "+00:00"),
          else: data

      valid?("date-time", "2020-01-01T" <> normalized)
    end
  end

  defp valid?("duration", data) do
    Regex.match?(@dur_week_re, data) or Regex.match?(@dur_main_re, data)
  end

  defp valid?("uri", data) do
    not Regex.match?(@bad_pct_re, data) and
      match?({:ok, %URI{scheme: s}} when s != nil and s != "", URI.new(data))
  end

  defp maybe_leap_second?(dt) do
    with true <- String.contains?(dt, ":60"),
         replaced <- Regex.replace(~r/(T\d{2}:\d{2}):60/, dt, "\\1:59", global: false),
         true <- replaced != dt,
         {:ok, %{hour: 23, minute: 59, second: 59}, _} <- DateTime.from_iso8601(replaced) do
      true
    else
      _ -> false
    end
  end
end

defmodule FastPathBench.StaticValidators do
  @moduledoc false
  # Compile-time generated validators via `use JSONSchex` (`defvalidator` & `~X`).
  use JSONSchex

  defvalidator :validate_user, %{
    "type" => "object",
    "required" => ["id", "name", "age", "active"],
    "properties" => %{
      "id" => %{"type" => "integer", "minimum" => 1},
      "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
      "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
      "active" => %{"type" => "boolean"}
    }
  }

  defvalidator :validate_order, %{
    "type" => "object",
    "required" => ["order_id", "customer", "items"],
    "properties" => %{
      "order_id" => %{"type" => "string", "minLength" => 1},
      "customer" => %{
        "type" => "object",
        "required" => ["id", "name"],
        "properties" => %{
          "id" => %{"type" => "integer", "minimum" => 1},
          "name" => %{"type" => "string", "minLength" => 1}
        }
      },
      "items" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["sku", "qty", "price"],
          "properties" => %{
            "sku" => %{"type" => "string", "minLength" => 1},
            "qty" => %{"type" => "integer", "minimum" => 1},
            "price" => %{"type" => "number", "minimum" => 0}
          }
        }
      }
    }
  }

  defvalidator :validate_user_batch, %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "required" => ["id", "name", "age", "active"],
      "properties" => %{
        "id" => %{"type" => "integer", "minimum" => 1},
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
        "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
        "active" => %{"type" => "boolean"}
      }
    }
  }

  defvalidator :validate_event,
    ~X/%{
      "type" => "object",
      "required" => ["event_id", "slug", "occurred_on", "created_at"],
      "additionalProperties" => false,
      "properties" => %{
        "event_id" => %{"type" => "string", "format" => "uuid"},
        "slug" => %{"type" => "string", "pattern" => "^[a-z0-9_-]+$"},
        "occurred_on" => %{"type" => "string", "format" => "date"},
        "created_at" => %{"type" => "string", "format" => "date-time"},
        "meta" => %{}
      }
    }/f

  defvalidator :validate_empty_object, %{"type" => "object", "additionalProperties" => false}

  defvalidator :validate_one_of_8, %{
    "oneOf" => [
      %{"type" => "integer", "minimum" => 0},
      %{"type" => "integer", "maximum" => 100},
      %{"type" => "integer", "minimum" => 1000},
      %{"type" => "integer", "minimum" => 2000},
      %{"type" => "integer", "minimum" => 3000},
      %{"type" => "integer", "minimum" => 4000},
      %{"type" => "integer", "minimum" => 5000},
      %{"type" => "integer", "minimum" => 6000}
    ]
  }
end

defmodule FastPathBench.Harness do
  @moduledoc false
  # Zero-dependency micro-benchmark harness.
  # Measures median us/op, IPS, speedup ratio, and reductions/op
  # across adaptive batches with explicit GC isolation outside timed intervals.

  @samples 7

  def batch_target_us do
    ms =
      case System.get_env("BENCH_BATCH_MS") do
        nil -> 25
        val -> String.to_integer(val)
      end

    ms * 1_000
  end

  def compare(title, baseline_label, candidate_label, cases) do
    IO.puts("\n--- #{title} ---")

    IO.puts(
      String.pad_trailing("Case", 42) <>
        String.pad_leading("#{baseline_label} (us)", 18) <>
        String.pad_leading("#{candidate_label} (us)", 20) <>
        String.pad_leading("Speedup", 11) <>
        String.pad_leading("Red. Ratio", 12)
    )

    IO.puts(String.duplicate("-", 103))

    for {case_name, baseline_fn, candidate_fn} <- cases do
      base = measure(baseline_fn)
      cand = measure(candidate_fn)
      speedup = if cand.median_us > 0, do: base.median_us / cand.median_us, else: 0.0
      red_ratio = if cand.reductions > 0, do: base.reductions / cand.reductions, else: 0.0

      IO.puts(
        String.pad_trailing(case_name, 42) <>
          String.pad_leading(fmt_us(base.median_us), 18) <>
          String.pad_leading(fmt_us(cand.median_us), 20) <>
          String.pad_leading("#{Float.round(speedup, 2)}x", 11) <>
          String.pad_leading("#{Float.round(red_ratio, 2)}x", 12)
      )
    end
  end

  def compare_multi(title, jobs) do
    IO.puts("\n--- #{title} ---")

    IO.puts(
      String.pad_trailing("Job", 48) <>
        String.pad_leading("Median (us)", 14) <>
        String.pad_leading("IPS", 14) <>
        String.pad_leading("Reductions", 14)
    )

    IO.puts(String.duplicate("-", 90))

    for {label, fun} <- jobs do
      res = measure(fun)
      ips = if res.median_us > 0, do: 1_000_000.0 / res.median_us, else: 0.0

      IO.puts(
        String.pad_trailing(label, 48) <>
          String.pad_leading(fmt_us(res.median_us), 14) <>
          String.pad_leading(fmt_ips(ips), 14) <>
          String.pad_leading("#{res.reductions}", 14)
      )
    end
  end

  def measure(fun) do
    _ = fun.()
    _ = fun.()
    :erlang.garbage_collect()

    {cal_us, _} = :timer.tc(fn -> run_loop(fun, 10) end)
    per_op_us = max(cal_us / 10.0, 0.01)
    count = min(200_000, max(10, trunc(batch_target_us() / per_op_us)))

    samples =
      for _ <- 1..@samples do
        :erlang.garbage_collect()
        {elapsed_us, :ok} = :timer.tc(fn -> run_loop(fun, count) end)
        elapsed_us / count
      end

    sorted = Enum.sort(samples)
    median_us = Enum.at(sorted, div(@samples, 2))
    reductions = measure_reductions(fun)

    %{median_us: median_us, min_us: hd(sorted), max_us: List.last(sorted), reductions: reductions, count: count}
  end

  defp run_loop(_fun, 0), do: :ok

  defp run_loop(fun, n) do
    _ = fun.()
    run_loop(fun, n - 1)
  end

  defp measure_reductions(fun) do
    parent = self()

    spawn_link(fn ->
      _ = fun.()
      :erlang.garbage_collect()
      {:reductions, r1} = :erlang.process_info(self(), :reductions)
      _ = fun.()
      {:reductions, r2} = :erlang.process_info(self(), :reductions)
      send(parent, {:reds, max(r2 - r1, 1)})
    end)

    receive do
      {:reds, reds} -> reds
    end
  end

  defp fmt_us(us) when us >= 100.0, do: :erlang.float_to_binary(us, decimals: 1)
  defp fmt_us(us) when us >= 1.0, do: :erlang.float_to_binary(us, decimals: 2)
  defp fmt_us(us), do: :erlang.float_to_binary(us, decimals: 3)

  defp fmt_ips(ips) when ips >= 1_000_000, do: "#{Float.round(ips / 1_000_000, 2)}M"
  defp fmt_ips(ips) when ips >= 1_000, do: "#{Float.round(ips / 1_000, 2)}K"
  defp fmt_ips(ips), do: "#{Float.round(ips, 1)}"
end

defmodule FastPathBench.Runner do
  @moduledoc false
  alias JSONSchex.Types.ValidationContext
  alias FastPathBench.Harness

  def run(section) do
    IO.puts("==================================================================")
    IO.puts("JSONSchex Fast-Path Validation Benchmarks")
    IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}, schedulers #{System.schedulers_online()}")
    IO.puts("Section: #{section}")
    IO.puts("==================================================================")

    if section in ["all", "short_circuit"], do: run_short_circuit()
    if section in ["all", "dispatch"], do: run_dispatch()
    if section in ["all", "formats"], do: run_formats()
    if section in ["all", "patterns"], do: run_patterns()
    if section in ["all", "decode"], do: run_decode()
    if section in ["all", "defvalidator"], do: run_defvalidator()
  end

  # =========================================================================
  # Short-Circuit Boolean Validation (`valid?/2` vs `validate/2`)
  # =========================================================================
  defp run_short_circuit do
    IO.puts("\n>>> [short_circuit] JSONSchex.validate/2 vs JSONSchex.valid?/2")

    props_20 =
      Map.new(1..20, fn i ->
        {"field_#{i}", %{"type" => "integer", "minimum" => 0, "maximum" => 1000}}
      end)

    {:ok, obj20_schema} = JSONSchex.compile(%{"type" => "object", "properties" => props_20})

    obj20_valid = Map.new(1..20, fn i -> {"field_#{i}", i * 10} end)
    obj20_first_bad = Map.put(obj20_valid, "field_1", "not_an_int")
    obj20_all_bad = Map.new(1..20, fn i -> {"field_#{i}", "bad_#{i}"} end)

    {:ok, arr_schema} =
      JSONSchex.compile(%{"type" => "array", "items" => %{"type" => "integer", "minimum" => 0}})

    arr_first_bad = [-1 | Enum.to_list(2..1000)]
    arr_all_bad = List.duplicate(-1, 1000)

    any_of_branches =
      Enum.map(1..10, fn i ->
        %{
          "type" => "object",
          "required" => ["kind"],
          "properties" => %{"kind" => %{"type" => "integer", "minimum" => i, "maximum" => i}}
        }
      end)

    {:ok, any_of_schema} = JSONSchex.compile(%{"anyOf" => any_of_branches})
    any_of_hit_first = %{"kind" => 1}

    one_of_branches =
      [
        %{"type" => "integer", "minimum" => 0},
        %{"type" => "integer", "maximum" => 100}
      ] ++ Enum.map(3..10, fn i -> %{"type" => "integer", "minimum" => i * 1000} end)

    {:ok, one_of_schema} = JSONSchex.compile(%{"oneOf" => one_of_branches})
    one_of_two_hits = 50

    cases = [
      {"object_20_props / valid", obj20_schema, obj20_valid, true},
      {"object_20_props / 1st_invalid", obj20_schema, obj20_first_bad, false},
      {"object_20_props / all_20_invalid", obj20_schema, obj20_all_bad, false},
      {"array_1000_items / 1st_invalid", arr_schema, arr_first_bad, false},
      {"array_1000_items / all_1000_invalid", arr_schema, arr_all_bad, false},
      {"anyOf_10_branches / 1st_hit", any_of_schema, any_of_hit_first, true},
      {"oneOf_10_branches / 2_hits_early_fail", one_of_schema, one_of_two_hits, false}
    ]

    for {label, schema, data, expected} <- cases do
      actual_prod = JSONSchex.validate(schema, data) == :ok
      actual_ff = JSONSchex.valid?(schema, data)

      unless actual_prod == expected and actual_ff == expected do
        raise "short_circuit verification failed for #{label}: prod=#{actual_prod}, valid?=#{actual_ff}, expected=#{expected}"
      end
    end

    IO.puts("Verified #{length(cases)} short_circuit cases.")

    Harness.compare(
      "Short-Circuit: JSONSchex.validate/2 vs JSONSchex.valid?/2",
      "validate/2",
      "valid?/2",
      Enum.map(cases, fn {label, schema, data, _} ->
        {label, fn -> JSONSchex.validate(schema, data) end,
         fn -> JSONSchex.valid?(schema, data) end}
      end)
    )
  end

  # =========================================================================
  # Hot-Path Rule Dispatch & Annotation-Free Evaluation
  # =========================================================================
  defp run_dispatch do
    IO.puts("\n>>> [dispatch] Hot-Path Dispatch, Rule Unboxing Reference & Annotation-Free Paths")

    {:ok, scalar_schema} =
      JSONSchex.compile(%{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 1000,
        "exclusiveMinimum" => -1,
        "exclusiveMaximum" => 1001
      })

    props_10 =
      Map.new(1..10, fn i ->
        {"p#{i}", %{"type" => "integer", "minimum" => 0, "maximum" => 1000}}
      end)

    {:ok, obj10_schema} =
      JSONSchex.compile(%{
        "type" => "object",
        "required" => Enum.map(1..10, &"p#{&1}"),
        "properties" => props_10
      })

    {:ok, arr500_schema} =
      JSONSchex.compile(%{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "name", "score"],
          "properties" => %{
            "id" => %{"type" => "integer", "minimum" => 1},
            "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 50},
            "score" => %{"type" => "number", "minimum" => 0, "maximum" => 100}
          }
        }
      })

    scalar_lowered = FastPathBench.UnboxedRulesPrototype.lower(scalar_schema)
    obj10_lowered = FastPathBench.UnboxedRulesPrototype.lower(obj10_schema)
    arr500_lowered = FastPathBench.UnboxedRulesPrototype.lower(arr500_schema)

    IO.puts("\nCompiled rule memory footprint (BEAM words via :erts_debug.flat_size/1):")

    for {name, compiled, lowered} <- [
          {"scalar_5_rules", scalar_schema.rules, scalar_lowered},
          {"object_10_props", obj10_schema.rules, obj10_lowered},
          {"array_of_objects", arr500_schema.rules, arr500_lowered}
        ] do
      before_words = :erts_debug.flat_size(compiled)
      after_words = :erts_debug.flat_size(lowered)
      reduction = Float.round((1 - after_words / before_words) * 100, 1)
      IO.puts("  #{name}: %Rule{} = #{before_words} words -> unboxed = #{after_words} words (-#{reduction}%)")
    end

    obj10_data = Map.new(1..10, fn i -> {"p#{i}", i * 10} end)
    arr500_data = Enum.map(1..500, fn i -> %{"id" => i, "name" => "user_#{i}", "score" => rem(i, 100)} end)

    cases = [
      {"scalar_5_rules / valid", scalar_schema, scalar_lowered, 42},
      {"object_10_props / valid", obj10_schema, obj10_lowered, obj10_data},
      {"array_500_objects / valid", arr500_schema, arr500_lowered, arr500_data}
    ]

    for {label, schema, lowered, data} <- cases do
      prod_res = JSONSchex.validate(schema, data)
      unboxed_res = FastPathBench.UnboxedRulesPrototype.validate(lowered, data)

      unless prod_res == :ok and unboxed_res == :ok do
        raise "dispatch verification failed for #{label}: prod=#{inspect(prod_res)}, unboxed=#{inspect(unboxed_res)}"
      end
    end

    IO.puts("Verified #{length(cases)} dispatch unboxing cases.")

    Harness.compare(
      "Dispatch: Production %Rule{} vs Unboxed Tuple Prototype (both error-collecting)",
      "%Rule{}",
      "unboxed",
      Enum.map(cases, fn {label, schema, lowered, data} ->
        {label, fn -> JSONSchex.validate(schema, data) end,
         fn -> FastPathBench.UnboxedRulesPrototype.validate(lowered, data) end}
      end)
    )

    {:ok, addl_true_schema} =
      JSONSchex.compile(%{
        "type" => "object",
        "properties" => %{"p1" => %{"type" => "integer"}},
        "additionalProperties" => true
      })

    obj20_data = Map.new(1..20, fn i -> {"p#{i}", i} end)

    {:ok, draft7_tuple_schema} =
      JSONSchex.compile(
        %{
          "type" => "array",
          "items" => [%{"type" => "integer"}, %{"type" => "string"}],
          "additionalItems" => %{"type" => "integer", "minimum" => 0}
        },
        draft: "draft7"
      )

    tuple_50_data = [1, "ok" | Enum.to_list(1..48)]

    {:ok, prop_names_schema} =
      JSONSchex.compile(%{
        "type" => "object",
        "propertyNames" => %{"type" => "string", "minLength" => 1}
      })

    empty_set = MapSet.new()

    annot_cases = [
      {"object_10_props / valid", obj10_schema, obj10_data},
      {"additionalProperties:true (20 keys)", addl_true_schema, obj20_data},
      {"draft7 tuple items (50 elems)", draft7_tuple_schema, tuple_50_data},
      {"propertyNames (20 keys)", prop_names_schema, obj20_data}
    ]

    for {_label, schema, data} <- annot_cases do
      ctx = ValidationContext.from_root_schema(schema)
      {:ok, _} = JSONSchex.Validator.validate_entry(schema, data, [], ctx, empty_set)
      :ok = JSONSchex.validate(schema, data)
    end

    IO.puts("Verified #{length(annot_cases)} annotation-free cases.")

    Harness.compare(
      "Annotation-Free: MapSet Tracking vs `JSONSchex.validate/2` (`evaluated == nil`)",
      "with MapSet",
      "annot-free",
      Enum.map(annot_cases, fn {label, schema, data} ->
        ctx = ValidationContext.from_root_schema(schema)

        {label,
         fn -> JSONSchex.Validator.validate_entry(schema, data, [], ctx, empty_set) end,
         fn -> JSONSchex.validate(schema, data) end}
      end)
    )
  end

  # =========================================================================
  # Binary Format Parsing vs Legacy Regex/ISO8601 Baseline
  # =========================================================================
  defp run_formats do
    IO.puts("\n>>> [formats] Legacy Regex/ISO8601 Baseline vs Production `JSONSchex.Formats.validate/2`")

    uuid_valid = "550e8400-e29b-41d4-a716-446655440000"
    uuid_invalid = "550e8400-e29b-41d4-a716-44665544000g"

    date_valid = "2024-02-29"
    date_invalid = "2023-02-29"

    dt_valid_utc = "2026-11-19T14:30:45Z"
    dt_valid_offset = "2026-11-19t14:30:45.123456+08:00"
    dt_invalid = "2026-02-30T14:30:45Z"

    time_valid = "14:30:45.123+08:00"
    time_invalid = "25:00:00Z"

    dur_valid = "P1Y2M3DT4H5M6S"
    dur_invalid = "P1Y2D"

    uri_valid = "https://example.com/api/v1/items%20list?tag=a%2Fb"
    uri_invalid = "https://example.com/api/v1/bad%2Gescape"

    verify_cases = [
      {"uuid", uuid_valid, true},
      {"uuid", uuid_invalid, false},
      {"uuid", "short", false},
      {"date", date_valid, true},
      {"date", date_invalid, false},
      {"date", "+2024-02-29", false},
      {"date-time", dt_valid_utc, true},
      {"date-time", dt_valid_offset, true},
      {"date-time", dt_invalid, false},
      {"date-time", "2020-12-31T23:59:60Z", true},
      {"date-time", "2020-12-31T22:59:60Z", false},
      {"time", time_valid, true},
      {"time", time_invalid, false},
      {"time", "23:59:60Z", true},
      {"duration", dur_valid, true},
      {"duration", "P3W", true},
      {"duration", "PT30M", true},
      {"duration", dur_invalid, false},
      {"duration", "P", false},
      {"uri", uri_valid, true},
      {"uri", uri_invalid, false}
    ]

    for {format, val, exp} <- verify_cases do
      legacy = FastPathBench.LegacyFormatsBaseline.validate(format, val) == :ok
      prod = JSONSchex.Formats.validate(format, val) == :ok
      prod_bool = JSONSchex.Formats.valid?(format, val)

      unless legacy == exp and prod == exp and prod_bool == exp do
        raise "formats #{format} mismatch for #{inspect(val)}: legacy=#{legacy} prod=#{prod} valid?=#{prod_bool}"
      end
    end

    IO.puts("Verified #{length(verify_cases)} format cases.")

    Harness.compare(
      "Formats: Legacy Regex/ISO8601 vs Production Binary `Formats.validate/2`",
      "Legacy",
      "Binary",
      [
        {"uuid / valid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("uuid", uuid_valid) end,
         fn -> JSONSchex.Formats.validate("uuid", uuid_valid) end},
        {"uuid / invalid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("uuid", uuid_invalid) end,
         fn -> JSONSchex.Formats.validate("uuid", uuid_invalid) end},
        {"date / valid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("date", date_valid) end,
         fn -> JSONSchex.Formats.validate("date", date_valid) end},
        {"date / invalid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("date", date_invalid) end,
         fn -> JSONSchex.Formats.validate("date", date_invalid) end},
        {"date-time / valid_utc",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("date-time", dt_valid_utc) end,
         fn -> JSONSchex.Formats.validate("date-time", dt_valid_utc) end},
        {"date-time / valid_offset_frac",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("date-time", dt_valid_offset) end,
         fn -> JSONSchex.Formats.validate("date-time", dt_valid_offset) end},
        {"date-time / invalid_date",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("date-time", dt_invalid) end,
         fn -> JSONSchex.Formats.validate("date-time", dt_invalid) end},
        {"time / valid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("time", time_valid) end,
         fn -> JSONSchex.Formats.validate("time", time_valid) end},
        {"time / invalid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("time", time_invalid) end,
         fn -> JSONSchex.Formats.validate("time", time_invalid) end},
        {"duration / valid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("duration", dur_valid) end,
         fn -> JSONSchex.Formats.validate("duration", dur_valid) end},
        {"duration / invalid",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("duration", dur_invalid) end,
         fn -> JSONSchex.Formats.validate("duration", dur_invalid) end},
        {"uri / valid_percent_enc",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("uri", uri_valid) end,
         fn -> JSONSchex.Formats.validate("uri", uri_valid) end},
        {"uri / invalid_percent_enc",
         fn -> FastPathBench.LegacyFormatsBaseline.validate("uri", uri_invalid) end,
         fn -> JSONSchex.Formats.validate("uri", uri_invalid) end}
      ]
    )
  end

  # =========================================================================
  # Compile-Time Predefined Pattern Matching vs :re.run Regex
  # =========================================================================
  defp run_patterns do
    IO.puts("\n>>> [patterns] Production PredefinedPattern Matcher vs :re.run Regex")

    pattern_cases = [
      {"exact / valid (^active$)", "^active$", "active", true},
      {"exact / invalid (^active$)", "^active$", "inactive", false},
      {"prefix / valid (^x-api-)", "^x-api-", "x-api-request-id", true},
      {"prefix / invalid (^x-api-)", "^x-api-", "content-type", false},
      {"suffix / valid (\\.json$)", "\\.json$", "openapi_schema.json", true},
      {"digits / valid (^\\d{4,8}$)", "^\\d{4,8}$", "20261119", true},
      {"digits / invalid (^\\d{4,8}$)", "^\\d{4,8}$", "2026-11-19", false},
      {"hex / valid (^[0-9a-fA-F]{32}$)", "^[0-9a-fA-F]{32}$", "550e8400e29b41d4a716446655440000", true},
      {"slug / valid (^[a-z0-9_-]+$)", "^[a-z0-9_-]+$", "my-service_endpoint-v2", true},
      {"slug / invalid (^[a-z0-9_-]+$)", "^[a-z0-9_-]+$", "my-service/invalid!", false}
    ]

    prepared =
      Enum.map(pattern_cases, fn {label, source, subject, expected} ->
        {:ok, regex} = JSONSchex.Compiler.ECMARegex.compile(source)
        {:ok, compiled} = JSONSchex.compile(%{"pattern" => source})
        [rule] = compiled.rules
        regex_only_schema = %{compiled | rules: [%{rule | params: %{regex: regex}}]}

        prod_ok = JSONSchex.validate(compiled, subject) == :ok
        prod_bool = JSONSchex.valid?(compiled, subject)
        regex_ok = JSONSchex.validate(regex_only_schema, subject) == :ok

        unless prod_ok == expected and prod_bool == expected and regex_ok == expected do
          raise "patterns verification failed for #{label}"
        end

        {label, regex_only_schema, compiled, subject}
      end)

    IO.puts("Verified #{length(prepared)} pattern cases.")

    Harness.compare(
      "Patterns: Regex-only JSONSchex.validate vs PredefinedPattern Fast-Path",
      "Regex-only",
      "Fast-Path",
      Enum.map(prepared, fn {label, regex_schema, fast_schema, subject} ->
        {label, fn -> JSONSchex.validate(regex_schema, subject) end,
         fn -> JSONSchex.validate(fast_schema, subject) end}
      end)
    )
  end

  # =========================================================================
  # End-to-End JSON Decode + Validation Breakdown
  # =========================================================================
  defp run_decode do
    IO.puts("\n>>> [decode] JSON Decode (Elixir JSON vs OTP :json) + Validation Breakdown")

    {:ok, schema} =
      JSONSchex.compile(%{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "name", "email", "age", "active"],
          "properties" => %{
            "id" => %{"type" => "integer", "minimum" => 1},
            "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
            "email" => %{"type" => "string", "minLength" => 3},
            "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
            "active" => %{"type" => "boolean"}
          }
        }
      })

    payload_list =
      Enum.map(1..200, fn i ->
        %{
          "id" => i,
          "name" => "User #{i}",
          "email" => "user#{i}@example.com",
          "age" => 20 + rem(i, 50),
          "active" => rem(i, 2) == 0
        }
      end)

    json_binary = JSON.encode!(payload_list)
    IO.puts("Payload size: #{byte_size(json_binary)} bytes (200 user objects)")

    decoded_elixir = JSON.decode!(json_binary)
    decoded_otp = :json.decode(json_binary)
    unless decoded_elixir == decoded_otp, do: raise("decode mismatch")
    unless JSONSchex.validate(schema, decoded_elixir) == :ok, do: raise("decode validation mismatch")

    Harness.compare_multi(
      "Decode vs Validate Breakdown (200 user objects)",
      [
        {"1. Elixir JSON.decode!/1 only", fn -> JSON.decode!(json_binary) end},
        {"2. OTP :json.decode/1 only", fn -> :json.decode(json_binary) end},
        {"3. JSONSchex.validate/2 only (pre-decoded)", fn -> JSONSchex.validate(schema, decoded_elixir) end},
        {"4. E2E: Elixir JSON.decode! + validate", fn -> JSONSchex.validate(schema, JSON.decode!(json_binary)) end},
        {"5. E2E: OTP :json.decode + validate", fn -> JSONSchex.validate(schema, :json.decode(json_binary)) end}
      ]
    )
  end

  # =========================================================================
  # Compile-Time Static Validators (`defvalidator`) vs Runtime Interpreter
  # =========================================================================
  defp run_defvalidator do
    IO.puts("\n>>> [defvalidator] Compile-Time Generated Validators vs Runtime Interpreter")

    user_raw_schema = %{
      "type" => "object",
      "required" => ["id", "name", "age", "active"],
      "properties" => %{
        "id" => %{"type" => "integer", "minimum" => 1},
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
        "age" => %{"type" => "integer", "minimum" => 0, "maximum" => 150},
        "active" => %{"type" => "boolean"}
      }
    }

    order_raw_schema = %{
      "type" => "object",
      "required" => ["order_id", "customer", "items"],
      "properties" => %{
        "order_id" => %{"type" => "string", "minLength" => 1},
        "customer" => %{
          "type" => "object",
          "required" => ["id", "name"],
          "properties" => %{
            "id" => %{"type" => "integer", "minimum" => 1},
            "name" => %{"type" => "string", "minLength" => 1}
          }
        },
        "items" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["sku", "qty", "price"],
            "properties" => %{
              "sku" => %{"type" => "string", "minLength" => 1},
              "qty" => %{"type" => "integer", "minimum" => 1},
              "price" => %{"type" => "number", "minimum" => 0}
            }
          }
        }
      }
    }

    event_raw_schema = %{
      "type" => "object",
      "required" => ["event_id", "slug", "occurred_on", "created_at"],
      "additionalProperties" => false,
      "properties" => %{
        "event_id" => %{"type" => "string", "format" => "uuid"},
        "slug" => %{"type" => "string", "pattern" => "^[a-z0-9_-]+$"},
        "occurred_on" => %{"type" => "string", "format" => "date"},
        "created_at" => %{"type" => "string", "format" => "date-time"},
        "meta" => %{}
      }
    }

    one_of_8_raw_schema = %{
      "oneOf" => [
        %{"type" => "integer", "minimum" => 0},
        %{"type" => "integer", "maximum" => 100},
        %{"type" => "integer", "minimum" => 1000},
        %{"type" => "integer", "minimum" => 2000},
        %{"type" => "integer", "minimum" => 3000},
        %{"type" => "integer", "minimum" => 4000},
        %{"type" => "integer", "minimum" => 5000},
        %{"type" => "integer", "minimum" => 6000}
      ]
    }

    {:ok, user_schema} = JSONSchex.compile(user_raw_schema)
    {:ok, order_schema} = JSONSchex.compile(order_raw_schema)
    {:ok, batch_schema} = JSONSchex.compile(%{"type" => "array", "items" => user_raw_schema})
    {:ok, event_schema} = JSONSchex.compile(event_raw_schema, format_assertion: true)
    {:ok, empty_obj_schema} = JSONSchex.compile(%{"type" => "object", "additionalProperties" => false})
    {:ok, one_of_8_schema} = JSONSchex.compile(one_of_8_raw_schema)

    valid_user = %{"id" => 42, "name" => "Alice", "age" => 30, "active" => true}
    invalid_user = %{"id" => 42, "name" => "Alice", "age" => -5, "active" => true}

    valid_order = %{
      "order_id" => "ORD-2026-001",
      "customer" => %{"id" => 7, "name" => "Bob"},
      "items" => Enum.map(1..10, fn i -> %{"sku" => "SKU-#{i}", "qty" => i, "price" => i * 9.99} end)
    }

    valid_batch =
      Enum.map(1..100, fn i ->
        %{"id" => i, "name" => "User #{i}", "age" => 20 + rem(i, 50), "active" => rem(i, 2) == 0}
      end)

    valid_event = %{
      "event_id" => "550e8400-e29b-41d4-a716-446655440000",
      "slug" => "user-signup_v2",
      "occurred_on" => "2026-11-23",
      "created_at" => "2026-11-23T14:30:45.123Z",
      "meta" => %{"source" => "web"}
    }

    for {label, schema, data, static_ok, static_bool, expected} <- [
          {"valid_user", user_schema, valid_user, &FastPathBench.StaticValidators.validate_user/1,
           &FastPathBench.StaticValidators.validate_user?/1, true},
          {"invalid_user", user_schema, invalid_user, &FastPathBench.StaticValidators.validate_user/1,
           &FastPathBench.StaticValidators.validate_user?/1, false},
          {"valid_order", order_schema, valid_order, &FastPathBench.StaticValidators.validate_order/1,
           &FastPathBench.StaticValidators.validate_order?/1, true},
          {"valid_batch", batch_schema, valid_batch, &FastPathBench.StaticValidators.validate_user_batch/1,
           &FastPathBench.StaticValidators.validate_user_batch?/1, true},
          {"valid_event", event_schema, valid_event, &FastPathBench.StaticValidators.validate_event/1,
           &FastPathBench.StaticValidators.validate_event?/1, true},
          {"empty_object", empty_obj_schema, %{}, &FastPathBench.StaticValidators.validate_empty_object/1,
           &FastPathBench.StaticValidators.validate_empty_object?/1, true},
          {"oneOf_8_early_fail", one_of_8_schema, 50, &FastPathBench.StaticValidators.validate_one_of_8/1,
           &FastPathBench.StaticValidators.validate_one_of_8?/1, false}
        ] do
      interp_ok = JSONSchex.validate(schema, data) == :ok
      interp_bool = JSONSchex.valid?(schema, data)
      s_ok = static_ok.(data) == :ok
      s_bool = static_bool.(data)

      unless interp_ok == expected and interp_bool == expected and s_ok == expected and s_bool == expected do
        raise "defvalidator #{label} mismatch"
      end
    end

    IO.puts("Verified all defvalidator cases.")

    Harness.compare(
      "defvalidator: Runtime JSONSchex.validate/2 vs Generated validate_*/1",
      "validate/2",
      "defvalidator",
      [
        {"user / valid (:ok)", fn -> JSONSchex.validate(user_schema, valid_user) end,
         fn -> FastPathBench.StaticValidators.validate_user(valid_user) end},
        {"nested_order_10_items / valid (:ok)", fn -> JSONSchex.validate(order_schema, valid_order) end,
         fn -> FastPathBench.StaticValidators.validate_order(valid_order) end},
        {"batch_100_users / valid (:ok)", fn -> JSONSchex.validate(batch_schema, valid_batch) end,
         fn -> FastPathBench.StaticValidators.validate_user_batch(valid_batch) end},
        {"event (pattern+uuid+date+dt+meta) / valid", fn -> JSONSchex.validate(event_schema, valid_event) end,
         fn -> FastPathBench.StaticValidators.validate_event(valid_event) end},
        {"empty_object (addlProps:false) / valid", fn -> JSONSchex.validate(empty_obj_schema, %{}) end,
         fn -> FastPathBench.StaticValidators.validate_empty_object(%{}) end}
      ]
    )

    Harness.compare(
      "defvalidator: Runtime JSONSchex.valid?/2 vs Generated validate_*?/1",
      "valid?/2",
      "defvalidator?",
      [
        {"user / valid", fn -> JSONSchex.valid?(user_schema, valid_user) end,
         fn -> FastPathBench.StaticValidators.validate_user?(valid_user) end},
        {"user / invalid", fn -> JSONSchex.valid?(user_schema, invalid_user) end,
         fn -> FastPathBench.StaticValidators.validate_user?(invalid_user) end},
        {"nested_order_10_items / valid", fn -> JSONSchex.valid?(order_schema, valid_order) end,
         fn -> FastPathBench.StaticValidators.validate_order?(valid_order) end},
        {"event (pattern+uuid+date+dt+meta) / valid", fn -> JSONSchex.valid?(event_schema, valid_event) end,
         fn -> FastPathBench.StaticValidators.validate_event?(valid_event) end},
        {"oneOf_8_branches / 2_hits_early_fail", fn -> JSONSchex.valid?(one_of_8_schema, 50) end,
         fn -> FastPathBench.StaticValidators.validate_one_of_8?(50) end}
      ]
    )
  end
end

section = System.get_env("BENCH", "all") |> String.downcase()
FastPathBench.Runner.run(section)

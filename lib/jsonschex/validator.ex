defmodule JSONSchex.Validator do
  @moduledoc """
  Executes compiled `Schema` rules against data, accumulating errors and tracking
  evaluated keys for `unevaluatedProperties`/`unevaluatedItems`.

  During validation, a context tuple is threaded through each rule:

      {path, evaluated_keys, validation_context}

  - `path` — Reversed list of JSON Pointer segments (e.g., `["email", 0, "users"]`)
  - `evaluated_keys` — `MapSet` of property names or array indices validated so far
  - `validation_context` — `ValidationContext` struct referencing the root schema

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})
      iex> JSONSchex.Validator.validate(schema, %{"name" => "Alice"})
      :ok

  """

  alias JSONSchex.Types.{Schema, ValidationContext, Error}
  alias JSONSchex.Validator.Reference


  @empty_mapset MapSet.new()

  @doc """
  Validates data against a compiled schema.

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "integer", "minimum" => 0})
      iex> JSONSchex.Validator.validate(schema, 10)
      :ok

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "integer", "minimum" => 0})
      iex> {:error, errors} = JSONSchex.Validator.validate(schema, -5)
      iex> Enum.any?(errors, fn e -> e.rule == :minimum end)
      true

  """
  @spec validate(Schema.t(), term()) :: :ok | {:error, list(Error.t())}
  def validate(%Schema{source_id: id} = root_schema, data) do
    initial_stack = if id != nil, do: [id], else: []

    ctx = %ValidationContext{
      root_schema: root_schema,
      scope_stack: initial_stack,
      source_id: id,
      raw: root_schema.raw
    }

    case validate_entry(root_schema, data, [], ctx) do
      {:ok, _annotations} ->
        :ok
      {:error, errors} ->
        flat_errors = List.flatten(errors)

        formatted_errors =
          Enum.map(flat_errors, fn
            {path, rule, context} when is_map(context) ->
              %Error{path: path, rule: rule, context: context, value: data}
            %Error{} = e ->
              e
          end)

        {:error, formatted_errors}
    end
  end

  @doc """
  Recursive validation engine called by compiled rule closures.

  Executes all rules in the schema sequentially, accumulating errors and evaluated keys.

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "string"})
      iex> ctx = %JSONSchex.Types.ValidationContext{root_schema: schema, scope_stack: [], source_id: nil, raw: nil}
      iex> JSONSchex.Validator.validate_entry(schema, "hello", [], ctx)
      {:ok, MapSet.new()}

  """
  @spec validate_entry(Schema.t(), term(), list(), ValidationContext.t(), term()) ::
          {:ok, MapSet.t()} | {:error, list(Error.t()) | String.t()}
  def validate_entry(schema, data, path, context, initial_evaluted \\ @empty_mapset)

  def validate_entry(%Schema{rules: [], source_id: nil}, _data, _path, _context, evaluated) do
    {:ok, evaluated}
  end

  def validate_entry(%Schema{rules: [rule], source_id: nil}, data, path, context, evaluated) do
    case rule.validator.(data, {path, evaluated, context}) do
      :ok ->
        {:ok, evaluated}

      {:ok, new_eval_keys} ->
        {:ok, MapSet.union(evaluated, new_eval_keys)}

      {:error, new_errs} when is_list(new_errs) ->
        {:error, new_errs}

      {:error, error_context} when is_map(error_context) ->
        {:error, [%Error{path: path, rule: rule.name, context: error_context, value: data}]}
    end
  end

  def validate_entry(%Schema{rules: [rule1, rule2], source_id: nil}, data, path, context, evaluated) do
    ctx = {path, evaluated, context}

    {eval1, ctx1, err1} =
      case rule1.validator.(data, ctx) do
        :ok -> {evaluated, ctx, nil}
        {:ok, new_keys} ->
          new_eval = MapSet.union(evaluated, new_keys)
          {new_eval, {path, new_eval, context}, nil}
        {:error, e} ->
          {evaluated, ctx, to_error_entry(e, path, rule1.name, data)}
      end

    {eval2, err2} =
      case rule2.validator.(data, ctx1) do
        :ok -> {eval1, nil}
        {:ok, new_keys} -> {MapSet.union(eval1, new_keys), nil}
        {:error, e} -> {eval1, to_error_entry(e, path, rule2.name, data)}
      end

    case {err1, err2} do
      {nil, nil} -> {:ok, eval2}
      {e, nil} -> {:error, e}
      {nil, e} -> {:error, e}
      {e1, e2} -> {:error, [e2 | [e1]]}
    end
  end

  def validate_entry(%Schema{rules: rules, source_id: nil}, data, path, context, initial_evaluated) do
    ctx = {path, initial_evaluated, context}
    run_rules(rules, data, path, context, initial_evaluated, ctx, [])
  end

  def validate_entry(%Schema{rules: rules} = current_schema, data, path, %ValidationContext{} = root_context, initial_evaluated) do
    current_context = update_context_if_needed(current_schema, root_context)

    initial_ctx = {path, initial_evaluated, current_context}
    run_rules(rules, data, path, current_context, initial_evaluated, initial_ctx, [])
  end

  defp to_error_entry(errs, _path, _rule_name, _data) when is_list(errs), do: errs
  defp to_error_entry(err_ctx, path, rule_name, data) when is_map(err_ctx),
    do: [%Error{path: path, rule: rule_name, context: err_ctx, value: data}]

  defp run_rules([], _data, _path, _context, evaluated, _ctx, []) do
    {:ok, evaluated}
  end

  defp run_rules([], _data, _path, _context, _evaluated, _ctx, errors) do
    {:error, errors}
  end

  defp run_rules([rule | rest], data, path, context, evaluated, ctx, errors) do
    case rule.validator.(data, ctx) do
      :ok ->
        run_rules(rest, data, path, context, evaluated, ctx, errors)

      {:ok, new_eval_keys} ->
        cond do
          MapSet.size(new_eval_keys) == 0 ->
            run_rules(rest, data, path, context, evaluated, ctx, errors)

          MapSet.size(evaluated) == 0 ->
            new_ctx = {path, new_eval_keys, context}
            run_rules(rest, data, path, context, new_eval_keys, new_ctx, errors)

          true ->
            new_evaluated = MapSet.union(evaluated, new_eval_keys)
            new_ctx = {path, new_evaluated, context}
            run_rules(rest, data, path, context, new_evaluated, new_ctx, errors)
        end

      {:error, new_errs} when is_list(new_errs) ->
        run_rules(rest, data, path, context, evaluated, ctx, [new_errs | errors])

      {:error, err_context} when is_map(err_context) ->
        e = %Error{path: path, rule: rule.name, context: err_context, value: data}
        run_rules(rest, data, path, context, evaluated, ctx, [e | errors])
    end
  end

  defp update_context_if_needed(%{source_id: nil}, %ValidationContext{} = root_context) do
    root_context
  end
  defp update_context_if_needed(%{source_id: id}, %ValidationContext{source_id: id} = root_context) do
    root_context
  end

  defp update_context_if_needed(%{source_id: source_id} = current_schema, %ValidationContext{} = root_context) do
    %{root_context |
      source_id: source_id,
      raw: current_schema.raw,
      scope_stack: [source_id | root_context.scope_stack]}
  end

  @doc """
  Resolves `$dynamicRef` via dynamic scope lookup.

  See `JSONSchex.Validator.Reference.validate_dynamic_ref/3`.
  """
  def validate_dynamic_ref(data, ref_string, context) do
    Reference.validate_dynamic_ref(data, ref_string, context)
  end

  @doc """
  Resolves a static `$ref` using a pre-resolved URI for fast lookup, falling back
  to full resolution via `JSONSchex.Validator.Reference.validate_ref/3`.
  """
  def validate_ref(data, ref_string, resolved_uri, {path, evaluated, validation_context} = context) do
    case Map.get(validation_context.root_schema.defs, resolved_uri) do
      %Schema{} = schema ->
        validate_entry(schema, data, path, validation_context, evaluated)

      nil ->
        Reference.validate_ref(data, ref_string, context)
    end
  end

end

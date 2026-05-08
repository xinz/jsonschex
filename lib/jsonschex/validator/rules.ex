defmodule JSONSchex.Validator.Rules do
  @moduledoc """
  Dispatches compiled `JSONSchex.Types.Rule` structs to their runtime
  validation implementations.

  This keeps `JSONSchex.Validator` focused on orchestration while centralizing
  rule-specific execution in one place.
  """

  alias JSONSchex.Compiler.Predicates
  alias JSONSchex.Types.{Error, ErrorContext, Rule, Schema}
  alias JSONSchex.Validator
  alias JSONSchex.Validator.{Keywords, Reference}

  @type validation_context :: {list(), MapSet.t(), term()}
  @type result :: :ok | {:ok, MapSet.t()} | {:error, list(Error.t()) | ErrorContext.t()}

  @doc """
  Applies a compiled rule to data in the given validation context.
  """
  @spec apply(Rule.t(), term(), validation_context()) :: result()
  def apply(%Rule{name: :boolean_schema}, data, {path, _, _}) do
    {:error,
     [
       %Error{
         path: path,
         rule: :boolean_schema,
         context: %ErrorContext{contrast: false, input: data}
       }
     ]}
  end

  def apply(
        %Rule{name: :ref, params: %{ref: ref_string, resolved_uri: resolved_uri}},
        data,
        ctx
      ) do
    validate_ref(data, ref_string, resolved_uri, ctx)
  end

  def apply(
        %Rule{
          name: :contentSchema,
          params: %{schema: compiled_sub, media_type: media_type, encoding: encoding}
        },
        data,
        {path, evaluated, root}
      ) do
    Keywords.validate_content_schema(
      data,
      compiled_sub,
      media_type,
      encoding,
      path,
      root,
      evaluated
    )
  end

  def apply(%Rule{name: :format, params: format}, data, _ctx) do
    JSONSchex.Formats.validate(format, data)
  end

  def apply(%Rule{name: :dynamicRef, params: ref}, data, ctx) do
    Reference.validate_dynamic_ref(data, ref, ctx)
  end

  def apply(%Rule{name: :type, params: types}, data, _ctx),
    do: Predicates.check_type(data, types)

  def apply(%Rule{name: :minimum, params: minimum}, data, _ctx),
    do: Predicates.check_minimum(data, minimum)

  def apply(%Rule{name: :maximum, params: maximum}, data, _ctx),
    do: Predicates.check_maximum(data, maximum)

  def apply(%Rule{name: :exclusiveMinimum, params: minimum}, data, _ctx),
    do: Predicates.check_exclusive_minimum(data, minimum)

  def apply(%Rule{name: :exclusiveMaximum, params: maximum}, data, _ctx),
    do: Predicates.check_exclusive_maximum(data, maximum)

  def apply(%Rule{name: :multipleOf, params: multiple_of}, data, _ctx),
    do: Predicates.check_multiple_of(data, multiple_of)

  def apply(%Rule{name: :minLength, params: min_length}, data, _ctx),
    do: Predicates.check_min_length(data, min_length)

  def apply(%Rule{name: :maxLength, params: max_length}, data, _ctx),
    do: Predicates.check_max_length(data, max_length)

  def apply(%Rule{name: :pattern, params: %{regex: regex}}, data, _ctx) do
    Predicates.check_pattern(data, regex)
  end

  def apply(%Rule{name: :minProperties, params: min_properties}, data, _ctx),
    do: Predicates.check_min_properties(data, min_properties)

  def apply(%Rule{name: :maxProperties, params: max_properties}, data, _ctx),
    do: Predicates.check_max_properties(data, max_properties)

  def apply(%Rule{name: :minItems, params: min_items}, data, _ctx),
    do: Predicates.check_min_items(data, min_items)

  def apply(%Rule{name: :maxItems, params: max_items}, data, _ctx),
    do: Predicates.check_max_items(data, max_items)

  def apply(%Rule{name: :uniqueItems, params: unique_items}, data, _ctx),
    do: Predicates.check_unique_items(data, unique_items)

  def apply(%Rule{name: :enum, params: values}, data, _ctx),
    do: Predicates.check_enum(data, values)

  def apply(%Rule{name: :const, params: value}, data, _ctx),
    do: Predicates.check_const(data, value)

  def apply(%Rule{name: :required, params: required}, data, {path, _, _}) do
    if is_map(data) do
      if Enum.all?(required, &Map.has_key?(data, &1)) do
        :ok
      else
        missing = Enum.reject(required, &Map.has_key?(data, &1))
        {:error, [%Error{path: path, rule: :required, context: %ErrorContext{contrast: missing}}]}
      end
    else
      :ok
    end
  end

  def apply(
        %Rule{name: :properties, params: compiled_props},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_properties_map(data, compiled_props, path, root)
  end

  def apply(
        %Rule{name: :patternProperties, params: compiled_patterns},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_pattern_properties(data, compiled_patterns, path, root)
  end

  def apply(
        %Rule{
          name: :additionalProperties,
          params: %{known_props: known_props, patterns: patterns, always_valid?: true}
        },
        data,
        {_path, _evaluated, _root}
      ) do
    Keywords.collect_additional_keys(data, known_props, patterns)
  end

  def apply(
        %Rule{
          name: :additionalProperties,
          params: %{schema: compiled_sub, known_props: known_props, patterns: patterns}
        },
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_additional_properties(data, compiled_sub, known_props, patterns, path, root)
  end

  def apply(%Rule{name: :dependencies, params: :ok}, _data, _ctx), do: :ok

  def apply(%Rule{name: :dependencies}, data, _ctx) when not is_map(data), do: :ok

  def apply(
        %Rule{name: :dependencies, params: %{mode: :required, required: required_deps}},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_dependent_required(data, required_deps, path, root)
  end

  def apply(
        %Rule{name: :dependencies, params: %{mode: :schemas, schemas: compiled_schemas}},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_dependent_schemas(data, compiled_schemas, path, root)
  end

  def apply(
        %Rule{
          name: :dependencies,
          params: %{mode: :both, required: required_deps, schemas: compiled_schemas}
        },
        data,
        {path, _evaluated, root}
      ) do
    required_result = Keywords.validate_dependent_required(data, required_deps, path, root)
    schema_result = Keywords.validate_dependent_schemas(data, compiled_schemas, path, root)
    merge_dependency_results(required_result, schema_result)
  end

  def apply(%Rule{name: :dependentRequired, params: deps}, data, {path, _evaluated, root}) do
    Keywords.validate_dependent_required(data, deps, path, root)
  end

  def apply(
        %Rule{name: :dependentSchemas, params: compiled_deps},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_dependent_schemas(data, compiled_deps, path, root)
  end

  def apply(
        %Rule{name: :propertyNames, params: compiled_sub},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_property_names(data, compiled_sub, path, root)
  end

  def apply(
        %Rule{name: :prefixItems, params: compiled_schemas},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_prefix_items(data, compiled_schemas, path, root)
  end

  def apply(
        %Rule{name: :items, params: %{start_index: start_index, schema: compiled_sub}},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_items_array(data, compiled_sub, start_index, path, root)
  end

  def apply(
        %Rule{name: :contains, params: %{schema: compiled_sub, min: min, max: max}},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_contains(data, compiled_sub, min, max, path, root)
  end

  def apply(%Rule{name: :allOf, params: compiled_schemas}, data, {path, evaluated, root}) do
    Keywords.validate_allOf(data, compiled_schemas, path, root, evaluated)
  end

  def apply(%Rule{name: :anyOf, params: compiled_schemas}, data, {path, evaluated, root}) do
    Keywords.validate_anyOf(data, compiled_schemas, path, root, evaluated)
  end

  def apply(%Rule{name: :oneOf, params: compiled_schemas}, data, {path, evaluated, root}) do
    Keywords.validate_oneOf(data, compiled_schemas, path, root, evaluated)
  end

  def apply(%Rule{name: :not, params: compiled_sub}, data, {path, evaluated, root}) do
    Keywords.validate_not(data, compiled_sub, path, root, evaluated)
  end

  def apply(
        %Rule{name: :if, params: %{if: compiled_if, then: compiled_then, else: compiled_else}},
        data,
        {path, evaluated, root}
      ) do
    Keywords.validate_if(data, compiled_if, compiled_then, compiled_else, path, root, evaluated)
  end

  def apply(
        %Rule{
          name: :unevaluatedProperties,
          params: %{schema: sub_schema, false_schema?: false_schema?}
        },
        data,
        {path, evaluated_keys, root}
      ) do
    case Keywords.validate_unevaluated_props(data, sub_schema, path, evaluated_keys, root) do
      {:ok, _} = new_evaluated ->
        new_evaluated

      :ok ->
        :ok

      {:error, errors} when false_schema? ->
        rewritten_errors =
          Enum.map(errors, fn e ->
            %{e | rule: :unevaluatedProperties, context: %ErrorContext{contrast: "not_allowed"}}
          end)

        {:error, rewritten_errors}

      error ->
        error
    end
  end

  def apply(
        %Rule{
          name: :unevaluatedItems,
          params: %{schema: sub_schema, false_schema?: false_schema?}
        },
        data,
        {path, evaluated_indices, root}
      ) do
    case Keywords.validate_unevaluated_items(data, sub_schema, path, evaluated_indices, root) do
      {:ok, _} = new_evaluated ->
        new_evaluated

      :ok ->
        :ok

      {:error, errors} when false_schema? ->
        rewritten =
          Enum.map(errors, fn e ->
            %{e | rule: :unevaluatedItems, context: %ErrorContext{contrast: "not_allowed"}}
          end)

        {:error, rewritten}

      {:error, errors} ->
        {:error, errors}
    end
  end

  def apply(%Rule{name: name}, _data, _ctx) do
    raise ArgumentError, "unsupported compiled rule: #{inspect(name)}"
  end

  defp merge_dependency_results(:ok, :ok), do: :ok
  defp merge_dependency_results(:ok, {:ok, evaluated}), do: {:ok, evaluated}
  defp merge_dependency_results(:ok, {:error, errs}), do: {:error, errs}
  defp merge_dependency_results({:error, req_errs}, :ok), do: {:error, req_errs}
  defp merge_dependency_results({:error, req_errs}, {:ok, _}), do: {:error, req_errs}

  defp merge_dependency_results({:error, req_errs}, {:error, schema_errs}) do
    {:error, schema_errs ++ req_errs}
  end

  defp validate_ref(
         data,
         ref_string,
         resolved_uri,
         {path, evaluated, validation_context} = context
       ) do
    case Map.get(validation_context.root_schema.defs, resolved_uri) do
      %Schema{} = schema ->
        Validator.validate_entry(schema, data, path, validation_context, evaluated)

      _ ->
        Reference.validate_ref(data, ref_string, context)
    end
  end
end

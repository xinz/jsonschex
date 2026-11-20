defmodule JSONSchex.Validator.Rules do
  @moduledoc """
  Dispatches compiled `JSONSchex.Types.Rule` structs to their runtime
  validation implementations.

  This keeps `JSONSchex.Validator` focused on orchestration while centralizing
  rule-specific execution in one place.
  """

  alias JSONSchex.Compiler.Predicates
  alias JSONSchex.Types.{Error, ErrorContext, Rule}
  alias JSONSchex.Validator.{Keywords, Reference}
  alias JSONSchex.Validator.Keywords.AnnotationFree

  @type validation_context :: {list(), MapSet.t() | nil, term()}
  @type result :: :ok | {:ok, MapSet.t()} | {:error, list(Error.t()) | ErrorContext.t()}

  @doc """
  Applies a compiled rule to data in the given validation context.
  """
  @spec apply(Rule.t(), term(), validation_context()) :: result()
  def apply(%Rule{name: name, params: params}, data, ctx) do
    apply_rule(name, params, data, ctx)
  end

  @doc false
  @spec apply_rule(atom(), term(), term(), validation_context()) :: result()
  def apply_rule(:boolean_schema, _params, data, {path, _, _}) do
    {:error,
     [
       %Error{
         path: path,
         rule: :boolean_schema,
         context: %ErrorContext{contrast: false, input: data}
       }
     ]}
  end

  def apply_rule(:ref, %{ref: ref_string, resolved_uri: resolved_uri}, data, ctx) do
    Reference.validate_ref(data, ref_string, resolved_uri, ctx)
  end

  def apply_rule(
        :contentSchema,
        %{schema: compiled_sub, media_type: media_type, encoding: encoding},
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

  def apply_rule(:format, format, data, _ctx) do
    JSONSchex.Formats.validate(format, data)
  end

  def apply_rule(:dynamicRef, ref, data, ctx) do
    Reference.validate_dynamic_ref(data, ref, ctx)
  end

  # Inlined hot scalar checks (atom-keyed jump table, avoiding extra remote calls on pass)
  def apply_rule(:type, "string", data, _ctx) when is_binary(data), do: :ok
  def apply_rule(:type, "integer", data, _ctx) when is_integer(data), do: :ok
  def apply_rule(:type, "number", data, _ctx) when is_number(data), do: :ok
  def apply_rule(:type, "boolean", data, _ctx) when is_boolean(data), do: :ok
  def apply_rule(:type, "object", data, _ctx) when is_map(data), do: :ok
  def apply_rule(:type, "array", data, _ctx) when is_list(data), do: :ok
  def apply_rule(:type, "null", nil, _ctx), do: :ok
  def apply_rule(:type, types, data, _ctx), do: Predicates.check_type(data, types)

  def apply_rule(:minimum, minimum, data, _ctx) when is_number(data) and data >= minimum, do: :ok
  def apply_rule(:minimum, minimum, data, _ctx) when is_number(data),
    do: {:error, %ErrorContext{contrast: minimum, input: data}}
  def apply_rule(:minimum, _minimum, _data, _ctx), do: :ok

  def apply_rule(:maximum, maximum, data, _ctx) when is_number(data) and data <= maximum, do: :ok
  def apply_rule(:maximum, maximum, data, _ctx) when is_number(data),
    do: {:error, %ErrorContext{contrast: maximum, input: data}}
  def apply_rule(:maximum, _maximum, _data, _ctx), do: :ok

  def apply_rule(:exclusiveMinimum, minimum, data, _ctx) when is_number(data) and data > minimum,
    do: :ok
  def apply_rule(:exclusiveMinimum, minimum, data, _ctx) when is_number(data),
    do: {:error, %ErrorContext{contrast: minimum, input: data}}
  def apply_rule(:exclusiveMinimum, _minimum, _data, _ctx), do: :ok

  def apply_rule(:exclusiveMaximum, maximum, data, _ctx) when is_number(data) and data < maximum,
    do: :ok
  def apply_rule(:exclusiveMaximum, maximum, data, _ctx) when is_number(data),
    do: {:error, %ErrorContext{contrast: maximum, input: data}}
  def apply_rule(:exclusiveMaximum, _maximum, _data, _ctx), do: :ok

  def apply_rule(:multipleOf, multiple_of, data, _ctx),
    do: Predicates.check_multiple_of(data, multiple_of)

  def apply_rule(:minLength, min_length, data, _ctx),
    do: Predicates.check_min_length(data, min_length)

  def apply_rule(:maxLength, max_length, data, _ctx),
    do: Predicates.check_max_length(data, max_length)

  def apply_rule(:pattern, %{regex: regex, matcher: matcher}, data, {path, _, _}) do
    Predicates.check_pattern(data, regex, matcher, path)
  end

  def apply_rule(:pattern, %{regex: regex}, data, {path, _, _}) do
    Predicates.check_pattern(data, regex, path)
  end

  def apply_rule(:minProperties, min_properties, data, _ctx) when is_map(data) do
    size = map_size(data)
    if size >= min_properties, do: :ok, else: {:error, %ErrorContext{contrast: min_properties, input: size}}
  end
  def apply_rule(:minProperties, _min_properties, _data, _ctx), do: :ok

  def apply_rule(:maxProperties, max_properties, data, _ctx) when is_map(data) do
    size = map_size(data)
    if size <= max_properties, do: :ok, else: {:error, %ErrorContext{contrast: max_properties, input: size}}
  end
  def apply_rule(:maxProperties, _max_properties, _data, _ctx), do: :ok

  def apply_rule(:minItems, min_items, data, _ctx) when is_list(data) do
    len = length(data)
    if len >= min_items, do: :ok, else: {:error, %ErrorContext{contrast: min_items, input: len}}
  end
  def apply_rule(:minItems, _min_items, _data, _ctx), do: :ok

  def apply_rule(:maxItems, max_items, data, _ctx) when is_list(data) do
    len = length(data)
    if len <= max_items, do: :ok, else: {:error, %ErrorContext{contrast: max_items, input: len}}
  end
  def apply_rule(:maxItems, _max_items, _data, _ctx), do: :ok

  def apply_rule(:uniqueItems, unique_items, data, _ctx),
    do: Predicates.check_unique_items(data, unique_items)

  def apply_rule(:enum, values, data, _ctx),
    do: Predicates.check_enum(data, values)

  def apply_rule(:const, value, data, _ctx) do
    if data == value, do: :ok, else: {:error, %ErrorContext{contrast: value, input: data}}
  end

  def apply_rule(:required, required, data, {path, _, _}) do
    if is_map(data) do
      case collect_missing_required(required, data, []) do
        [] -> :ok
        missing -> {:error, [%Error{path: path, rule: :required, context: %ErrorContext{contrast: Enum.reverse(missing)}}]}
      end
    else
      :ok
    end
  end

  def apply_rule(:properties, compiled_props, data, {path, nil, root}) do
    AnnotationFree.validate_properties_map(data, compiled_props, path, root)
  end

  def apply_rule(:properties, compiled_props, data, {path, _evaluated, root}) do
    Keywords.validate_properties_map(data, compiled_props, path, root)
  end

  def apply_rule(:patternProperties, compiled_patterns, data, {path, nil, root}) do
    AnnotationFree.validate_pattern_properties(data, compiled_patterns, path, root)
  end

  def apply_rule(:patternProperties, compiled_patterns, data, {path, _evaluated, root}) do
    Keywords.validate_pattern_properties(data, compiled_patterns, path, root)
  end

  def apply_rule(
        :additionalProperties,
        %{known_props: known_props, patterns: patterns, always_valid?: true},
        data,
        {path, _evaluated, _root}
      ) do
    Keywords.collect_additional_keys(data, known_props, patterns, path)
  end

  def apply_rule(
        :additionalProperties,
        %{schema: compiled_sub, known_props: known_props, patterns: patterns},
        data,
        {path, nil, root}
      ) do
    AnnotationFree.validate_additional_properties(data, compiled_sub, known_props, patterns, path, root)
  end

  def apply_rule(
        :additionalProperties,
        %{schema: compiled_sub, known_props: known_props, patterns: patterns},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_additional_properties(data, compiled_sub, known_props, patterns, path, root)
  end

  def apply_rule(:dependencies, :ok, _data, _ctx), do: :ok
  def apply_rule(:dependencies, _params, data, _ctx) when not is_map(data), do: :ok

  def apply_rule(:dependencies, %{mode: :required, required: required_deps}, data, {path, _evaluated, root}) do
    Keywords.validate_dependent_required(data, required_deps, path, root)
  end

  def apply_rule(:dependencies, %{mode: :schemas, schemas: compiled_schemas}, data, {path, nil, root}) do
    AnnotationFree.validate_dependent_schemas(data, compiled_schemas, path, root)
  end

  def apply_rule(:dependencies, %{mode: :schemas, schemas: compiled_schemas}, data, {path, _evaluated, root}) do
    Keywords.validate_dependent_schemas(data, compiled_schemas, path, root)
  end

  def apply_rule(
        :dependencies,
        %{mode: :both, required: required_deps, schemas: compiled_schemas},
        data,
        {path, evaluated, root}
      ) do
    required_result = Keywords.validate_dependent_required(data, required_deps, path, root)

    schema_result =
      if evaluated == nil do
        AnnotationFree.validate_dependent_schemas(data, compiled_schemas, path, root)
      else
        Keywords.validate_dependent_schemas(data, compiled_schemas, path, root)
      end

    merge_dependency_results(required_result, schema_result)
  end

  def apply_rule(:dependentRequired, deps, data, {path, _evaluated, root}) do
    Keywords.validate_dependent_required(data, deps, path, root)
  end

  def apply_rule(:dependentSchemas, compiled_deps, data, {path, nil, root}) do
    AnnotationFree.validate_dependent_schemas(data, compiled_deps, path, root)
  end

  def apply_rule(:dependentSchemas, compiled_deps, data, {path, _evaluated, root}) do
    Keywords.validate_dependent_schemas(data, compiled_deps, path, root)
  end

  def apply_rule(:propertyNames, compiled_sub, data, {path, _evaluated, root}) do
    Keywords.validate_property_names(data, compiled_sub, path, root)
  end

  def apply_rule(:prefixItems, compiled_schemas, data, {path, nil, root}) do
    AnnotationFree.validate_prefix_items(data, compiled_schemas, path, root)
  end

  def apply_rule(:prefixItems, compiled_schemas, data, {path, _evaluated, root}) do
    Keywords.validate_prefix_items(data, compiled_schemas, path, root)
  end

  def apply_rule(
        :items,
        %{draft: "draft7", schemas: schemas, additional: additional},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_tuple_items(data, schemas, additional, path, root)
  end

  def apply_rule(
        :items,
        %{start_index: start_index, schema: compiled_sub},
        data,
        {path, nil, root}
      ) do
    AnnotationFree.validate_items_array(data, compiled_sub, start_index, path, root)
  end

  def apply_rule(
        :items,
        %{start_index: start_index, schema: compiled_sub},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_items_array(data, compiled_sub, start_index, path, root)
  end

  def apply_rule(
        :contains,
        %{schema: compiled_sub, min: min, max: max},
        data,
        {path, nil, root}
      ) do
    AnnotationFree.validate_contains(data, compiled_sub, min, max, path, root)
  end

  def apply_rule(
        :contains,
        %{schema: compiled_sub, min: min, max: max},
        data,
        {path, _evaluated, root}
      ) do
    Keywords.validate_contains(data, compiled_sub, min, max, path, root)
  end

  def apply_rule(:allOf, compiled_schemas, data, {path, nil, root}) do
    AnnotationFree.validate_all_of(data, compiled_schemas, path, root)
  end

  def apply_rule(:allOf, compiled_schemas, data, {path, evaluated, root}) do
    Keywords.validate_allOf(data, compiled_schemas, path, root, evaluated)
  end

  def apply_rule(:anyOf, compiled_schemas, data, {path, nil, root}) do
    AnnotationFree.validate_any_of(data, compiled_schemas, path, root)
  end

  def apply_rule(:anyOf, compiled_schemas, data, {path, evaluated, root}) do
    Keywords.validate_anyOf(data, compiled_schemas, path, root, evaluated)
  end

  def apply_rule(:oneOf, compiled_schemas, data, {path, evaluated, root}) do
    Keywords.validate_oneOf(data, compiled_schemas, path, root, evaluated)
  end

  def apply_rule(:not, compiled_sub, data, {path, evaluated, root}) do
    Keywords.validate_not(data, compiled_sub, path, root, evaluated)
  end

  def apply_rule(
        :if,
        %{if: compiled_if, then: compiled_then, else: compiled_else},
        data,
        {path, nil, root}
      ) do
    AnnotationFree.validate_if(data, compiled_if, compiled_then, compiled_else, path, root)
  end

  def apply_rule(
        :if,
        %{if: compiled_if, then: compiled_then, else: compiled_else},
        data,
        {path, evaluated, root}
      ) do
    Keywords.validate_if(data, compiled_if, compiled_then, compiled_else, path, root, evaluated)
  end

  def apply_rule(
        :unevaluatedProperties,
        %{schema: sub_schema, false_schema?: false_schema?},
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

  def apply_rule(
        :unevaluatedItems,
        %{schema: sub_schema, false_schema?: false_schema?},
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

  def apply_rule(
        name,
        %{media_type: media_type, encoding: encoding},
        data,
        {path, _evaluated, _root}
      )
      when name in [:contentEncoding, :contentMediaType] do
    Keywords.validate_content_assertion(data, media_type, encoding, path)
  end

  def apply_rule(name, _params, _data, _ctx) do
    raise ArgumentError, "unsupported compiled rule: #{inspect(name)}"
  end

  @doc false
  @spec apply(Rule.t(), term(), validation_context(), map()) :: {result(), map()}
  def apply(
        %Rule{name: :patternProperties, params: compiled_patterns},
        data,
        {path, _evaluated, root},
        cache
      ) do
    Keywords.validate_pattern_properties(
      data,
      compiled_patterns,
      path,
      root,
      cache
    )
  end

  def apply(
        %Rule{
          name: :additionalProperties,
          params: %{known_props: known_props, patterns: patterns, always_valid?: true}
        },
        data,
        {path, _evaluated, _root},
        cache
      ) do
    Keywords.collect_additional_keys_with_match_cache(data, known_props, patterns, cache, path)
  end

  def apply(
        %Rule{
          name: :additionalProperties,
          params: %{schema: compiled_sub, known_props: known_props, patterns: patterns}
        },
        data,
        {path, _evaluated, root},
        cache
      ) do
    Keywords.validate_additional_properties_with_match_cache(
      data,
      compiled_sub,
      known_props,
      patterns,
      path,
      root,
      cache
    )
  end

  def apply(rule, data, ctx, cache), do: {__MODULE__.apply(rule, data, ctx), cache}

  defp collect_missing_required([], _data, missing), do: missing

  defp collect_missing_required([key | rest], data, missing) when is_map_key(data, key) do
    collect_missing_required(rest, data, missing)
  end
  defp collect_missing_required([key | rest], data, missing) do
    collect_missing_required(rest, data, [key | missing])
  end

  defp merge_dependency_results(:ok, :ok), do: :ok
  defp merge_dependency_results(:ok, {:ok, evaluated}), do: {:ok, evaluated}
  defp merge_dependency_results(:ok, {:error, errs}), do: {:error, errs}
  defp merge_dependency_results({:error, req_errs}, :ok), do: {:error, req_errs}
  defp merge_dependency_results({:error, req_errs}, {:ok, _}), do: {:error, req_errs}

  defp merge_dependency_results({:error, req_errs}, {:error, schema_errs}) do
    {:error, schema_errs ++ req_errs}
  end
end

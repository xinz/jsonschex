defmodule JSONSchex.Validator.ShortCircuit do
  @moduledoc false
  # Short-circuiting boolean validation engine.
  #
  # Avoids allocating `%Error{}`, `%ErrorContext{}`, `path` lists, and `MapSet`
  # evaluated-key annotations whenever a schema node does not depend on
  # `unevaluatedProperties` or `unevaluatedItems`. Nodes with
  # `needs_evaluated_annotations: true` delegate to `JSONSchex.Validator.validate_entry/4`
  # to preserve full Draft 2020-12 annotation semantics.

  alias JSONSchex.Compiler.Predicates
  alias JSONSchex.Compiler.Predicates.MultipleOf
  alias JSONSchex.Formats
  alias JSONSchex.Guards
  alias JSONSchex.PredefinedPattern
  alias JSONSchex.Types.{Error, Rule, Schema, ValidationContext}
  alias JSONSchex.Validator
  alias JSONSchex.Validator.{Keywords, Pattern, Reference}

  @spec valid?(Schema.t(), term()) :: boolean()
  def valid?(%Schema{} = root_schema, data) do
    valid_entry?(root_schema, data, root_schema)
  catch
    {Pattern, %Error{}} ->
      false
  end

  # Internal entry point for generated predicates too. Only the outer predicate
  # catches pattern errors: a nested `not` must not invert them into a match.
  @spec valid_entry?(Schema.t(), term(), ValidationContext.t() | Schema.t()) :: boolean()
  def valid_entry?(%Schema{needs_evaluated_annotations: true} = schema, data, ctx) do
    match?({:ok, _}, Validator.validate_entry(schema, data, [], ensure_context(ctx)))
  end

  def valid_entry?(%Schema{rules: []}, _data, _ctx), do: true

  def valid_entry?(%Schema{rules: rules, source_id: nil}, data, ctx) do
    run_rules(rules, data, ctx)
  end

  def valid_entry?(%Schema{rules: rules} = schema, data, %Schema{} = root_schema)
       when schema === root_schema do
    run_rules(rules, data, root_schema)
  end

  def valid_entry?(%Schema{rules: rules} = schema, data, ctx) do
    child_ctx = Reference.context_for_child(schema, ensure_context(ctx))
    run_rules(rules, data, child_ctx)
  end

  defp ensure_context(%ValidationContext{} = ctx), do: ctx

  defp ensure_context(%Schema{} = root_schema), do: ValidationContext.from_root_schema(root_schema)

  defp run_rules([], _data, _ctx), do: true

  defp run_rules([%Rule{name: name, params: params} | rest], data, ctx) do
    if check_rule(name, params, data, ctx) do
      run_rules(rest, data, ctx)
    else
      false
    end
  end

  # --- Scalar & Primitive Rules (atom-keyed jump table) ---

  defp check_rule(:boolean_schema, _params, _data, _ctx), do: false

  for type <- Guards.json_types() do
    defp check_rule(:type, unquote(type), data, _ctx),
      do: unquote(Guards.type_check_ast(type, Macro.var(:data, nil)))
  end

  defp check_rule(:type, types, data, _ctx) when is_list(types),
    do: Predicates.valid_type?(data, types)

  defp check_rule(:type, _type, _data, _ctx), do: false

  defp check_rule(:minimum, min, data, _ctx),
    do: not is_number(data) or data >= min

  defp check_rule(:maximum, max, data, _ctx),
    do: not is_number(data) or data <= max

  defp check_rule(:exclusiveMinimum, min, data, _ctx),
    do: not is_number(data) or data > min

  defp check_rule(:exclusiveMaximum, max, data, _ctx),
    do: not is_number(data) or data < max

  defp check_rule(:multipleOf, 0, _data, _ctx), do: false
  defp check_rule(:multipleOf, +0.0, _data, _ctx), do: false

  defp check_rule(:multipleOf, factor, data, _ctx) when is_number(data),
    do: MultipleOf.valid?(data, factor)

  defp check_rule(:multipleOf, _factor, _data, _ctx), do: true

  defp check_rule(:minLength, min, data, _ctx) when is_binary(data),
    do: Predicates.valid_min_length?(data, min)

  defp check_rule(:minLength, _min, _data, _ctx), do: true

  defp check_rule(:maxLength, max, data, _ctx) when is_binary(data),
    do: Predicates.valid_max_length?(data, max)

  defp check_rule(:maxLength, _max, _data, _ctx), do: true

  defp check_rule(:pattern, %{matcher: matcher}, data, _ctx)
       when is_binary(data),
       do: PredefinedPattern.match?(matcher, data)

  defp check_rule(:pattern, %{regex: regex}, data, _ctx)
       when is_binary(data),
       do: Pattern.match?(regex, data, [])

  defp check_rule(:pattern, _params, _data, _ctx), do: true

  defp check_rule(:format, format, data, _ctx),
    do: Formats.valid?(format, data)

  defp check_rule(:minProperties, min, data, _ctx),
    do: not is_map(data) or map_size(data) >= min

  defp check_rule(:maxProperties, max, data, _ctx),
    do: not is_map(data) or map_size(data) <= max

  defp check_rule(:minItems, min, data, _ctx),
    do: not is_list(data) or length(data) >= min

  defp check_rule(:maxItems, max, data, _ctx),
    do: not is_list(data) or length(data) <= max

  defp check_rule(:uniqueItems, true, data, _ctx),
    do: Predicates.valid_unique_items?(data)

  defp check_rule(:uniqueItems, _unique, _data, _ctx), do: true

  defp check_rule(:enum, values, data, _ctx),
    do: Enum.any?(values, &(&1 == data))

  defp check_rule(:const, value, data, _ctx),
    do: data == value

  # --- Object Rules ---

  defp check_rule(:required, required, data, _ctx) when is_map(data),
    do: all_keys_present?(required, data)

  defp check_rule(:required, _required, _data, _ctx), do: true

  defp check_rule(:properties, compiled_props, data, ctx)
       when is_map(data),
       do: check_properties(compiled_props, data, ctx)

  defp check_rule(:properties, _compiled_props, _data, _ctx), do: true

  defp check_rule(:patternProperties, compiled_patterns, data, ctx)
       when is_map(data),
       do: check_pattern_properties(compiled_patterns, Map.to_list(data), ctx)

  defp check_rule(:patternProperties, _compiled_patterns, _data, _ctx), do: true

  defp check_rule(:additionalProperties, %{always_valid?: true}, _data, _ctx),
    do: true

  defp check_rule(
         :additionalProperties,
         %{schema: compiled_sub, known_props: known_props, patterns: patterns},
         data,
         ctx
       )
       when is_map(data) do
    check_additional_properties(Map.to_list(data), compiled_sub, known_props, patterns, ctx)
  end

  defp check_rule(:additionalProperties, _params, _data, _ctx), do: true

  defp check_rule(:propertyNames, compiled_sub, data, ctx)
       when is_map(data),
       do: check_property_names(Map.keys(data), compiled_sub, ctx)

  defp check_rule(:propertyNames, _compiled_sub, _data, _ctx), do: true

  defp check_rule(:dependentRequired, deps, data, _ctx)
       when is_map(data),
       do: check_dependent_required(Map.to_list(deps), data)

  defp check_rule(:dependentRequired, _deps, _data, _ctx), do: true

  defp check_rule(:dependentSchemas, compiled_deps, data, ctx)
       when is_map(data),
       do: check_dependent_schemas(Map.to_list(compiled_deps), data, ctx)

  defp check_rule(:dependentSchemas, _compiled_deps, _data, _ctx), do: true

  defp check_rule(:dependencies, :ok, _data, _ctx), do: true
  defp check_rule(:dependencies, _params, data, _ctx) when not is_map(data), do: true

  defp check_rule(:dependencies, %{mode: :required, required: req}, data, _ctx),
    do: check_dependent_required(Map.to_list(req), data)

  defp check_rule(:dependencies, %{mode: :schemas, schemas: schemas}, data, ctx),
    do: check_dependent_schemas(Map.to_list(schemas), data, ctx)

  defp check_rule(
         :dependencies,
         %{mode: :both, required: req, schemas: schemas},
         data,
         ctx
       ) do
    check_dependent_required(Map.to_list(req), data) and
      check_dependent_schemas(Map.to_list(schemas), data, ctx)
  end

  # --- Array Rules ---

  defp check_rule(:prefixItems, compiled_schemas, data, ctx)
       when is_list(data),
       do: check_prefix_items(compiled_schemas, data, ctx)

  defp check_rule(:prefixItems, _compiled_schemas, _data, _ctx), do: true

  defp check_rule(
         :items,
         %{draft: "draft7", schemas: schemas, additional: additional},
         data,
         ctx
       )
       when is_list(data) do
    check_tuple_items(schemas, data, additional, ctx)
  end

  defp check_rule(
         :items,
         %{start_index: start_index, schema: compiled_sub},
         data,
         ctx
       )
       when is_list(data) do
    items = if start_index == 0, do: data, else: Enum.drop(data, start_index)
    check_items_list(items, compiled_sub, ctx)
  end

  defp check_rule(:items, _params, _data, _ctx), do: true

  defp check_rule(
         :contains,
         %{schema: compiled_sub, min: min, max: max},
         data,
         ctx
       )
       when is_list(data) do
    check_contains(data, compiled_sub, min, max, 0, ctx)
  end

  defp check_rule(:contains, _params, _data, _ctx), do: true

  # --- Combinators & Conditionals ---

  defp check_rule(:allOf, schemas, data, ctx),
    do: check_all_of(schemas, data, ctx)

  defp check_rule(:anyOf, schemas, data, ctx),
    do: check_any_of(schemas, data, ctx)

  defp check_rule(:oneOf, schemas, data, ctx),
    do: check_one_of(schemas, data, 0, ctx)

  defp check_rule(:not, compiled_sub, data, ctx),
    do: not valid_entry?(compiled_sub, data, ctx)

  defp check_rule(
         :if,
         %{if: compiled_if, then: compiled_then, else: compiled_else},
         data,
         ctx
       ) do
    if valid_entry?(compiled_if, data, ctx) do
      if compiled_then != nil, do: valid_entry?(compiled_then, data, ctx), else: true
    else
      if compiled_else != nil, do: valid_entry?(compiled_else, data, ctx), else: true
    end
  end

  # --- References & Content ---

  defp check_rule(
         :ref,
         %{ref: ref_string, resolved_uri: resolved_uri},
         data,
         ctx
       ) do
    validation_ctx = ensure_context(ctx)

    case Reference.resolve_compiled_ref(resolved_uri, validation_ctx) do
      {:ok, target_schema, target_ctx} ->
        valid_entry?(target_schema, data, target_ctx)

      nil ->
        match?(
          {:ok, _},
          Reference.validate_ref(data, ref_string, resolved_uri, {[], nil, validation_ctx})
        )
    end
  end

  defp check_rule(:dynamicRef, ref, data, ctx) do
    validation_ctx = ensure_context(ctx)
    match?({:ok, _}, Reference.validate_dynamic_ref(data, ref, {[], nil, validation_ctx}))
  end

  defp check_rule(
         :contentSchema,
         %{schema: compiled_sub, media_type: media_type, encoding: encoding},
         data,
         ctx
       ) do
    Keywords.validate_content_schema(
      data,
      compiled_sub,
      media_type,
      encoding,
      [],
      ensure_context(ctx)
    ) == :ok
  end

  defp check_rule(
         name,
         %{media_type: media_type, encoding: encoding},
         data,
         _ctx
       )
       when name in [:contentEncoding, :contentMediaType] do
    Keywords.validate_content_assertion(data, media_type, encoding, []) == :ok
  end

  defp check_rule(name, _params, _data, _ctx) do
    raise ArgumentError, "unsupported compiled rule: #{inspect(name)}"
  end

  # --- Helper Loops ---

  defp all_keys_present?([], _data), do: true

  defp all_keys_present?([key | rest], data) when is_map_key(data, key) do
    all_keys_present?(rest, data)
  end
  defp all_keys_present?(_keys, _data), do: false

  defp check_properties([], _data, _ctx), do: true

  defp check_properties([{key, sub_schema} | rest], data, ctx) do
    case data do
      %{^key => val} ->
        if valid_entry?(sub_schema, val, ctx), do: check_properties(rest, data, ctx), else: false

      _ ->
        check_properties(rest, data, ctx)
    end
  end

  defp check_pattern_properties([], _data_list, _ctx), do: true

  defp check_pattern_properties([{regex, sub_schema} | rest], data_list, ctx) do
    if check_pattern_entries(data_list, regex, sub_schema, ctx) do
      check_pattern_properties(rest, data_list, ctx)
    else
      false
    end
  end

  defp check_pattern_entries([], _regex, _sub_schema, _ctx), do: true

  defp check_pattern_entries([{key, val} | rest], regex, sub_schema, ctx) do
    if Pattern.match?(regex, key, [key]) do
      if valid_entry?(sub_schema, val, ctx) do
        check_pattern_entries(rest, regex, sub_schema, ctx)
      else
        false
      end
    else
      check_pattern_entries(rest, regex, sub_schema, ctx)
    end
  end

  defp check_additional_properties([], _sub, _known, _patterns, _ctx), do: true

  defp check_additional_properties([{key, val} | rest], sub, known, patterns, ctx) do
    cond do
      MapSet.member?(known, key) ->
        check_additional_properties(rest, sub, known, patterns, ctx)

      patterns != [] and Enum.any?(patterns, &Pattern.match?(&1, key, [key])) ->
        check_additional_properties(rest, sub, known, patterns, ctx)

      valid_entry?(sub, val, ctx) ->
        check_additional_properties(rest, sub, known, patterns, ctx)

      true ->
        false
    end
  end

  defp check_property_names([], _sub, _ctx), do: true

  defp check_property_names([key | rest], sub, ctx) do
    if valid_entry?(sub, key, ctx), do: check_property_names(rest, sub, ctx), else: false
  end

  defp check_dependent_required([], _data), do: true

  defp check_dependent_required([{prop, req_keys} | rest], data) do
    if :maps.is_key(prop, data) do
      if all_keys_present?(req_keys, data),
        do: check_dependent_required(rest, data),
        else: false
    else
      check_dependent_required(rest, data)
    end
  end

  defp check_dependent_schemas([], _data, _ctx), do: true

  defp check_dependent_schemas([{prop, sub_schema} | rest], data, ctx) do
    if :maps.is_key(prop, data) do
      if valid_entry?(sub_schema, data, ctx),
        do: check_dependent_schemas(rest, data, ctx),
        else: false
    else
      check_dependent_schemas(rest, data, ctx)
    end
  end

  defp check_prefix_items([], _data, _ctx), do: true
  defp check_prefix_items(_schemas, [], _ctx), do: true

  defp check_prefix_items([schema | rest_schemas], [item | rest_data], ctx) do
    if valid_entry?(schema, item, ctx),
      do: check_prefix_items(rest_schemas, rest_data, ctx),
      else: false
  end

  defp check_tuple_items([], [], _additional, _ctx), do: true

  defp check_tuple_items([], rest_data, additional, ctx),
    do: check_items_list(rest_data, additional, ctx)

  defp check_tuple_items(_schemas, [], _additional, _ctx), do: true

  defp check_tuple_items([schema | rest_schemas], [item | rest_data], additional, ctx) do
    if valid_entry?(schema, item, ctx),
      do: check_tuple_items(rest_schemas, rest_data, additional, ctx),
      else: false
  end

  defp check_items_list([], _sub_schema, _ctx), do: true

  defp check_items_list([item | rest], sub_schema, ctx) do
    if valid_entry?(sub_schema, item, ctx),
      do: check_items_list(rest, sub_schema, ctx),
      else: false
  end

  defp check_contains(_data, _sub, _min, max, count, _ctx) when max != nil and count > max,
    do: false

  defp check_contains(_data, _sub, min, nil, count, _ctx) when count >= min,
    do: true

  defp check_contains([], _sub, min, max, count, _ctx),
    do: count >= min and (max == nil or count <= max)

  defp check_contains([item | rest], sub, min, max, count, ctx) do
    next_count = if valid_entry?(sub, item, ctx), do: count + 1, else: count
    check_contains(rest, sub, min, max, next_count, ctx)
  end

  defp check_all_of([], _data, _ctx), do: true

  defp check_all_of([schema | rest], data, ctx) do
    if valid_entry?(schema, data, ctx), do: check_all_of(rest, data, ctx), else: false
  end

  defp check_any_of([], _data, _ctx), do: false

  defp check_any_of([schema | rest], data, ctx) do
    if valid_entry?(schema, data, ctx), do: true, else: check_any_of(rest, data, ctx)
  end

  defp check_one_of([], _data, count, _ctx), do: count == 1

  defp check_one_of([schema | rest], data, count, ctx) do
    if valid_entry?(schema, data, ctx) do
      if count == 1, do: false, else: check_one_of(rest, data, 1, ctx)
    else
      check_one_of(rest, data, count, ctx)
    end
  end
end

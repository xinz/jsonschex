defmodule JSONSchex.Compiler do
  @moduledoc """
  Transforms raw JSON Schema maps into executable `Schema` structs.

  Compilation has two phases:

  1. **Node compilation** — Recursively converts keywords into `Rule` structs
     (serializable rule descriptors), resolves vocabularies, and compiles `$defs`.
  2. **Scope scanning** — Discovers all `$id` and anchor definitions across the
     schema tree and registers them by absolute URI for reference resolution.

  Standard rules execute first; **finalizer** rules (`unevaluatedProperties`,
  `unevaluatedItems`) run last so they can see which keys were already evaluated.

  ## Examples

      iex> {:ok, schema} = JSONSchex.Compiler.compile(%{"type" => "string"})
      iex> length(schema.rules)
      1

  """
  alias JSONSchex.Types.{Schema, Rule, Error, ErrorContext}
  alias JSONSchex.ScopeScanner
  alias JSONSchex.Draft202012.{Vocabulary, Dialect}
  alias JSONSchex.URIUtil
  alias JSONSchex.Compiler.Fragment
  alias JSONSchex.Compiler.Fragment.Bundle

  import JSONSchex.Types,
    only: [
      is_non_neg_int_keywords?: 1,
      is_numeric_keywords?: 1,
      is_valid_types?: 1
    ]

  @default_vocabs_list Dialect.supported_vocabularies()

  defp vocab_supported?(supported, uri) when is_list(supported), do: uri in supported

  @doc """
  Compiles a raw JSON Schema into an executable `Schema` struct.

  See `JSONSchex.compile/2` for options and usage.
  """
  @spec compile(map() | boolean()) :: {:ok, Schema.t()} | {:error, String.t()}
  def compile(raw_schema, opts \\ [])

  def compile(raw_schema, opts) when is_map(raw_schema) do
    compile_root_schema(raw_schema, raw_schema, Keyword.get(opts, :base_uri), opts, :schema)
  end

  def compile(value, opts) when is_boolean(value) do
    format_assertion = Keyword.get(opts, :format_assertion, false)
    content_assertion = Keyword.get(opts, :content_assertion, false)

    compile_schema_node(value, nil, @default_vocabs_list, %{
      loader: nil,
      format_assertion: format_assertion,
      content_assertion: content_assertion
    })
  end

  @doc """
  Compiles a JSON Schema fragment from a containing document while preserving
  that document as the reference-resolution context.
  """
  @spec compile_fragment(map() | boolean(), keyword()) :: {:ok, Schema.t()} | {:error, Error.t()}
  def compile_fragment(document, opts) when (is_map(document) or is_boolean(document)) and is_list(opts) do
    with {:ok, entry_schema, base_uri} <- Fragment.entry(document, opts) do
      compile_root_schema(entry_schema, document, base_uri, opts, :document)
    end
  end

  def compile_fragment(_document, _opts) do
    {:error,
     Fragment.error(
       "invalid_document",
       nil,
       "JSONSchex.compile_fragment/2 expects the document to be a map or boolean"
     )}
  end

  @doc """
  Bundles a JSON Schema fragment into a standalone raw schema document.
  """
  @spec bundle_fragment(map() | boolean(), keyword()) :: {:ok, map() | boolean()} | {:error, Error.t()}
  defdelegate bundle_fragment(document, opts), to: Bundle, as: :bundle

  defp compile_root_schema(raw_schema, context_document, init_base, opts, scope_mode) do
    loader = Keyword.get(opts, :loader)
    format_assertion = Keyword.get(opts, :format_assertion, false)
    content_assertion = Keyword.get(opts, :content_assertion, false)

    ctx = %{
      loader: loader,
      format_assertion: format_assertion,
      content_assertion: content_assertion
    }

    with :ok <- Dialect.validate_required_vocabularies(raw_schema),
         {:ok, root_vocabs} <- resolve_dialect(raw_schema, loader, @default_vocabs_list),
         {:ok, root_compiled} <- compile_schema_node(raw_schema, init_base, root_vocabs, ctx) do
      root_compiled = %{root_compiled | raw: context_document}
      {global_scopes, explicit_refs} = scan_context(context_document, init_base, scope_mode)

      full_defs =
        Enum.reduce_while(global_scopes, root_compiled.defs, fn {id, sub_raw}, acc_defs ->
          if Map.has_key?(acc_defs, id) do
            {:cont, acc_defs}
          else
            if id == root_compiled.source_id do
              {:cont, Map.put(acc_defs, id, root_compiled)}
            else
              case Dialect.validate_required_vocabularies(sub_raw) do
                :ok ->
                  case resolve_dialect(sub_raw, loader, root_vocabs) do
                    {:ok, sub_vocabs} ->
                      sub_raw
                      |> Map.delete("$id")
                      |> compile_schema_node(id, sub_vocabs, ctx)
                      |> case do
                        {:ok, compiled_sub} ->
                          compiled_sub = %{compiled_sub | raw: sub_raw}
                          {:cont, Map.put(acc_defs, id, compiled_sub)}

                        {:error, error} ->
                          {:halt, {:error, error}}
                      end

                    {:error, error} ->
                      {:halt, {:error, error}}
                  end

                {:error, _msg} = error ->
                  {:halt, error}
              end
            end
          end
        end)

      resolved_runtime_defs =
        resolve_refs(context_document, MapSet.to_list(explicit_refs), root_vocabs, ctx, init_base)

      case merge_defs(full_defs, resolved_runtime_defs) do
        {:error, _} = error ->
          error

        defs ->
          {:ok, %{root_compiled | defs: defs, loader: loader}}
      end
    end
  end

  defp scan_context(context_document, _base_uri, :schema), do: ScopeScanner.scan(context_document)
  defp scan_context(context_document, base_uri, :document), do: ScopeScanner.scan_all(context_document, base_uri)

  defp merge_defs({:error, error}, _), do: {:error, error}
  defp merge_defs(full_defs, runtime_defs), do: Map.merge(full_defs, runtime_defs)

  defp resolve_dialect(schema, loader, current_vocabs) do
    case Dialect.resolve_builtin(schema) do
      {:ok, vocabs} ->
        {:ok, vocabs}

      nil ->
        resolve_dialect_fallback(schema, loader, current_vocabs)
    end
  end

  defp resolve_dialect_fallback(%{"$schema" => uri}, loader, current_vocabs)
       when is_function(loader) and is_binary(uri) do
    case loader.(uri) do
      {:ok, meta_schema} when is_map(meta_schema) ->
        with :ok <- Dialect.validate_required_vocabularies(meta_schema) do
          {:ok, Dialect.enabled_vocabularies(meta_schema, @default_vocabs_list)}
        end

      {:error, reason} ->
        {:error,
         %Error{context: %ErrorContext{contrast: "load_remote", input: uri, error_detail: reason}}}

      _ ->
        {:ok, current_vocabs}
    end
  end

  defp resolve_dialect_fallback(_, _, current_vocabs) do
    {:ok, current_vocabs}
  end

  defp resolve_refs(raw_schema, refs, vocabs, ctx, base_uri) do
    ExJSONPointer.batch_resolve_reduce(raw_schema, refs, %{}, fn ref, result, acc ->
      case result do
        {:ok, fragment} ->
          case compile_schema_node(fragment, base_uri, vocabs, ctx) do
            {:ok, compiled_sub} ->
              compiled_sub = %{compiled_sub | raw: fragment}

              Map.put(acc, ref, compiled_sub)

            _ ->
              acc
          end

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp compile_schema_node(true, _id, _vocabs, ctx) do
    {:ok,
     %Schema{
       rules: [],
       defs: %{},
       format_assertion: ctx.format_assertion,
       content_assertion: ctx.content_assertion
     }}
  end

  defp compile_schema_node(false, _id, _vocabs, ctx) do
    rule = %Rule{
      name: :boolean_schema,
      params: false
    }

    {:ok,
     %Schema{
       rules: [rule],
       defs: %{},
       format_assertion: ctx.format_assertion,
       content_assertion: ctx.content_assertion
     }}
  end

  defp compile_schema_node(schema, parent_base, vocabs, ctx) when is_map(schema) do
    raw_id = Map.get(schema, "$id")
    base = resolve_uri(parent_base, raw_id)

    with {:ok, compiled_defs} <- compile_local_defs(schema, base, vocabs, ctx),
         {:ok, standard_rules} <- compile_standard_keywords(schema, base, vocabs, ctx) do
      # Draft 2020-12 allows $ref to have sibling keywords
      rules =
        if Map.has_key?(schema, "$ref") do
          [compile_ref(schema["$ref"], base) | standard_rules]
        else
          standard_rules
        end

      {:ok,
       %Schema{
         rules: rules,
         defs: compiled_defs,
         source_id: base,
         raw: schema,
         loader: ctx.loader,
         format_assertion: ctx.format_assertion,
         content_assertion: ctx.content_assertion
       }}
    end
  end

  defp resolve_uri(parent, id), do: URIUtil.resolve(parent, id)

  defp compile_local_defs(schema, base, vocabs, ctx) do
    raw_defs = Map.get(schema, "$defs", %{})

    Enum.reduce_while(raw_defs, {:ok, %{}}, fn {key, sub}, {:ok, acc} ->
      case compile_schema_node(sub, base, vocabs, ctx) do
        {:ok, compiled_sub} ->
          local_ref = "#/$defs/" <> key

          updated_acc = Map.put(acc, local_ref, compiled_sub)

          {:cont, {:ok, updated_acc}}

        {:error, error} ->
          {:halt, {:error, %{error | path: ["$defs", key] ++ error.path}}}
      end
    end)
  end

  defp compile_standard_keywords(schema, base, vocabs, ctx) do
    {uneval_props, rest} = Map.pop(schema, "unevaluatedProperties")
    {uneval_items, rest} = Map.pop(rest, "unevaluatedItems")

    with {:ok, base_rules} <- compile_keywords_list(rest, base, vocabs, ctx),
         {:ok, props_rule} <-
           compile_unevaluted("unevaluatedProperties", uneval_props, base, vocabs, ctx),
         {:ok, items_rule} <-
           compile_unevaluted("unevaluatedItems", uneval_items, base, vocabs, ctx) do
      finalizers = []
      finalizers = if props_rule, do: [props_rule | finalizers], else: finalizers
      finalizers = if items_rule, do: [items_rule | finalizers], else: finalizers

      {:ok, base_rules ++ Enum.reverse(finalizers)}
    end
  end

  defp compile_keywords_list(keywords_map, base, vocabs, ctx) do
    Enum.reduce_while(keywords_map, {:ok, []}, fn {k, v}, {:ok, acc} ->
      if keyword_allowed?(k, vocabs, ctx) do
        case compile_keyword({k, v}, keywords_map, base, vocabs, ctx) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp compile_unevaluted(_, nil, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_unevaluted("unevaluatedProperties" = keyword, sub_schema, base, vocabs, ctx) do
    if keyword_allowed?(keyword, vocabs, ctx) do
      case compile_schema_node(sub_schema, base, vocabs, ctx) do
        {:ok, compiled} ->
          {:ok, build_unevaluated_props_rule(compiled)}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, nil}
    end
  end

  defp compile_unevaluted("unevaluatedItems" = keyword, sub_schema, base, vocabs, ctx) do
    if keyword_allowed?(keyword, vocabs, ctx) do
      case compile_schema_node(sub_schema, base, vocabs, ctx) do
        {:ok, compiled} ->
          {:ok, build_unevaluated_items_rule(compiled)}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, nil}
    end
  end

  defp keyword_allowed?("format", vocabs, ctx) do
    ctx.format_assertion == true or
      vocab_supported?(vocabs, Vocabulary.format_annotation()) or
      vocab_supported?(vocabs, Vocabulary.format_assertion())
  end

  defp keyword_allowed?(keyword, vocabs, ctx)
       when keyword in ["contentMediaType", "contentEncoding", "contentSchema"] do
    ctx.content_assertion == true or
      vocab_supported?(vocabs, Vocabulary.keyword(keyword))
  end

  defp keyword_allowed?(keyword, vocabs, _ctx) do
    vocab = Vocabulary.keyword(keyword)

    cond do
      is_nil(vocab) ->
        true

      vocab_supported?(vocabs, vocab) ->
        true

      true ->
        false
    end
  end

  defp compile_ref(ref_string, base) do
    resolved_uri = URIUtil.resolve(base, ref_string)

    %Rule{
      name: :ref,
      params: %{ref: ref_string, resolved_uri: resolved_uri}
    }
  end

  defp compile_keyword({"contentMediaType", _media_type}, _, _base, _vocabs, _ctx) do
    {:ok, nil}
  end

  defp compile_keyword({"contentEncoding", _encoding}, _, _base, _vocabs, _ctx) do
    {:ok, nil}
  end

  defp compile_keyword({"contentSchema", schema}, full_schema, base, vocabs, ctx) do
    content_media_type = Map.get(full_schema, "contentMediaType")
    content_encoding = Map.get(full_schema, "contentEncoding")

    if ctx.content_assertion == true do
      case compile_schema_node(schema, base, vocabs, ctx) do
        {:ok, compiled_sub} ->
          {:ok,
           %Rule{
             name: :contentSchema,
             params: %{
               schema: compiled_sub,
               media_type: content_media_type,
               encoding: content_encoding
             }
           }}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, nil}
    end
  end

  defp compile_keyword({"format", format}, _, _base, vocabs, ctx) do
    if ctx.format_assertion == true or vocab_supported?(vocabs, Vocabulary.format_assertion()) do
      {:ok,
       %Rule{
         name: :format,
         params: format
       }}
    else
      {:ok, nil}
    end
  end

  defp compile_keyword({"$dynamicRef", ref}, _, _base, _vocabs, _loader) do
    {:ok,
     %Rule{
       name: :dynamicRef,
       params: ref
     }}
  end

  defp compile_keyword({"$dynamicAnchor", _}, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_keyword({"type", t}, _, _base, _vocabs, _ctx)
       when is_binary(t) and is_valid_types?(t) do
    {:ok, %Rule{name: :type, params: t}}
  end

  defp compile_keyword({"type", types}, _, _base, _vocabs, _ctx) when is_list(types) do
    invalid = Enum.reject(types, &(is_binary(&1) and &1 in JSONSchex.Types.valid_types()))

    if invalid == [] do
      {:ok, %Rule{name: :type, params: types}}
    else
      {:error,
       %Error{
         rule: :invalid_keyword_value,
         path: ["type"],
         value: types,
         context: %ErrorContext{contrast: JSONSchex.Types.valid_types(), input: types}
       }}
    end
  end

  defp compile_keyword({"type", t}, _, _base, _vocabs, _ctx) do
    {:error,
     %Error{
       rule: :invalid_keyword_value,
       path: ["type"],
       value: t,
       context: %ErrorContext{contrast: JSONSchex.Types.valid_types(), input: t}
     }}
  end

  defp compile_keyword({kw, m}, _, _base, _vocabs, _ctx)
       when is_numeric_keywords?(kw) and not is_number(m) do
    {:error,
     %Error{
       rule: :invalid_keyword_value,
       path: [kw],
       value: m,
       context: %ErrorContext{contrast: "number", input: m}
     }}
  end

  defp compile_keyword({"minimum", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :minimum, params: m}}

  defp compile_keyword({"maximum", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :maximum, params: m}}

  defp compile_keyword({"exclusiveMinimum", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :exclusiveMinimum, params: m}}

  defp compile_keyword({"exclusiveMaximum", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :exclusiveMaximum, params: m}}

  # "multipleOf" — value must be a strictly positive number
  defp compile_keyword({"multipleOf", m}, _, _base, _vocabs, _ctx)
       when not is_number(m) or m <= 0 do
    {:error,
     %Error{
       rule: :invalid_keyword_value,
       path: ["multipleOf"],
       value: m,
       context: %ErrorContext{contrast: "strictly_positive_number", input: m}
     }}
  end

  defp compile_keyword({"multipleOf", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :multipleOf, params: m}}

  defp compile_keyword({kw, m}, _, _base, _vocabs, _ctx)
       when is_non_neg_int_keywords?(kw) and
              not (is_integer(m) and m >= 0) and
              not (is_float(m) and m >= 0.0 and trunc(m) == m) do
    {:error,
     %Error{
       rule: :invalid_keyword_value,
       path: [kw],
       value: m,
       context: %ErrorContext{contrast: "non_negative_integer", input: m}
     }}
  end

  defp compile_keyword({"minLength", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :minLength, params: m}}

  defp compile_keyword({"maxLength", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :maxLength, params: m}}

  defp compile_keyword({"pattern", p}, _, _base, _vocabs, _ctx) do
    case JSONSchex.Compiler.ECMARegex.compile(p) do
      {:ok, regex} ->
        {:ok, %Rule{name: :pattern, params: %{source: p, regex: regex}}}

      {:error, {err, _pos}} ->
        {:error,
         %Error{
           rule: :invalid_regex,
           path: ["pattern"],
           value: p,
           context: %ErrorContext{error_detail: err}
         }}
    end
  end

  defp compile_keyword({"minProperties", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :minProperties, params: m}}

  defp compile_keyword({"maxProperties", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :maxProperties, params: m}}

  defp compile_keyword({"minItems", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :minItems, params: m}}

  defp compile_keyword({"maxItems", m}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :maxItems, params: m}}

  defp compile_keyword({"uniqueItems", b}, _, _base, _vocabs, _ctx) when not is_boolean(b) do
    {:error,
     %Error{
       rule: :invalid_keyword_value,
       path: ["uniqueItems"],
       value: b,
       context: %ErrorContext{contrast: "boolean", input: b}
     }}
  end

  defp compile_keyword({"uniqueItems", b}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :uniqueItems, params: b}}

  defp compile_keyword({"enum", v}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :enum, params: v}}

  defp compile_keyword({"const", c}, _, _base, _vocabs, _ctx),
    do: {:ok, %Rule{name: :const, params: c}}

  defp compile_keyword({"required", []}, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_keyword({"required", req}, _, _base, _vocabs, _ctx) do
    {:ok,
     %Rule{
       name: :required,
       params: req
     }}
  end

  defp compile_keyword({"properties", props}, _, _base, _vocabs, _ctx) when map_size(props) == 0,
    do: {:ok, nil}

  defp compile_keyword({"properties", props}, _, base, vocabs, ctx) do
    Enum.reduce_while(props, {:ok, []}, fn {key, sub}, {:ok, acc} ->
      case compile_schema_node(sub, base, vocabs, ctx) do
        {:ok, c} -> {:cont, {:ok, [{key, c} | acc]}}
        {:error, compile_error} -> {:halt, {:error, compile_error}}
      end
    end)
    |> case do
      {:ok, compiled_props} ->
        {:ok,
         %Rule{
           name: :properties,
           params: compiled_props
         }}

      {:error, _} = err ->
        err
    end
  end

  defp compile_keyword({"patternProperties", patterns}, _, _base, _vocabs, _ctx)
       when map_size(patterns) == 0,
       do: {:ok, nil}

  defp compile_keyword({"patternProperties", patterns}, _, base, vocabs, ctx) do
    result =
      Enum.reduce_while(patterns, {:ok, []}, fn {pattern, sub}, {:ok, acc} ->
        with {:ok, regex} <- JSONSchex.Compiler.ECMARegex.compile(pattern),
             {:ok, compiled_sub} <- compile_schema_node(sub, base, vocabs, ctx) do
          {:cont, {:ok, [{regex, compiled_sub} | acc]}}
        else
          {:error, %Error{} = error} ->
            path = error.path || []
            {:halt, {:error, %{error | path: path ++ [pattern]}}}

          {:error, {regex_term, _}} ->
            {:halt,
             {:error,
              %Error{
                rule: :invalid_regex,
                path: ["patternProperties", pattern],
                context: %ErrorContext{
                  contrast: "invalid_regex",
                  input: pattern,
                  error_detail: regex_term
                }
              }}}
        end
      end)

    case result do
      {:ok, compiled_patterns} ->
        {:ok,
         %Rule{
           name: :patternProperties,
           params: compiled_patterns
         }}

      error ->
        error
    end
  end

  defp compile_keyword({"additionalProperties", sub_schema}, full_schema, base, vocabs, ctx) do
    raw_patterns = Map.keys(Map.get(full_schema, "patternProperties", %{}))

    regex_compilation =
      Enum.reduce_while(raw_patterns, {:ok, []}, fn p, {:ok, acc} ->
        case JSONSchex.Compiler.ECMARegex.compile(p) do
          {:ok, r} ->
            {:cont, {:ok, [r | acc]}}

          {:error, {regex_term, _}} ->
            {:halt,
             {:error,
              %Error{
                rule: :invalid_regex,
                path: ["patternProperties", p],
                context: %ErrorContext{
                  contrast: "invalid_regex",
                  input: p,
                  error_detail: regex_term
                }
              }}}
        end
      end)

    with {:ok, compiled_patterns} <- regex_compilation,
         {:ok, compiled_sub} <- compile_schema_node(sub_schema, base, vocabs, ctx) do
      known_props_set = Map.keys(Map.get(full_schema, "properties", %{})) |> MapSet.new()
      always_valid? = match?(%Schema{rules: []}, compiled_sub)

      {:ok,
       %Rule{
         name: :additionalProperties,
         params: %{
           schema: compiled_sub,
           known_props: known_props_set,
           patterns: compiled_patterns,
           always_valid?: always_valid?
         }
       }}
    end
  end

  # Pre-2019 compatibility: "dependencies" combines dependentRequired and dependentSchemas.
  defp compile_keyword({"dependencies", deps}, _, base, vocabs, ctx) do
    {required_deps, schema_deps} =
      Enum.reduce(deps, {%{}, %{}}, fn
        {key, dep_list}, {req_acc, schema_acc} when is_list(dep_list) ->
          {Map.put(req_acc, key, dep_list), schema_acc}

        {key, dep_schema}, {req_acc, schema_acc}
        when is_map(dep_schema) or is_boolean(dep_schema) ->
          {req_acc, Map.put(schema_acc, key, dep_schema)}
      end)

    compiled_schema_deps = compile_dependent_schemas_map(schema_deps, base, vocabs, ctx)

    case compiled_schema_deps do
      {:ok, compiled_schemas} ->
        {:ok,
         %Rule{
           name: :dependencies,
           params: build_dependencies_params(required_deps, compiled_schemas)
         }}

      {:error, error, key} ->
        {:error, %{error | path: ["dependencies", key] ++ error.path}}
    end
  end

  defp compile_keyword({"dependentRequired", deps}, _, _base, _vocabs, _ctx)
       when map_size(deps) == 0,
       do: {:ok, nil}

  defp compile_keyword({"dependentRequired", deps}, _, _base, _vocabs, _ctx) do
    {:ok,
     %Rule{
       name: :dependentRequired,
       params: deps
     }}
  end

  defp compile_keyword({"dependentSchemas", deps}, _, _base, _vocabs, _ctx)
       when map_size(deps) == 0,
       do: {:ok, nil}

  defp compile_keyword({"dependentSchemas", deps}, _, base, vocabs, ctx) do
    case compile_dependent_schemas_map(deps, base, vocabs, ctx) do
      {:ok, compiled_deps} ->
        {:ok,
         %Rule{
           name: :dependentSchemas,
           params: compiled_deps
         }}

      {:error, error, key} ->
        {:error, %{error | path: ["dependentSchemas", key] ++ error.path}}
    end
  end

  defp compile_keyword({"propertyNames", schema}, _, base, vocabs, ctx) do
    case compile_schema_node(schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        {:ok,
         %Rule{
           name: :propertyNames,
           params: compiled_sub
         }}

      {:error, error} ->
        {:error, %{error | path: ["propertyNames"] ++ error.path}}
    end
  end

  defp compile_keyword({"prefixItems", []}, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_keyword({"prefixItems", schemas}, _, base, vocabs, ctx) do
    case map_compile_list(schemas, base, vocabs, ctx) do
      {:ok, compiled_schemas} ->
        {:ok,
         %Rule{
           name: :prefixItems,
           params: compiled_schemas
         }}

      {:error, error} ->
        {:error, %{error | path: ["prefixItems"] ++ error.path}}
    end
  end

  defp compile_keyword({"items", sub_schema}, full_schema, base, vocabs, ctx) do
    start_index =
      if is_list(Map.get(full_schema, "prefixItems")),
        do: length(full_schema["prefixItems"]),
        else: 0

    case compile_schema_node(sub_schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        {:ok,
         %Rule{
           name: :items,
           params: %{start_index: start_index, schema: compiled_sub}
         }}

      {:error, error} ->
        {:error, %{error | path: ["items"] ++ error.path}}
    end
  end

  defp compile_keyword({"contains", sub_schema}, full_schema, base, vocabs, ctx) do
    case compile_schema_node(sub_schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        min = Map.get(full_schema, "minContains", 1)
        max = Map.get(full_schema, "maxContains")

        {:ok,
         %Rule{
           name: :contains,
           params: %{schema: compiled_sub, min: min, max: max}
         }}

      {:error, error} ->
        {:error, %{error | path: ["contains"] ++ error.path}}
    end
  end

  # Logic Applicators
  defp compile_keyword({"allOf", schemas}, _, base, vocabs, ctx),
    do: compile_applicator(:allOf, schemas, base, vocabs, ctx)

  defp compile_keyword({"anyOf", schemas}, _, base, vocabs, ctx),
    do: compile_applicator(:anyOf, schemas, base, vocabs, ctx)

  defp compile_keyword({"oneOf", schemas}, _, base, vocabs, ctx),
    do: compile_applicator(:oneOf, schemas, base, vocabs, ctx)

  defp compile_keyword({"not", schema}, _, base, vocabs, ctx) do
    case compile_schema_node(schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        {:ok,
         %Rule{
           name: :not,
           params: compiled_sub
         }}

      {:error, error} ->
        {:error, %{error | path: ["not"] ++ error.path}}
    end
  end

  defp compile_keyword({"if", if_schema}, full_schema, base, vocabs, ctx) do
    then_schema = Map.get(full_schema, "then")
    else_schema = Map.get(full_schema, "else")

    with {:ok, compiled_if} <- compile_schema_node(if_schema, base, vocabs, ctx),
         {:ok, compiled_then} <- compile_optional_schema(then_schema, base, vocabs, ctx),
         {:ok, compiled_else} <- compile_optional_schema(else_schema, base, vocabs, ctx) do
      {:ok,
       %Rule{
         name: :if,
         params: %{if: compiled_if, then: compiled_then, else: compiled_else}
       }}
    else
      {:error, %Error{} = error} ->
        {:error, %{error | path: ["if"] ++ error.path}}
    end
  end

  # "then" and "else" without "if" are ignored per spec
  defp compile_keyword({"then", _}, _, _base, _vocabs, _ctx), do: {:ok, nil}
  defp compile_keyword({"else", _}, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_keyword(_, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_optional_schema(nil, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_optional_schema(schema, base, vocabs, ctx),
    do: compile_schema_node(schema, base, vocabs, ctx)

  defp map_compile_list(list, base, vocabs, ctx) do
    Enum.reduce_while(list, {:ok, []}, fn sub, {:ok, acc} ->
      case compile_schema_node(sub, base, vocabs, ctx) do
        {:ok, c} ->
          {:cont, {:ok, [c | acc]}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} ->
        {:ok, Enum.reverse(reversed)}

      error ->
        error
    end
  end

  defp compile_dependent_schemas_map(deps, _base, _vocabs, _ctx) when map_size(deps) == 0 do
    {:ok, %{}}
  end

  defp compile_dependent_schemas_map(deps, base, vocabs, ctx) do
    Enum.reduce_while(deps, {:ok, %{}}, fn {prop, schema}, {:ok, acc} ->
      case compile_schema_node(schema, base, vocabs, ctx) do
        {:ok, compiled} -> {:cont, {:ok, Map.put(acc, prop, compiled)}}
        {:error, error} -> {:halt, {:error, error, prop}}
      end
    end)
  end

  defp build_dependencies_params(required_deps, compiled_schemas) do
    has_required = map_size(required_deps) > 0
    has_schemas = map_size(compiled_schemas) > 0

    cond do
      has_required and has_schemas ->
        %{mode: :both, required: required_deps, schemas: compiled_schemas}

      has_required ->
        %{mode: :required, required: required_deps}

      has_schemas ->
        %{mode: :schemas, schemas: compiled_schemas}

      true ->
        :ok
    end
  end

  defp compile_applicator(name, schemas, base, vocabs, ctx) do
    case map_compile_list(schemas, base, vocabs, ctx) do
      {:ok, compiled_schemas} ->
        {:ok,
         %Rule{
           name: name,
           params: compiled_schemas
         }}

      {:error, error} ->
        {:error, %{error | path: [name | error.path]}}
    end
  end

  defp build_unevaluated_props_rule(sub_schema) do
    is_false_schema? =
      match?(
        %JSONSchex.Types.Schema{rules: [%{name: :boolean_schema, params: false}]},
        sub_schema
      )

    %Rule{
      name: :unevaluatedProperties,
      params: %{schema: sub_schema, false_schema?: is_false_schema?}
    }
  end

  defp build_unevaluated_items_rule(sub_schema) do
    is_false_schema? =
      match?(
        %Schema{rules: [%{name: :boolean_schema, params: false}]},
        sub_schema
      )

    %Rule{
      name: :unevaluatedItems,
      params: %{schema: sub_schema, false_schema?: is_false_schema?}
    }
  end
end

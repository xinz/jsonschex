defmodule JSONSchex.Compiler do
  @moduledoc """
  Transforms raw JSON Schema maps into executable `Schema` structs.

  Compilation has two phases:

  1. **Node compilation** — Recursively converts keywords into `Rule` structs
     (validation closures), resolves vocabularies, and compiles `$defs`.
  2. **Scope scanning** — Discovers all `$id` and anchor definitions across the
     schema tree and registers them by absolute URI for reference resolution.

  Standard rules execute first; **finalizer** rules (`unevaluatedProperties`,
  `unevaluatedItems`) run last so they can see which keys were already evaluated.

  ## Examples

      iex> {:ok, schema} = JSONSchex.Compiler.compile(%{"type" => "string"})
      iex> length(schema.rules)
      1

  """
  alias JSONSchex.Types.{Schema, Rule, Error, CompileError}
  alias JSONSchex.Compiler.Predicates
  alias JSONSchex.Validator
  alias JSONSchex.Validator.Keywords
  alias JSONSchex.ScopeScanner
  alias JSONSchex.Vocabulary
  alias JSONSchex.URIUtil

  @default_vocabs_list Vocabulary.defaults()


  @doc """
  Compiles a raw JSON Schema into an executable `Schema` struct.

  See `JSONSchex.compile/2` for options and usage.
  """
  @spec compile(map() | boolean()) :: {:ok, Schema.t()} | {:error, String.t()}
  def compile(raw_schema, opts \\ [])
  def compile(raw_schema, opts) when is_map(raw_schema) do
    external_loader = Keyword.get(opts, :external_loader)
    init_base = Keyword.get(opts, :base_uri)
    format_assertion = Keyword.get(opts, :format_assertion, false)
    content_assertion = Keyword.get(opts, :content_assertion, false)

    ctx = %{loader: external_loader, format_assertion: format_assertion, content_assertion: content_assertion}

    # Step A: Compile the root using the recursive node logic
    with :ok <- check_vocabulary(raw_schema),
         {:ok, root_vocabs} <- resolve_dialect(raw_schema, external_loader, @default_vocabs_list),
         {:ok, root_compiled} <- compile_schema_node(raw_schema, init_base, root_vocabs, ctx) do

      global_scopes = ScopeScanner.scan(raw_schema)

      full_defs =
        Enum.reduce_while(global_scopes, root_compiled.defs, fn {id, sub_raw}, acc_defs ->
          if Map.has_key?(acc_defs, id) do
            {:cont, acc_defs}
          else
            if id == root_compiled.source_id do
              {:cont, Map.put(acc_defs, id, root_compiled)}
            else

              case check_vocabulary(sub_raw) do
                :ok ->

                  case resolve_dialect(sub_raw, external_loader, root_vocabs) do
                    {:ok, sub_vocabs} ->
                      sub_raw
                      |> Map.delete("$id")
                      |> compile_schema_node(id, sub_vocabs, ctx)
                      |> case do
                        {:ok, compiled_sub} ->
                          compiled_sub = %{compiled_sub | raw: sub_raw}
                          {:cont, Map.put(acc_defs, id, compiled_sub)}
                        {:error, msg} ->
                          {:halt, {:error, msg}}
                      end

                    {:error, msg} ->
                      {:halt, {:error, msg}}
                  end
                {:error, _msg} = error ->
                  {:halt, error}
              end
            end
          end
        end)

      case full_defs do
        {:error, msg} ->
          {:error, msg}
        valid_defs ->
          # Return the root schema with the ENRICHED registry
          {:ok, %{root_compiled | defs: valid_defs, external_loader: external_loader}}
      end
    end
  end
  def compile(value, opts) when is_boolean(value) do
    format_assertion = Keyword.get(opts, :format_assertion, false)
    content_assertion = Keyword.get(opts, :content_assertion, false)
    compile_schema_node(value, nil, @default_vocabs_list, %{loader: nil, format_assertion: format_assertion, content_assertion: content_assertion})
  end

  defp resolve_dialect(%{"$schema" => uri}, loader, current_vocabs) when is_function(loader) and is_binary(uri) do
    case loader.(uri) do
      {:ok, meta_schema} when is_map(meta_schema) ->
        with :ok <- check_vocabulary(meta_schema) do
          {:ok, fetch_enabled_vocabs(meta_schema, @default_vocabs_list)}
        end
      {:error, msg} ->
        {:error, msg}
      _ ->
        {:ok, current_vocabs}
    end
  end
  defp resolve_dialect(_, _, current_vocabs) do
    {:ok, current_vocabs}
  end

  defp fetch_enabled_vocabs(%{"$vocabulary" => vocabs_def}, supported) when is_map(vocabs_def) do
    vocabs_def
    |> Enum.filter(fn
      {_, true} -> true
      {uri, false} -> vocab_supported?(supported, uri)
      _ -> false
    end)
    |> Enum.map(fn {v_uri, _} -> v_uri end)
  end
  defp fetch_enabled_vocabs(_, defaults), do: defaults

  defp vocab_supported?(supported, uri) when is_list(supported), do: uri in supported
  defp vocab_supported?(_, _), do: false

  defp check_vocabulary(%{"$vocabulary" => vocab} = _schema) when is_map(vocab) do
    supported = @default_vocabs_list

    Enum.reduce_while(vocab, :ok, fn {uri, required}, :ok ->
      if required == true and not vocab_supported?(supported, uri) do
        {:halt, {:error, %CompileError{error: :unsupported_vocabulary, path: ["$vocabulary", uri], value: true}}}
      else
        {:cont, :ok}
      end
    end)
  end
  defp check_vocabulary(_), do: :ok

  defp compile_schema_node(true, _id, _vocabs, ctx) do
    {:ok, %Schema{rules: [], defs: %{}, format_assertion: ctx.format_assertion, content_assertion: ctx.content_assertion}}
  end

  defp compile_schema_node(false, _id, _vocabs, ctx) do
    rule = %Rule{
      name: :boolean_schema,
      params: false,
      validator: fn _data, {path, _, _} ->
        {:error, [%Error{path: path, rule: :boolean_schema}]}
      end
    }
    {:ok, %Schema{rules: [rule], defs: %{}, format_assertion: ctx.format_assertion, content_assertion: ctx.content_assertion}}
  end

  defp compile_schema_node(schema, parent_base, vocabs, ctx) when is_map(schema) do
    current_vocabs =
      if Map.has_key?(schema, "$schema") do
        resolve_dialect(schema, ctx.loader, vocabs)
      else
        {:ok, vocabs}
      end

    raw_id = Map.get(schema, "$id")
    base = resolve_uri(parent_base, raw_id)

    with {:ok, current_vocabs} <- current_vocabs,
         {:ok, compiled_defs} <- compile_local_defs(schema, base, current_vocabs, ctx),
         {:ok, standard_rules} <- compile_standard_keywords(schema, base, current_vocabs, ctx) do

        # Draft 2020-12 allows $ref to have sibling keywords
        rules =
          if Map.has_key?(schema, "$ref") do
            [compile_ref(schema["$ref"], base) | standard_rules]
          else
            standard_rules
          end

        {:ok, %Schema{
          rules: rules,
          defs: compiled_defs,
          source_id: base,
          raw: schema,
          external_loader: ctx.loader,
          format_assertion: ctx.format_assertion,
          content_assertion: ctx.content_assertion
        }}
      end
    end

  defp resolve_uri(parent, id), do: URIUtil.resolve(parent, id)

  defp compile_local_defs(schema, base, vocabs, ctx) do
    raw_defs = Map.get(schema, "$defs", %{})

    Enum.reduce_while(raw_defs, {:ok, %{}}, fn {key, sub}, {:ok, acc} ->
      # RECURSION: We call compile_schema_node, not compile_rules_only
      case compile_schema_node(sub, base, vocabs, ctx) do
        {:ok, compiled_sub} ->
          updated_acc =
            acc
            |> Map.put("#/$defs/" <> key, compiled_sub)
            |> register_id_alias(sub, compiled_sub)
          {:cont, {:ok, updated_acc}}

        {:error, compile_error} ->
          {:halt, {:error, %{compile_error | path: ["$defs", key] ++ compile_error.path}}}
      end
    end)
  end

  defp register_id_alias(registry, raw_sub_schema, compiled_sub) when is_map(raw_sub_schema) do
    case Map.get(raw_sub_schema, "$id") do
      id when is_binary(id) -> Map.put(registry, id, compiled_sub)
      _ -> registry
    end
  end
  defp register_id_alias(registry, _raw_sub_schema, _compiled_sub), do: registry

  defp compile_standard_keywords(schema, base, vocabs, ctx) do
    {uneval_props, rest} = Map.pop(schema, "unevaluatedProperties")
    {uneval_items, rest} = Map.pop(rest, "unevaluatedItems")

    with {:ok, base_rules} <- compile_keywords_list(rest, base, vocabs, ctx),
         {:ok, props_rule} <- compile_unevaluted("unevaluatedProperties", uneval_props, base, vocabs, ctx),
         {:ok, items_rule} <- compile_unevaluted("unevaluatedItems", uneval_items, base, vocabs, ctx) do

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
          {:error, msg} -> {:halt, {:error, msg}}
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
        {:error, msg} ->
          {:error, msg}
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
        {:error, msg} ->
          {:error, msg}
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
      params: ref_string,
      validator: fn data, ctx ->
        Validator.validate_ref(data, ref_string, resolved_uri, ctx)
      end
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
              params: %{schema: compiled_sub, media_type: content_media_type, encoding: content_encoding},
              validator: fn data, {path, evaluated, root} ->
                Keywords.validate_content_schema(data, compiled_sub, content_media_type, content_encoding, path, root, evaluated)
              end
            }
          }
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
          params: format,
          validator: fn data, _ctx ->
            JSONSchex.Formats.validate(format, data)
          end
        }
      }
    else
      # Format is annotation-only — skip emitting a rule entirely.
      {:ok, nil}
    end
  end

  defp compile_keyword({"$dynamicRef", ref}, _, _base, _vocabs, _loader) do
    {:ok,
      %Rule{
        name: :dynamicRef,
        params: ref,
        validator: fn data, ctx ->
          Validator.validate_dynamic_ref(data, ref, ctx)
        end
      }
    }
  end

  defp compile_keyword({"$dynamicAnchor", _}, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_keyword({"type", t}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :type, params: t, validator: fn d, _ -> Predicates.check_type(d, t) end}}
  defp compile_keyword({"minimum", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :minimum, params: m, validator: fn d, _ -> Predicates.check_minimum(d, m) end}}
  defp compile_keyword({"maximum", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :maximum, params: m, validator: fn d, _ -> Predicates.check_maximum(d, m) end}}
  defp compile_keyword({"exclusiveMinimum", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :exclusiveMinimum, params: m, validator: fn d, _ -> Predicates.check_exclusive_minimum(d, m) end}}
  defp compile_keyword({"exclusiveMaximum", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :exclusiveMaximum, params: m, validator: fn d, _ -> Predicates.check_exclusive_maximum(d, m) end}}
  defp compile_keyword({"multipleOf", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :multipleOf, params: m, validator: fn d, _ -> Predicates.check_multiple_of(d, m) end}}

  defp compile_keyword({"minLength", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :minLength, params: m, validator: fn d, _ -> Predicates.check_min_length(d, m) end}}
  defp compile_keyword({"maxLength", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :maxLength, params: m, validator: fn d, _ -> Predicates.check_max_length(d, m) end}}

  defp compile_keyword({"pattern", p}, _, _base, _vocabs, _ctx) do
    case JSONSchex.Compiler.ECMARegex.compile(p) do
      {:ok, regex} ->
        {:ok, %Rule{name: :pattern, params: p, validator: fn d, _ -> Predicates.check_pattern(d, regex) end}}
      {:error, {msg, _pos}} ->
        {:error, %CompileError{error: :invalid_regex, path: ["pattern"], value: p, message: msg}}
    end
  end

  defp compile_keyword({"minProperties", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :minProperties, params: m, validator: fn d, _ -> Predicates.check_min_properties(d, m) end}}
  defp compile_keyword({"maxProperties", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :maxProperties, params: m, validator: fn d, _ -> Predicates.check_max_properties(d, m) end}}

  defp compile_keyword({"minItems", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :minItems, params: m, validator: fn d, _ -> Predicates.check_min_items(d, m) end}}
  defp compile_keyword({"maxItems", m}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :maxItems, params: m, validator: fn d, _ -> Predicates.check_max_items(d, m) end}}
  defp compile_keyword({"uniqueItems", b}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :uniqueItems, params: b, validator: fn d, _ -> Predicates.check_unique_items(d, b) end}}

  defp compile_keyword({"enum", v}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :enum, params: v, validator: fn d, _ -> Predicates.check_enum(d, v) end}}
  defp compile_keyword({"const", c}, _, _base, _vocabs, _ctx), do: {:ok, %Rule{name: :const, params: c, validator: fn d, _ -> Predicates.check_const(d, c) end}}

  defp compile_keyword({"required", req}, _, _base, _vocabs, _ctx) do
    {:ok, %Rule{
      name: :required,
      params: req,
      validator: fn data, {path, _, _} ->
        if is_map(data) do
          if Enum.all?(req, &Map.has_key?(data, &1)) do
            :ok
          else
            missing = Enum.reject(req, &Map.has_key?(data, &1))
            {:error, [%Error{path: path, rule: :required, context: %{missing: missing}}]}
          end
        else
          :ok
        end
      end
    }}
  end

  defp compile_keyword({"properties", props}, _, base, vocabs, ctx) do
    Enum.reduce_while(props, {:ok, []}, fn {key, sub}, {:ok, acc} ->
      case compile_schema_node(sub, base, vocabs, ctx) do
        {:ok, c} -> {:cont, {:ok, [{key, c} | acc]}}
        {:error, compile_error} -> {:halt, {:error, compile_error}}
      end
    end)
    |> case do
      {:ok, compiled_props} ->
        {:ok, %Rule{
          name: :properties,
          params: compiled_props,
          validator: fn data, {path, _evaluated, root} -> Keywords.validate_properties_map(data, compiled_props, path, root) end
        }}
      {:error, _} = err ->
        err
    end
  end

  defp compile_keyword({"patternProperties", patterns}, _, base, vocabs, ctx) do
    result =
      Enum.reduce_while(patterns, {:ok, []}, fn {pattern, sub}, {:ok, acc} ->
        with {:ok, regex} <- JSONSchex.Compiler.ECMARegex.compile(pattern),
             {:ok, compiled_sub} <- compile_schema_node(sub, base, vocabs, ctx) do
          {:cont, {:ok, [{regex, compiled_sub} | acc]}}
        else
          {:error, %CompileError{} = err} ->
            path = err.path || []
            {:halt, {:error, %{err | path: path ++ [pattern]}}}
          {:error, {regex_term, _}} ->
            {:halt, {:error, %CompileError{error: :invalid_regex, path: ["patternProperties", pattern], message: regex_term}}}
        end
      end)

    case result do
      {:ok, compiled_patterns} ->
        {:ok, %Rule{
          name: :patternProperties,
          params: compiled_patterns,
          validator: fn data, {path, _evaluated, root} ->
            Keywords.validate_pattern_properties(data, compiled_patterns, path, root)
          end
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
            {:halt, {:error, %CompileError{error: :invalid_regex, path: ["patternProperties", p], message: regex_term}}}
        end
      end)

    with {:ok, compiled_patterns} <- regex_compilation,
         {:ok, compiled_sub} <- compile_schema_node(sub_schema, base, vocabs, ctx) do

      known_props_set = Map.keys(Map.get(full_schema, "properties", %{})) |> MapSet.new()
      always_valid? = match?(%Schema{rules: []}, compiled_sub)

      {:ok, %Rule{
        name: :additionalProperties,
        params: compiled_sub,
        validator: fn
          data, {_path, _evaluated, _root} when always_valid? == true ->
            Keywords.collect_additional_keys(data, known_props_set, compiled_patterns)
          data, {path, _evaluated, root} ->
            Keywords.validate_additional_properties(data, compiled_sub, known_props_set, compiled_patterns, path, root)
        end
      }}
    end
  end


  # Pre-2019 compatibility: "dependencies" combines dependentRequired and dependentSchemas.
  defp compile_keyword({"dependencies", deps}, _, base, vocabs, ctx) do
    {required_deps, schema_deps} =
      Enum.reduce(deps, {%{}, %{}}, fn
        {key, dep_list}, {req_acc, schema_acc} when is_list(dep_list) ->
          {Map.put(req_acc, key, dep_list), schema_acc}

        {key, dep_schema}, {req_acc, schema_acc} when is_map(dep_schema) or is_boolean(dep_schema) ->
          {req_acc, Map.put(schema_acc, key, dep_schema)}
      end)

    compiled_schema_deps = compile_dependent_schemas_map(schema_deps, base, vocabs, ctx)

    case compiled_schema_deps do
      {:ok, compiled_schemas} ->
        has_required = map_size(required_deps) > 0
        has_schemas = map_size(compiled_schemas) > 0

        {:ok, %Rule{
          name: :dependencies,
          params: deps,
          validator: fn
            data, {_path, _evaluated, _root} when is_map(data)
              and has_required == false
              and has_schemas == false ->
              :ok
            data, {path, _evaluated, root} when is_map(data)
              and has_required == true
              and has_schemas == false ->
              Keywords.validate_dependent_required(data, required_deps, path, root)
            data, {path, _evaluated, root} when is_map(data)
              and has_required == false
              and has_schemas == true ->
              Keywords.validate_dependent_schemas(data, compiled_schemas, path, root)
            data, {path, _evaluated, root} when is_map(data)
              and has_required == true
              and has_schemas == true ->

              required_result =
                Keywords.validate_dependent_required(data, required_deps, path, root)

              schema_result =
                Keywords.validate_dependent_schemas(data, compiled_schemas, path, root)

              case {required_result, schema_result} do
                {:ok, :ok} -> :ok
                {:ok, {:ok, evaluated}} -> {:ok, evaluated}
                {:ok, {:error, errs}} -> {:error, errs}
                {{:error, req_errs}, :ok} -> {:error, req_errs}
                {{:error, req_errs}, {:ok, _}} -> {:error, req_errs}
                {{:error, req_errs}, {:error, schema_errs}} -> {:error, schema_errs ++ req_errs}
              end

            _, _ ->
              :ok
          end
        }}

      {:error, error, key} ->
        {:error, %{error | path: ["dependencies", key] ++ error.path}}
    end
  end

  defp compile_keyword({"dependentRequired", deps}, _, _base, _vocabs, _ctx) do
    {:ok, %Rule{
      name: :dependentRequired,
      params: deps,
      validator: fn data, {path, _evaluated, root} ->
        Keywords.validate_dependent_required(data, deps, path, root)
      end
    }}
  end

  defp compile_keyword({"dependentSchemas", deps}, _, base, vocabs, ctx) do
    case compile_dependent_schemas_map(deps, base, vocabs, ctx) do
      {:ok, compiled_deps} ->
        {:ok, %Rule{
          name: :dependentSchemas,
          params: compiled_deps,
          validator: fn
            data, {path, _evaluated, root} ->
              Keywords.validate_dependent_schemas(data, compiled_deps, path, root)
          end
        }}

      {:error, error, key} ->
        {:error, %{error | path: ["dependentSchemas", key] ++ error.path}}
    end
  end

  defp compile_keyword({"propertyNames", schema}, _, base, vocabs, ctx) do
    case compile_schema_node(schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        {:ok, %Rule{
          name: :propertyNames,
          params: compiled_sub,
          validator: fn data, {path, _evaluated, root} ->
            Keywords.validate_property_names(data, compiled_sub, path, root)
          end
        }}

      {:error, error} ->
        {:error, %{error | path: ["propertyNames"] ++ error.path}}
    end
  end

  defp compile_keyword({"prefixItems", schemas}, _, base, vocabs, ctx) do
    case map_compile_list(schemas, base, vocabs, ctx) do
      {:ok, compiled_schemas} ->
        {:ok, %Rule{
          name: :prefixItems,
          params: compiled_schemas,
          validator: fn data, {path, _evaluated, root} -> Keywords.validate_prefix_items(data, compiled_schemas, path, root) end
        }}
      {:error, error} ->
        {:error, %{error | path: ["prefixItems"] ++ error.path}}
    end
  end

  defp compile_keyword({"items", sub_schema}, full_schema, base, vocabs, ctx) do
    start_index = if is_list(Map.get(full_schema, "prefixItems")), do: length(full_schema["prefixItems"]), else: 0
    case compile_schema_node(sub_schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        {:ok, %Rule{
          name: :items,
          params: {start_index, compiled_sub},
          validator: fn data, {path, _evaluated, root} -> Keywords.validate_items_array(data, compiled_sub, start_index, path, root) end
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
        {:ok, %Rule{
          name: :contains,
          params: %{schema: compiled_sub, min: min, max: max},
          validator: fn data, {path, _evaluated, root} -> Keywords.validate_contains(data, compiled_sub, min, max, path, root) end
        }}
      {:error, error} ->
        {:error, %{error | path: ["contains"] ++ error.path}}
    end
  end

  # Logic Applicators
  defp compile_keyword({"allOf", schemas}, _, base, vocabs, ctx), do: compile_applicator(:allOf, schemas, base, &Keywords.validate_allOf/5, vocabs, ctx)
  defp compile_keyword({"anyOf", schemas}, _, base, vocabs, ctx), do: compile_applicator(:anyOf, schemas, base, &Keywords.validate_anyOf/5, vocabs, ctx)
  defp compile_keyword({"oneOf", schemas}, _, base, vocabs, ctx), do: compile_applicator(:oneOf, schemas, base, &Keywords.validate_oneOf/5, vocabs, ctx)

  defp compile_keyword({"not", schema}, _, base, vocabs, ctx) do
    case compile_schema_node(schema, base, vocabs, ctx) do
      {:ok, compiled_sub} ->
        {:ok, %Rule{
          name: :not,
          params: compiled_sub,
          validator: fn data, {path, evaluated, root} -> Keywords.validate_not(data, compiled_sub, path, root, evaluated) end
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

      {:ok, %Rule{
        name: :if,
        params: %{if: compiled_if, then: compiled_then, else: compiled_else},
        validator: fn data, {path, evaluated, root} ->
          Keywords.validate_if(data, compiled_if, compiled_then, compiled_else, path, root, evaluated)
        end
      }}
    else
      {:error, %CompileError{} = error} ->
        {:error, %{error | path: ["if"] ++ error.path}}
    end
  end

  # "then" and "else" without "if" are ignored per spec
  defp compile_keyword({"then", _}, _, _base, _vocabs, _ctx), do: {:ok, nil}
  defp compile_keyword({"else", _}, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_keyword(_, _, _base, _vocabs, _ctx), do: {:ok, nil}

  defp compile_optional_schema(nil, _base, _vocabs, _ctx), do: {:ok, nil}
  defp compile_optional_schema(schema, base, vocabs, ctx), do: compile_schema_node(schema, base, vocabs, ctx)

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

  defp compile_applicator(name, schemas, base, validate_fn, vocabs, ctx) do
    case map_compile_list(schemas, base, vocabs, ctx) do
      {:ok, compiled_schemas} ->
        {:ok, %Rule{
          name: name,
          params: compiled_schemas,
          validator: fn data, {path, evaluated, root} -> validate_fn.(data, compiled_schemas, path, root, evaluated) end
        }}
      {:error, error} ->
        {:error, %{error | path: [name | error.path]}}
    end
  end

  defp build_unevaluated_props_rule(sub_schema) do
    is_false_schema? = match?(
      %JSONSchex.Types.Schema{rules: [%{name: :boolean_schema, params: false}]},
      sub_schema
    )

    %Rule{
      name: :unevaluatedProperties,
      params: sub_schema,
      validator: fn data, {path, evaluated_keys, root} ->
        case Keywords.validate_unevaluated_props(data, sub_schema, path, evaluated_keys, root) do
          {:ok, _} = new_evaluated ->
            new_evaluated
          :ok ->
            :ok
          {:error, errors} when is_false_schema? ->
            rewritten_errors = Enum.map(errors, fn e ->
              %{e | rule: :unevaluatedProperties, context: %{error: :not_allowed}, message: nil}
            end)
            {:error, rewritten_errors}
          error ->
            error
        end
      end
    }
  end

  defp build_unevaluated_items_rule(sub_schema) do
    is_false_schema? = match?(
      %Schema{rules: [%{name: :boolean_schema, params: false}]},
      sub_schema
    )

    %Rule{
      name: :unevaluatedItems,
      params: sub_schema,
      validator: fn data, {path, evaluated_indices, root} ->
        case Keywords.validate_unevaluated_items(data, sub_schema, path, evaluated_indices, root) do
          {:ok, _} = new_evaluated ->
            new_evaluated
          :ok ->
            :ok

          {:error, errors} when is_false_schema? ->
             rewritten = Enum.map(errors, fn e -> %{e | rule: :unevaluatedItems, context: %{error: :not_allowed}, message: nil} end)
             {:error, rewritten}

          {:error, errors} -> {:error, errors}
        end
      end
    }
  end

end

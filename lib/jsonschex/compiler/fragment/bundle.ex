defmodule JSONSchex.Compiler.Fragment.Bundle do
  @moduledoc false

  alias JSONSchex.Compiler.Fragment
  alias JSONSchex.{ResourceContext, SchemaTraversal, URIUtil}
  alias JSONSchex.Types.{Error, ErrorContext}

  # Generated `$defs` keys are storage slots, not reference identities. Resources
  # retain their identity through `$id` and anchors, and no generated reference
  # points at these keys. `put_generated_defs/2` may therefore suffix a key to
  # avoid replacing a caller-owned definition without rewriting any references.
  @context_definition_key "jsonschex_context_document"
  @external_definition_prefix "jsonschex_external"
  @anchor_definition_prefix "jsonschex_anchor"

  defmodule State do
    @moduledoc false

    defstruct loader: nil,
              external_resources: %{},
              base_aliases: %{},
              resource_roots: %{},
              anchors: %{},
              dynamic_anchors: %{},
              fallback_anchors: %{},
              reachable_anchors: %{},
              visited_refs: %{}
  end

  @doc false
  def bundle(document, opts) when (is_map(document) or is_boolean(document)) and is_list(opts) do
    with {:ok, entry_schema, base_uri} <- Fragment.entry(document, opts),
         {:ok, bundle} <- build(document, entry_schema, base_uri, opts) do
      {:ok, bundle}
    end
  end

  def bundle(_document, _opts) do
    {:error,
     Fragment.error(
       "invalid_document",
       nil,
       "JSONSchex.bundle_fragment/2 expects the document to be a map or boolean"
     )}
  end

  defp build(_document, entry_schema, _base_uri, _opts) when is_boolean(entry_schema) do
    {:ok, entry_schema}
  end

  defp build(document, entry_schema, base_uri, opts) when is_map(entry_schema) do
    {entry_resource, entry_base, entry_resources} =
      entry_resource_context(document, Keyword.get(opts, :entry), base_uri)

    bundle =
      entry_resource
      |> merge_entry_schema(entry_schema)
      |> put_entry_base_uri(entry_schema, entry_base)

    with :ok <- validate_generated_defs(bundle),
         bundle <- put_context_document(bundle, document, entry_resource, base_uri),
         {:ok, {external_resources, reachable_anchors, base_aliases}} <-
           collect_external_resources(document, entry_schema, entry_base, entry_resources, base_uri, opts) do
      bundle = rewrite_external_refs(bundle, entry_base, base_aliases)

      bundle =
        bundle
        |> put_external_resources(external_resources, base_aliases)
        |> put_reachable_anchors(reachable_anchors, base_aliases)

      {:ok, bundle}
    end
  end

  defp merge_entry_schema(document, entry_schema) when is_map(document) do
    Map.merge(document, entry_schema)
  end

  defp merge_entry_schema(_document, entry_schema), do: entry_schema

  defp put_bundle_base_uri(bundle, base_uri) when is_map(bundle) and is_binary(base_uri) do
    Map.put_new(bundle, "$id", base_uri)
  end

  defp put_bundle_base_uri(bundle, _base_uri), do: bundle

  defp resolve_base_from_id(%{"$id" => id}, base), do: URIUtil.resolve(base, id)
  defp resolve_base_from_id(_schema, base), do: base

  defp put_entry_base_uri(bundle, entry_schema, inherited_base) do
    case resolve_base_from_id(entry_schema, inherited_base) do
      effective_base when is_binary(effective_base) -> Map.put(bundle, "$id", effective_base)
      _ -> Map.delete(bundle, "$id")
    end
  end

  defp validate_generated_defs(%{"$defs" => defs}) when not is_map(defs) do
    {:error,
     Fragment.error(
       "invalid_defs",
       defs,
       "The selected entry resource must contain a map at $defs when bundling requires generated resources"
     )}
  end

  defp validate_generated_defs(_bundle), do: :ok

  defp put_context_document(bundle, document, entry_resource, _base_uri) when document == entry_resource do
    bundle
  end

  defp put_context_document(bundle, document, _entry_resource, base_uri) when is_map(document) do
    context_document = put_effective_base_uri(document, base_uri)
    put_generated_defs(bundle, %{@context_definition_key => context_document})
  end

  defp put_effective_base_uri(document, retrieval_base) when is_map(document) do
    case resolve_base_from_id(document, retrieval_base) do
      effective_base when is_binary(effective_base) -> Map.put(document, "$id", effective_base)
      _ -> document
    end
  end

  defp put_effective_base_uri(document, _retrieval_base), do: document

  defp collect_external_resources(document, entry_schema, entry_base, entry_resources, base_uri, opts) do
    state = %State{loader: Keyword.get(opts, :loader)}

    state = put_resource_root(state, base_uri, document, base_uri)

    state =
      Enum.reduce(entry_resources, state, fn {resource, resource_base}, acc ->
        index_schema_tree(acc, resource, resource_base)
      end)

    state = index_fallback_anchors(state, document, base_uri)

    case walk_reachable(entry_schema, entry_base, {[], %{}}, state) do
      {:ok, state} ->
        {:ok, {state.external_resources, state.reachable_anchors, state.base_aliases}}

      {:error, error} ->
        {:error, error}
    end
  end

  # Authoritative resource metadata is indexed only from roots already known to
  # be schemas. This deliberately traverses schema-valued JSON Schema keywords,
  # including inactive definitions, without following any references.
  defp index_schema_tree(state, schema, current_base) when is_map(schema) do
    new_base = resolve_base_from_id(schema, current_base)

    state =
      case Map.get(schema, "$id") do
        id when is_binary(id) -> put_resource_root(state, new_base, schema, current_base)
        _ -> state
      end

    state =
      ["$anchor", "$dynamicAnchor"]
      |> Enum.reduce(state, fn keyword, acc ->
        case Map.get(schema, keyword) do
          anchor when is_binary(anchor) ->
            acc
            |> put_anchor(new_base, anchor, schema, current_base)
            |> maybe_put_dynamic_anchor(keyword, new_base, anchor)

          _ ->
            acc
        end
      end)

    schema
    |> SchemaTraversal.metadata_subschemas()
    |> Enum.reduce(state, fn subschema, acc -> index_schema_tree(acc, subschema, new_base) end)
  end

  defp index_schema_tree(state, _schema, _current_base), do: state





  # Anchors have no URI that can be loaded, so a containing non-schema document
  # needs a discovery fallback. These candidates never register `$id` resources
  # or dynamic scope and are consulted only after authoritative schema metadata.
  defp index_fallback_anchors(state, value, base_uri) do
    do_index_fallback_anchors(state, value, base_uri, [])
  end

  defp do_index_fallback_anchors(state, value, base_uri, path) when is_map(value) do
    state =
      ["$anchor", "$dynamicAnchor"]
      |> Enum.reduce(state, fn keyword, acc ->
        case Map.get(value, keyword) do
          anchor when is_binary(anchor) -> put_fallback_anchor(acc, base_uri, anchor, value, path)
          _ -> acc
        end
      end)

    Enum.reduce(value, state, fn {key, child}, acc ->
      do_index_fallback_anchors(acc, child, base_uri, [key | path])
    end)
  end

  defp do_index_fallback_anchors(state, value, base_uri, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(state, fn {child, index}, acc ->
      do_index_fallback_anchors(acc, child, base_uri, [index | path])
    end)
  end

  defp do_index_fallback_anchors(state, _value, _base_uri, _path), do: state

  defp put_fallback_anchor(state, base_uri, anchor, schema, path) do
    anchor_uri = URIUtil.resolve(base_uri, "#" <> anchor)
    candidate_path = Enum.reverse(path)
    candidate = {schema, base_uri, candidate_path}

    candidates =
      Map.update(state.fallback_anchors, anchor_uri, [candidate], fn existing ->
        if Enum.any?(existing, fn {_schema, _base, path} -> path == candidate_path end) do
          existing
        else
          existing ++ [candidate]
        end
      end)

    %{state | fallback_anchors: candidates}
  end

  defp put_resource_root(state, uri, document, inherited_base) do
    key = resource_key(uri)
    roots = Map.put_new(state.resource_roots, key, {document, inherited_base})
    %{state | resource_roots: roots}
  end

  defp put_anchor(state, base_uri, anchor, schema, inherited_base) do
    anchor_uri = URIUtil.resolve(base_uri, "#" <> anchor)
    %{state | anchors: Map.put(state.anchors, anchor_uri, {schema, inherited_base})}
  end

  defp maybe_put_dynamic_anchor(state, "$dynamicAnchor", base_uri, anchor) do
    anchor_uri = URIUtil.resolve(base_uri, "#" <> anchor)
    %{state | dynamic_anchors: Map.put(state.dynamic_anchors, anchor_uri, anchor)}
  end

  defp maybe_put_dynamic_anchor(state, _keyword, _base_uri, _anchor), do: state

  defp resource_key(nil), do: ""
  defp resource_key(uri) when is_binary(uri) do
    {base, _fragment} = URIUtil.split_fragment(uri)
    base
  end

  defp walk_reachable(schema, current_base, dynamic_scope, state) when is_map(schema) do
    state = index_schema_tree(state, schema, current_base)
    new_base = resolve_base_from_id(schema, current_base)
    dynamic_scope = put_dynamic_scope(dynamic_scope, resource_key(new_base))

    with {:ok, state} <- follow_schema_refs(schema, new_base, dynamic_scope, state) do
      schema
      |> SchemaTraversal.active_subschemas()
      |> Enum.reduce_while({:ok, state}, fn subschema, {:ok, acc} ->
        case walk_reachable(subschema, new_base, dynamic_scope, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp walk_reachable(list, current_base, dynamic_scope, state) when is_list(list) do
    Enum.reduce_while(list, {:ok, state}, fn value, {:ok, acc} ->
      case walk_reachable(value, current_base, dynamic_scope, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp walk_reachable(_value, _current_base, _dynamic_scope, state), do: {:ok, state}

  defp put_dynamic_scope({stack, members} = dynamic_scope, base) do
    if Map.has_key?(members, base) do
      dynamic_scope
    else
      {[base | stack], Map.put(members, base, true)}
    end
  end



  defp follow_schema_refs(schema, current_base, dynamic_scope, state) do
    with {:ok, state} <- follow_ref_keyword(Map.get(schema, "$ref"), current_base, dynamic_scope, state) do
      follow_dynamic_ref_keyword(Map.get(schema, "$dynamicRef"), current_base, dynamic_scope, state)
    end
  end

  defp follow_ref_keyword(ref, current_base, dynamic_scope, state) when is_binary(ref) do
    follow_ref(ref, current_base, dynamic_scope, state)
  end

  defp follow_ref_keyword(_ref, _current_base, _dynamic_scope, state), do: {:ok, state}

  defp follow_dynamic_ref_keyword(ref, current_base, dynamic_scope, state) when is_binary(ref) do
    resolved = URIUtil.resolve(current_base, ref)

    with {:ok, target, target_base, state} <- reachable_target(resolved, state) do
      state =
        state
        |> put_reachable_anchor(resolved, target, target_base)
        |> index_schema_tree(target, target_base)

      anchor = URIUtil.fragment(ref)

      if dynamic_anchor_target?(target, anchor) do
        case winning_dynamic_anchor_uri(dynamic_scope, anchor, state) do
          nil -> follow_ref(ref, current_base, dynamic_scope, state)
          uri -> follow_ref(uri, nil, dynamic_scope, state)
        end
      else
        follow_ref(ref, current_base, dynamic_scope, state)
      end
    end
  end

  defp follow_dynamic_ref_keyword(_ref, _current_base, _dynamic_scope, state), do: {:ok, state}

  defp dynamic_anchor_target?(%{"$dynamicAnchor" => anchor}, anchor) when is_binary(anchor), do: true
  defp dynamic_anchor_target?(_target, _anchor), do: false

  defp winning_dynamic_anchor_uri({stack, _members}, anchor, state) when is_binary(anchor) do
    Enum.reduce(stack, nil, fn base, winner ->
      uri = URIUtil.with_fragment(base, anchor)
      if Map.get(state.dynamic_anchors, uri) == anchor, do: uri, else: winner
    end)
  end

  defp winning_dynamic_anchor_uri(_dynamic_scope, _anchor, _state), do: nil

  defp follow_ref(ref, current_base, dynamic_scope, state) do
    resolved = URIUtil.resolve(current_base, ref)
    canonical_uri = canonical_ref_uri(resolved, state.base_aliases)
    {scope_stack, _scope_members} = dynamic_scope
    visited_key = {canonical_uri, scope_stack}

    if Map.has_key?(state.visited_refs, visited_key) do
      {:ok, state}
    else
      state = %{state | visited_refs: Map.put(state.visited_refs, visited_key, true)}

      with {:ok, target, target_base, state} <- reachable_target(resolved, state) do
        case target do
          nil ->
            {:ok, state}

          target ->
            state = put_reachable_anchor(state, resolved, target, target_base)
            walk_reachable(target, target_base, dynamic_scope, state)
        end
      end
    end
  end

  defp put_reachable_anchor(state, resolved, target, target_base) when is_map(target) do
    canonical_uri = canonical_ref_uri(resolved, state.base_aliases)
    {base, fragment} = URIUtil.split_fragment(canonical_uri)

    cond do
      Map.has_key?(state.external_resources, base) ->
        state

      is_binary(fragment) and not String.starts_with?(fragment, "/") ->
        reachable_anchors = Map.put(state.reachable_anchors, canonical_uri, {base, target_base, target})
        %{state | reachable_anchors: reachable_anchors}

      true ->
        state
    end
  end

  defp put_reachable_anchor(state, _resolved, _target, _target_base), do: state

  defp reachable_target(resolved, state) do
    case find_target(resolved, state) do
      {:ok, target, target_base} ->
        {:ok, target, target_base, state}

      {:ambiguous_anchor, anchor_uri, candidate_count} ->
        ambiguous_anchor_error(anchor_uri, candidate_count)

      {nil, base} ->
        with {:ok, state} <- load_external_resource(base, state) do
          case find_target(resolved, state) do
            {:ok, target, target_base} -> {:ok, target, target_base, state}
            {:ambiguous_anchor, anchor_uri, candidate_count} -> ambiguous_anchor_error(anchor_uri, candidate_count)
            _ -> {:ok, nil, nil, state}
          end
        end

      nil ->
        {:ok, nil, nil, state}
    end
  end

  defp ambiguous_anchor_error(anchor_uri, candidate_count) do
    {:error,
     %Error{
       context: %ErrorContext{
         contrast: "ambiguous_anchor",
         input: anchor_uri,
         error_detail: {:candidate_count, candidate_count}
       }
     }}
  end

  defp find_target(nil, _state), do: nil
  defp find_target(resolved, state) do
    {base, fragment} = URIUtil.split_fragment(resolved)
    effective_base = Map.get(state.base_aliases, base, base)

    case Map.get(state.resource_roots, effective_base) do
      nil ->
        {nil, base}

      {resource, inherited_base} ->
        find_resource_target(resource, inherited_base, effective_base, fragment, state)
    end
  end

  defp find_resource_target(resource, inherited_base, _effective_base, nil, _state) do
    {:ok, resource, inherited_base}
  end

  defp find_resource_target(resource, inherited_base, _effective_base, "/" <> _ = fragment, _state) do
    case ResourceContext.resolve(resource, inherited_base, fragment) do
      {:ok, %{target: target, inherited_base: target_base}} -> {:ok, target, target_base}
      :error -> nil
    end
  end

  defp find_resource_target(_resource, _inherited_base, effective_base, fragment, state) do
    anchor_uri = URIUtil.with_fragment(effective_base, fragment)

    case Map.get(state.anchors, anchor_uri) do
      nil -> find_fallback_anchor(anchor_uri, state)
      {target, inherited_base} -> {:ok, target, inherited_base}
    end
  end

  defp find_fallback_anchor(anchor_uri, state) do
    case Map.get(state.fallback_anchors, anchor_uri, []) do
      [{target, inherited_base, _path}] -> {:ok, target, inherited_base}
      [] -> nil
      candidates -> {:ambiguous_anchor, anchor_uri, length(candidates)}
    end
  end

  defp load_external_resource(base, state) do
    if not is_function(state.loader, 1) do
      {:error, %Error{context: %ErrorContext{contrast: "load_remote", input: base, error_detail: :no_loader}}}
    else
      with {:ok, document, loaded_base} <- load_resource(state.loader, base) do
        document = put_effective_base_uri(document, loaded_base)
        canonical_base = document_resource_base(document, loaded_base)

        base_aliases =
          state.base_aliases
          |> Map.put(base, canonical_base)
          |> Map.put(loaded_base, canonical_base)

        state = %{
          state
          | external_resources: Map.put(state.external_resources, canonical_base, document),
            base_aliases: base_aliases
        }

        state =
          state
          |> put_resource_root(loaded_base, document, loaded_base)
          |> index_schema_tree(document, loaded_base)
          |> index_fallback_anchors(document, loaded_base)

        {:ok, state}
      end
    end
  end

  defp document_resource_base(document, fallback_base) when is_map(document) do
    document
    |> Map.get("$id", fallback_base)
    |> resource_key()
  end

  defp document_resource_base(_document, fallback_base), do: resource_key(fallback_base)

  defp canonical_ref_uri(nil, _base_aliases), do: nil
  defp canonical_ref_uri(uri, base_aliases) do
    {base, fragment} = URIUtil.split_fragment(uri)
    URIUtil.with_fragment(Map.get(base_aliases, base, base), fragment)
  end



  defp entry_resource_context(document, entry, base_uri) do
    case entry_pointer_fragment(entry) do
      nil ->
        {document, base_uri, []}

      fragment ->
        case ResourceContext.resolve(document, base_uri, fragment) do
          {:ok, context} -> {context.resource, context.inherited_base, context.resources}
          :error -> {document, base_uri, []}
        end
    end
  end

  defp entry_pointer_fragment(""), do: nil
  defp entry_pointer_fragment("#"), do: nil
  defp entry_pointer_fragment("#/" <> rest), do: "/" <> rest
  defp entry_pointer_fragment("/" <> rest), do: "/" <> rest
  defp entry_pointer_fragment(entry) when is_binary(entry) do
    case URIUtil.split_fragment(entry) do
      {_base, "/" <> rest} -> "/" <> rest
      _ -> nil
    end
  end
  defp entry_pointer_fragment(_entry), do: nil



  defp load_resource(loader, base) do
    case loader.(base) do
      {:ok, %{document: document} = loaded} when is_map(document) or is_boolean(document) ->
        {:ok, document, base_uri_or_original(Map.get(loaded, :base_uri), base)}

      {:ok, document} when is_map(document) or is_boolean(document) ->
        {:ok, document, base}

      {:error, reason} ->
        {:error, %Error{context: %ErrorContext{contrast: "load_remote", input: base, error_detail: reason}}}

      _ ->
        {:error, %Error{context: %ErrorContext{contrast: "invalid_loader_response", input: base}}}
    end
  end

  defp base_uri_or_original(base_uri, _original_base) when is_binary(base_uri), do: base_uri
  defp base_uri_or_original(_base_uri, original_base), do: original_base

  defp rewrite_external_refs(value, _current_base, base_aliases) when map_size(base_aliases) == 0 do
    value
  end

  defp rewrite_external_refs(schema, current_base, base_aliases) when is_map(schema) do
    new_base = URIUtil.resolve(current_base, Map.get(schema, "$id"))

    schema
    |> Enum.map(fn
      {keyword, ref} when keyword in ["$ref", "$dynamicRef"] and is_binary(ref) ->
        {keyword, rewrite_external_ref(ref, new_base, base_aliases)}

      {key, value} ->
        {key, rewrite_external_refs(value, new_base, base_aliases)}
    end)
    |> Map.new()
  end

  defp rewrite_external_refs(list, current_base, base_aliases) when is_list(list) do
    Enum.map(list, &rewrite_external_refs(&1, current_base, base_aliases))
  end

  defp rewrite_external_refs(value, _current_base, _base_aliases), do: value

  defp rewrite_external_ref(ref, current_base, base_aliases) do
    resolved = URIUtil.resolve(current_base, ref)
    {base, fragment} = URIUtil.split_fragment(resolved)

    case Map.get(base_aliases, base) do
      nil -> ref
      ^base -> ref
      aliased_base -> URIUtil.with_fragment(aliased_base, fragment)
    end
  end

  defp put_external_resources(bundle, resources, _base_aliases) when map_size(resources) == 0 do
    bundle
  end

  defp put_external_resources(bundle, resources, base_aliases) do
    external_defs =
      resources
      |> Enum.sort_by(fn {base, _document} -> base end)
      |> Enum.with_index(1)
      |> Map.new(fn {{base, document}, index} ->
        document =
          document
          |> rewrite_external_refs(base, base_aliases)
          |> mount_resource_document(base)

        {"#{@external_definition_prefix}_#{index}", document}
      end)

    put_generated_defs(bundle, external_defs)
  end

  defp mount_resource_document(document, base) when is_map(document) do
    put_bundle_base_uri(document, base)
  end

  defp mount_resource_document(document, base) when is_boolean(document) do
    %{
      "$id" => base,
      "$ref" => "#/$defs/value",
      "$defs" => %{"value" => document}
    }
  end

  defp put_reachable_anchors(bundle, anchors, _base_aliases) when map_size(anchors) == 0 do
    bundle
  end

  defp put_reachable_anchors(bundle, anchors, base_aliases) do
    bundle_base = document_resource_base(bundle, "")

    anchor_defs =
      anchors
      |> Enum.sort_by(fn {uri, _target} -> uri end)
      |> Enum.with_index(1)
      |> Map.new(fn {{_uri, {base, target_base, target}}, index} ->
        target = rewrite_external_refs(target, target_base, base_aliases)
        {"#{@anchor_definition_prefix}_#{index}", put_anchor_base_uri(target, base, bundle_base)}
      end)

    put_generated_defs(bundle, anchor_defs)
  end

  defp put_anchor_base_uri(target, "", _bundle_base), do: target
  defp put_anchor_base_uri(target, base, base), do: target
  defp put_anchor_base_uri(target, base, _bundle_base) when is_binary(base) do
    Map.put(target, "$id", base)
  end

  defp put_generated_defs(bundle, generated_defs) do
    Map.update(bundle, "$defs", generated_defs, fn defs ->
      Enum.reduce(generated_defs, defs, fn {key, schema}, acc ->
        Map.put(acc, available_generated_key(acc, key), schema)
      end)
    end)
  end

  defp available_generated_key(defs, key) do
    if Map.has_key?(defs, key) do
      available_generated_key(defs, key, 2)
    else
      key
    end
  end

  defp available_generated_key(defs, key, suffix) do
    candidate = "#{key}_#{suffix}"

    if Map.has_key?(defs, candidate) do
      available_generated_key(defs, key, suffix + 1)
    else
      candidate
    end
  end
end

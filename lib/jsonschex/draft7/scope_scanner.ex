defmodule JSONSchex.Draft7.ScopeScanner do
  @moduledoc false

  alias JSONSchex.{ResourceContext, SchemaTraversal, URIUtil}

  @schema_map_keywords ~w(properties patternProperties definitions dependencies)
  @schema_list_keywords ~w(allOf anyOf oneOf)
  @single_schema_keywords ~w(additionalProperties contains items not propertyNames if then else)

  @string_value_keywords ~w(
    $id $schema $ref $comment type title description format pattern contentEncoding contentMediaType
  )

  @numeric_value_keywords ~w(
    minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
    minLength maxLength minItems maxItems minProperties maxProperties
  )

  @list_value_keywords ~w(required enum examples)
  @boolean_value_keywords ~w(uniqueItems readOnly writeOnly)
  @unrestricted_value_keywords ~w(const default)

  # These newer-draft names are only used to prune ignored schema annotations,
  # not to register anchors or execute their reference semantics.
  @ignored_scope_keywords ~w(
    $defs $anchor $dynamicAnchor $dynamicRef $vocabulary
    prefixItems dependentSchemas dependentRequired
    contentSchema unevaluatedItems unevaluatedProperties minContains maxContains deprecated
  )


  def scan(schema, opts \\ []) do
    base_uri = Keyword.get(opts, :base_uri)
    owner = document_owner(schema, base_uri)
    schema |> do_scan(base_uri, new_state(), owner) |> finish()
  end

  def scan_all(document, base_uri, opts) do
    path = Keyword.get(opts, :schema_path)
    owner = document_owner(document, base_uri)
    document |> do_scan_all(base_uri, new_state(), :document, path, owner) |> finish()
  end


  defp new_state(fallback_resources \\ %{}) do
    %{resources: %{}, fallback_resources: fallback_resources, refs: MapSet.new(), pending: []}
  end


  defp document_owner(document, base_uri) do
    %{key: :document, raw: document, base_uri: base_uri, priority: :ordinary}
  end

  defp do_scan(raw_schema, base_uri, state, owner) when is_map(raw_schema) do
    schema = scope_schema(raw_schema)
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    resources =
      if current_id do
        Map.put(state.resources, new_base_uri, raw_schema)
      else
        state.resources
      end

    owner = resource_owner(raw_schema, base_uri, owner)
    state = collect_refs(schema, %{state | resources: resources}, owner)

    SchemaTraversal.reduce_scope_subschemas(schema, state, fn subschema, acc ->
      do_scan(subschema, new_base_uri, acc, owner)
    end, "draft7")
  end

  defp do_scan(_value, _base_uri, acc, _owner), do: acc

  defp do_scan_all(schemas, base_uri, acc, :schema_map, path, owner)
       when is_map(schemas) and path != [] do
    # These keys are names, even when they happen to spell a schema keyword.
    Enum.reduce(schemas, acc, fn {name, schema}, inner_acc ->
      do_scan_all(schema, base_uri, inner_acc, :schema, child_path(path, name), owner)
    end)
  end

  defp do_scan_all(raw_schema, base_uri, state, role, path, owner) when is_map(raw_schema) do
    schema_context? = role == :schema or path == [] or schema_candidate?(raw_schema)
    schema = if schema_context?, do: scope_schema(raw_schema), else: raw_schema
    current_id = Map.get(schema, "$id")
    new_base_uri = if is_binary(current_id), do: URIUtil.resolve(base_uri, current_id), else: base_uri
    new_base_uri = new_base_uri || ""

    resources =
      if is_binary(current_id) do
        Map.put(state.resources, new_base_uri, raw_schema)
      else
        state.resources
      end

    owner = resource_owner(raw_schema, base_uri, owner)
    state = collect_refs(schema, %{state | resources: resources}, owner)

    state = Enum.reduce(schema, state, fn {key, value}, acc ->
      child_role = if schema_context?, do: schema_child_role(key), else: :document
      do_scan_all(value, new_base_uri, acc, child_role, child_path(path, key), owner)
    end)

    # Explicit entry selection may cross an ignored annotation. Follow only that
    # route, without resurrecting its sibling resources or reference annotations.
    case path do
      [key | rest] when not is_map_key(schema, key) ->
        scan_selected_route(Map.get(raw_schema, key), new_base_uri, state, rest, owner)
      _ ->
        state
    end
  end

  defp do_scan_all(list, base_uri, acc, role, nil, owner) when is_list(list) do
    Enum.reduce(list, acc, fn item, inner_acc ->
      do_scan_all(item, base_uri, inner_acc, role, nil, owner)
    end)
  end

  defp do_scan_all(list, base_uri, acc, role, path, owner) when is_list(list) do
    path = canonical_list_path(path, list)

    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {item, index}, inner_acc ->
      do_scan_all(item, base_uri, inner_acc, role, child_path(path, Integer.to_string(index)), owner)
    end)
  end

  defp do_scan_all(_value, _base_uri, acc, _role, _path, _owner), do: acc

  defp child_path([key | rest], key), do: rest
  defp child_path(_path, _key), do: nil

  defp canonical_list_path([token | rest], list) do
    case Integer.parse(token) do
      {index, ""} ->
        index = if index < 0, do: length(list) + index, else: index
        [Integer.to_string(index) | rest]
      _ -> nil
    end
  end
  defp canonical_list_path(path, _list), do: path

  defp scan_selected_route(value, base_uri, acc, [], owner) do
    do_scan_all(value, base_uri, acc, :schema, [], owner)
  end
  defp scan_selected_route(map, base_uri, state, [key | rest], owner) when is_map(map) do
    owner = resource_owner(map, base_uri, owner)
    id = scope_id(map)
    next_base = if is_binary(id), do: URIUtil.resolve(base_uri, id), else: base_uri
    fallbacks = register_fallback_resource(map, base_uri, state.fallback_resources)
    state = %{state | fallback_resources: fallbacks}
    scan_selected_route(Map.get(map, key), next_base, state, rest, owner)
  end
  defp scan_selected_route(list, base_uri, acc, [token | rest], owner) when is_list(list) do
    case Integer.parse(token) do
      {index, ""} -> scan_selected_route(Enum.at(list, index), base_uri, acc, rest, owner)
      _ -> acc
    end
  end
  defp scan_selected_route(_value, _base_uri, acc, _path, _owner), do: acc

  # The base precedes the raw root's own $id, so pointer resolution and scanning
  # a reached target each apply that ID once. Priority is inherited independently.
  defp resource_owner(%{"$ref" => _}, _base_uri, owner), do: owner
  defp resource_owner(%{"$id" => id} = raw_schema, base_uri, owner) when is_binary(id) do
    {id_base, _fragment} = URIUtil.split_fragment(id)
    uri = URIUtil.resolve(base_uri, id) || ""
    {base, _fragment} = URIUtil.split_fragment(uri)
    {owner_base, _fragment} = URIUtil.split_fragment(resource_uri(owner))

    # Fragment IDs stay within the raw resource, even when URI resolution falls
    # back to the child ID for a relative parent base.
    if id_base == "" or base == owner_base,
      do: owner,
      else: %{owner | key: {:id, uri}, raw: raw_schema, base_uri: base_uri}
  end
  defp resource_owner(_raw_schema, _base_uri, owner), do: owner

  defp resource_uri(%{key: {:id, uri}}), do: uri
  defp resource_uri(%{key: :document, base_uri: base_uri}), do: base_uri || ""

  # Crossed ancestors contribute fallback identities, never traversal of siblings.
  defp register_fallback_resource(%{"$ref" => _}, _base_uri, fallbacks), do: fallbacks
  defp register_fallback_resource(%{"$id" => id} = raw_schema, base_uri, fallbacks) when is_binary(id) do
    Map.put_new(fallbacks, URIUtil.resolve(base_uri, id) || "", raw_schema)
  end
  defp register_fallback_resource(_raw_schema, _base_uri, fallbacks), do: fallbacks

  defp finish(state) do
    discovered = follow_refs(state.pending, [], %{}, %{state | pending: []}, false)

    # Discovery-only refs must not become aliases against the root document.
    {Map.merge(discovered.fallback_resources, discovered.resources), state.refs}
  end

  # Growth includes fallback identities and promotion to ordinary resources.
  # Replay attempted lookups too: their resource may now have a different raw root.
  defp follow_refs([], replay_candidates, seen, state, true) when replay_candidates != [] do
    follow_refs(Enum.reverse(replay_candidates), [], seen, state, false)
  end
  defp follow_refs([], _replay_candidates, _seen, state, _grew?), do: state

  defp follow_refs([{owner, ref} = item | pending], replay_candidates, seen, state, grew?) do
    {more, state, seen, changed?} = discover_reference(owner, ref, state, seen)
    follow_refs(more ++ pending, [item | replay_candidates], seen, state, grew? or changed?)
  end


  defp discover_reference(owner, ref, state, seen) do
    with {:ok, target_owner, pointer} <- pointer_owner(ref, owner, state),
         {:unseen, seen} <- visit_owner(target_owner, pointer, seen) do
      discover_target(target_owner, pointer, state, seen)
    else
      _ -> {[], state, seen, false}
    end
  end


  defp visit_owner(owner, pointer, seen) do
    # Hash only stable identity/priority fields. Strict owner comparison handles
    # changed raw roots without hashing entire schemas for every pointer.
    key = {owner.priority, owner.key, pointer}
    owners = Map.get(seen, key, [])

    if Enum.any?(owners, &(&1 === owner)),
      do: :seen,
      else: {:unseen, Map.put(seen, key, [owner | owners])}
  end


  defp discover_target(owner, pointer, state, seen) do
    case ResourceContext.resolve(owner.raw, owner.base_uri, pointer, draft: "draft7") do
      {:ok, context} ->
        discovered = scan_reached_target(context, owner, state.fallback_resources)
        updated = merge_discovery(state, discovered, owner.priority, context.resources)
        {discovered.pending, updated, seen, resources_grew?(state, updated)}
      :error ->
        {[], state, seen, false}
    end
  end


  defp scan_reached_target(context, owner, fallbacks) do
    owner = Enum.reduce(context.resources, owner, fn {raw, parent_base}, acc ->
      resource_owner(raw, parent_base, acc)
    end)

    do_scan(context.target, context.inherited_base, new_state(fallbacks), owner)
  end


  defp merge_discovery(state, discovered, priority, ancestors) do
    # Weak paths stay weak through new IDs and references to ordinary resources.
    # Existing ordinary discoveries retain their original duplicate precedence.
    {resources, fallbacks} =
      case priority do
        :fallback -> {state.resources, Map.merge(discovered.resources, discovered.fallback_resources)}
        :ordinary -> {Map.merge(discovered.resources, state.resources), discovered.fallback_resources}
      end

    fallbacks = Enum.reduce(ancestors, fallbacks, fn {raw, parent_base}, acc ->
      register_fallback_resource(raw, parent_base, acc)
    end)

    %{state | resources: resources, fallback_resources: fallbacks}
  end


  defp resources_grew?(before, updated) do
    map_size(updated.resources) > map_size(before.resources) or
      map_size(updated.fallback_resources) > map_size(before.fallback_resources)
  end


  defp pointer_owner(ref, owner, state) do
    case URIUtil.split_fragment(ref) do
      {"", pointer} ->
        {:ok, owner, pointer}

      _ ->
        uri = resource_uri(owner)
        {resource_base, _fragment} = URIUtil.split_fragment(uri)
        {ref_base, pointer} = URIUtil.split_fragment(URIUtil.resolve(uri, ref))

        if ref_base == resource_base,
          do: {:ok, owner, pointer},
          else: lookup_pointer_owner(ref_base, pointer, owner.priority, state)
    end
  end


  defp lookup_pointer_owner(base_uri, pointer, priority, state) do
    # Entering an ordinary resource cannot promote a fallback-derived reference.
    {resource, priority} =
      case Map.fetch(state.resources, base_uri) do
        {:ok, resource} -> {resource, priority}
        :error -> {Map.get(state.fallback_resources, base_uri), :fallback}
      end

    case resource do
      resource when is_map(resource) ->
        # The URI already includes the root's ID. Normalize only this resolution
        # copy, retaining the original raw schema in both resource registries.
        owner = %{key: {:id, base_uri}, raw: Map.delete(resource, "$id"),
                  base_uri: base_uri, priority: priority}
        {:ok, owner, pointer}
      _ ->
        :unknown_resource
    end
  end

  defp schema_child_role(key) when key in @schema_map_keywords, do: :schema_map
  defp schema_child_role(key)
       when key in @schema_list_keywords or key in @single_schema_keywords or key == "additionalItems",
       do: :schema
  defp schema_child_role(_key), do: :document

  # Infer schema context only when no schema slot or selected-entry boundary applies.
  # This is a best-effort shape heuristic, not schema validation: ordinary document
  # maps can share these shapes, such as a string-valued "title". Conversely, a
  # map-valued "$ref" or "prefixItems" may just be a document name.
  defp schema_candidate?(map) do
    Enum.any?(map, fn
      {key, value} when key in @string_value_keywords ->
        is_binary(value) or (key == "type" and is_list(value))
      {key, value} when key in @schema_map_keywords ->
        schema_map_candidate?(key, value)
      {key, value} when key in @schema_list_keywords or key in @list_value_keywords ->
        is_list(value)
      {key, value} when key in @single_schema_keywords ->
        is_map(value) or is_boolean(value) or (key == "items" and is_list(value))
      {key, value} when key in @numeric_value_keywords ->
        is_number(value)
      {key, value} when key in @boolean_value_keywords ->
        is_boolean(value)
      {key, _value} when key in @unrestricted_value_keywords ->
        true
      _ ->
        false
    end)
  end

  # A schema-map candidate contains named schemas, not keyword values; dependencies
  # also permits property-name arrays. This shape is evidence, not a certain boundary.
  defp schema_map_candidate?(keyword, value) when is_map(value) do
    Enum.all?(value, fn {_name, child} ->
      is_map(child) or is_boolean(child) or (keyword == "dependencies" and is_list(child))
    end)
  end
  defp schema_map_candidate?(_keyword, _value), do: false

  # Selected routes need only the $ref sibling rule, not full schema filtering.
  # Keep the raw ID value so the caller's binary guard remains authoritative.

  defp scope_id(%{"$ref" => _}), do: nil
  defp scope_id(schema), do: Map.get(schema, "$id")

  # Filter discovery only; registry entries retain raw content for explicit pointers.
  defp scope_schema(%{"$ref" => _} = schema), do: Map.take(schema, ["$ref"])

  defp scope_schema(schema) do
    schema = Map.drop(schema, @ignored_scope_keywords)

    if is_list(Map.get(schema, "items")), do: schema, else: Map.delete(schema, "additionalItems")
  end

  defp collect_refs(schema, state, owner) do
    case Map.get(schema, "$ref") do
      ref when is_binary(ref) ->
        refs = if String.starts_with?(ref, "#"), do: MapSet.put(state.refs, ref), else: state.refs
        %{state | refs: refs, pending: [{owner, ref} | state.pending]}
      _ ->
        state
    end
  end
end

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

  # These newer-draft names are only used to prune ignored schema annotations,
  # not to register anchors or execute their reference semantics.
  @ignored_scope_keywords ~w(
    $defs $anchor $dynamicAnchor $dynamicRef $vocabulary
    prefixItems dependentSchemas dependentRequired
    contentSchema unevaluatedItems unevaluatedProperties minContains maxContains deprecated
  )

  def scan(schema, opts \\ []) do
    base_uri = Keyword.get(opts, :base_uri)
    owner = {:document, schema, base_uri}
    schema |> do_scan(base_uri, {%{}, MapSet.new(), []}, owner) |> finish()
  end

  def scan_all(document, base_uri, opts) do
    path = Keyword.get(opts, :schema_path)
    owner = {:document, document, base_uri}
    document |> do_scan_all(base_uri, {%{}, MapSet.new(), []}, :document, path, owner) |> finish()
  end

  defp do_scan(raw_schema, base_uri, {registry, refs, pending}, owner) when is_map(raw_schema) do
    schema = scope_schema(raw_schema)
    current_id = Map.get(schema, "$id")
    new_base_uri = URIUtil.resolve(base_uri, current_id) || ""

    registry =
      if current_id do
        Map.put(registry, new_base_uri, raw_schema)
      else
        registry
      end

    owner = resource_owner(raw_schema, base_uri, owner)
    acc = collect_refs(schema, {registry, refs, pending}, owner)

    SchemaTraversal.reduce_scope_subschemas(schema, acc, fn subschema, acc ->
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

  defp do_scan_all(raw_schema, base_uri, {registry, refs, pending}, role, path, owner) when is_map(raw_schema) do
    schema_context? = role == :schema or path == [] or schema_candidate?(raw_schema)
    schema = if schema_context?, do: scope_schema(raw_schema), else: raw_schema
    current_id = Map.get(schema, "$id")
    new_base_uri = if is_binary(current_id), do: URIUtil.resolve(base_uri, current_id), else: base_uri
    new_base_uri = new_base_uri || ""

    registry =
      if is_binary(current_id) do
        Map.put(registry, new_base_uri, raw_schema)
      else
        registry
      end

    owner = resource_owner(raw_schema, base_uri, owner)
    acc = collect_refs(schema, {registry, refs, pending}, owner)

    acc = Enum.reduce(schema, acc, fn {key, value}, acc ->
      child_role = if schema_context?, do: schema_child_role(key), else: :document
      do_scan_all(value, new_base_uri, acc, child_role, child_path(path, key), owner)
    end)

    # Explicit entry selection may cross an ignored annotation. Follow only that
    # route, without resurrecting its sibling resources or reference annotations.
    case path do
      [key | rest] when not is_map_key(schema, key) ->
        scan_selected_route(Map.get(raw_schema, key), new_base_uri, acc, rest, owner)
      _ ->
        acc
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
  defp scan_selected_route(map, base_uri, acc, [key | rest], owner) when is_map(map) do
    owner = resource_owner(map, base_uri, owner)
    id = Map.get(scope_schema(map), "$id")
    next_base = if is_binary(id), do: URIUtil.resolve(base_uri, id), else: base_uri
    scan_selected_route(Map.get(map, key), next_base, acc, rest, owner)
  end
  defp scan_selected_route(list, base_uri, acc, [token | rest], owner) when is_list(list) do
    case Integer.parse(token) do
      {index, ""} -> scan_selected_route(Enum.at(list, index), base_uri, acc, rest, owner)
      _ -> acc
    end
  end
  defp scan_selected_route(_value, _base_uri, acc, _path, _owner), do: acc

  # Resource ownership carries the base before its own $id, so pointer resolution
  # and scanning a reached target each apply that target's $id exactly once.
  defp resource_owner(%{"$ref" => _}, _base_uri, owner), do: owner
  defp resource_owner(%{"$id" => id} = raw_schema, base_uri, owner) when is_binary(id) do
    uri = URIUtil.resolve(base_uri, id) || ""
    {base, _fragment} = URIUtil.split_fragment(uri)
    {owner_base, _fragment} = URIUtil.split_fragment(resource_uri(owner))

    # Fragment IDs name subschemas within a resource; they do not change the raw
    # root against which that resource's JSON Pointers are resolved.
    if base == owner_base, do: owner, else: {{:id, uri}, raw_schema, base_uri}
  end
  defp resource_owner(_raw_schema, _base_uri, owner), do: owner

  defp resource_uri({{:id, uri}, _resource, _base_uri}), do: uri
  defp resource_uri({:document, _resource, base_uri}), do: base_uri || ""

  defp finish({registry, refs, pending}) do
    # Additional pointers drive discovery only. Publishing them as root-document
    # aliases would resolve embedded resources' local pointers against the wrong root.
    {follow_refs(pending, MapSet.new(), registry), refs}
  end

  defp follow_refs([], _seen, registry), do: registry
  defp follow_refs([{owner, ref} | pending], seen, registry) do
    {resource_key, resource, base_uri} = owner

    with {:ok, pointer} <- local_pointer(ref, owner),
         false <- MapSet.member?(seen, {resource_key, pointer}) do
      seen = MapSet.put(seen, {resource_key, pointer})

      case ResourceContext.resolve(resource, base_uri, pointer, draft: "draft7") do
        {:ok, context} ->
          target_owner = Enum.reduce(context.resources, owner, fn {raw, parent_base}, owner ->
            resource_owner(raw, parent_base, owner)
          end)
          {discovered, _refs, more} =
            do_scan(context.target, context.inherited_base, {%{}, MapSet.new(), []}, target_owner)

          # Ordinary traversal keeps its existing duplicate-identity precedence.
          registry = Map.merge(discovered, registry)
          follow_refs(more ++ pending, seen, registry)

        :error ->
          follow_refs(pending, seen, registry)
      end
    else
      _ -> follow_refs(pending, seen, registry)
    end
  end

  defp local_pointer(ref, owner) do
    case URIUtil.split_fragment(ref) do
      {"", pointer} ->
        {:ok, pointer}

      _ ->
        uri = resource_uri(owner)
        {resource_base, _fragment} = URIUtil.split_fragment(uri)
        {ref_base, pointer} = URIUtil.split_fragment(URIUtil.resolve(uri, ref))

        if ref_base == resource_base, do: {:ok, pointer}, else: :error
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
      {key, value} when key in @schema_list_keywords or key in ~w(required enum examples) ->
        is_list(value)
      {key, value} when key in @single_schema_keywords ->
        is_map(value) or is_boolean(value) or (key == "items" and is_list(value))
      {key, value} when key in @numeric_value_keywords ->
        is_number(value)
      {key, value} when key in ~w(uniqueItems readOnly writeOnly) ->
        is_boolean(value)
      {key, _value} when key in ~w(const default) ->
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

  # Filter discovery only; registry entries retain raw content for explicit pointers.
  defp scope_schema(%{"$ref" => _} = schema), do: Map.take(schema, ["$ref"])

  defp scope_schema(schema) do
    schema = Map.drop(schema, @ignored_scope_keywords)

    if is_list(Map.get(schema, "items")), do: schema, else: Map.delete(schema, "additionalItems")
  end

  defp collect_refs(schema, {registry, refs, pending} = acc, owner) do
    case Map.get(schema, "$ref") do
      ref when is_binary(ref) ->
        refs = if String.starts_with?(ref, "#"), do: MapSet.put(refs, ref), else: refs
        {registry, refs, [{owner, ref} | pending]}
      _ ->
        acc
    end
  end
end

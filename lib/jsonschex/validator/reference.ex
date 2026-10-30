defmodule JSONSchex.Validator.Reference do
  @moduledoc """
  Resolves `$ref` and `$dynamicRef` during validation, including remote schema
  loading and JIT compilation of JSON Pointer references.
  """

  alias JSONSchex.Validator
  alias JSONSchex.Compiler
  alias JSONSchex.URIUtil
  alias JSONSchex.ResourceContext
  alias JSONSchex.Draft202012.Schemas, as: Draft202012Schemas
  alias JSONSchex.Draft7.Schemas, as: Draft7Schemas
  alias JSONSchex.Types.ErrorContext

  @doc """
  Resolves a `$dynamicRef` by checking if the static target has a matching
  `$dynamicAnchor`, then performing dynamic scope lookup through the scope stack.
  Falls back to static `$ref` resolution if no dynamic anchor is found.
  """
  def validate_dynamic_ref(data, ref_string, {path, evaluated, validation_context} = context) do
    anchor = URIUtil.fragment(ref_string)

    static_match = resolve_scoped_ref(ref_string, validation_context)

    is_dynamic_candidate =
      anchor && static_match && is_map(static_match.raw) && Map.get(static_match.raw, "$dynamicAnchor") == anchor

    if is_dynamic_candidate do
      dynamic_match =
        validation_context.scope_stack
        |> Enum.reverse()
        |> Enum.find_value(fn base_uri ->
          candidate_uri = URIUtil.join_fragment(base_uri, anchor)

          case Map.get(validation_context.root_schema.defs, candidate_uri) do
            %{raw: raw} = schema when is_map(raw) ->
              if Map.get(raw, "$dynamicAnchor") == anchor do
                schema
              else
                nil
              end
            _ ->
              nil
          end
        end)

      if dynamic_match do
        Validator.validate_reference_entry(dynamic_match, data, path, validation_context, evaluated)
      else
        Validator.validate_reference_entry(static_match, data, path, validation_context, evaluated, ref_string)
      end
    else
      validate_ref(data, ref_string, context)
    end
  end

  @doc """
  Resolves and validates a static `$ref`.

  Looks up the target schema in the compiled `defs` registry. If not found locally
  and the reference points to a remote URI, attempts to load it using the `loader`.
  Supports JSON Pointer references, anchor references, and absolute/relative URIs.
  """
  def validate_ref(data, ref_string, {path, evaluated, validation_context}) do
    effective_context = effective_context_for_ref(validation_context, ref_string)

    case resolve_scoped_ref(ref_string, effective_context) do
      nil ->
        resolve_missing_ref(data, ref_string, path, effective_context, evaluated)

      schema ->
        Validator.validate_reference_entry(schema, data, path, effective_context, evaluated, ref_string)
    end
  end

  defp effective_context_for_ref(validation_context, ref_string) do
    case built_in_defs_for_ref(validation_context.source_id, ref_string, validation_context.root_schema) do
      nil ->
        validation_context

      defs ->
        merge_defs_into_context(validation_context, defs)
    end
  end

  # A retrieval base need not be registered by $id. An empty reference still
  # belongs to the current raw root, rather than an external load or URI pointer.
  defp resolve_missing_ref(data, "", path, validation_context, evaluated) do
    resolve_and_validate_jit(data, validation_context.raw, "", path, validation_context, evaluated)
  end

  defp resolve_missing_ref(data, ref_string, path, validation_context, evaluated) do
    uri_to_load = resolve_relative_uri(validation_context.source_id, ref_string)

    with nil <- check_registry_for_base(uri_to_load, validation_context.root_schema.defs),
         :ok <- check_load_remote(validation_context.root_schema.loader, uri_to_load),
         result <- load_remote_schema(data, uri_to_load, path, validation_context, evaluated) do
      result
    else
      {:ok, base_schema, fragment} when is_map(base_schema) ->
        resolve_registry_base_match(data, ref_string, path, validation_context, evaluated, base_schema, fragment)

      :halt ->
        resolve_and_validate_jit(data, validation_context.raw, uri_to_load, path, validation_context, evaluated)
    end
  end

  defp resolve_registry_base_match(
         data,
         _ref_string,
         path,
         validation_context,
         evaluated,
         base_schema,
         fragment
       ) do
    local_ref = URIUtil.local_ref(fragment)

    if base_schema.source_id == validation_context.source_id do
      resolve_and_validate_jit(data, validation_context.raw, local_ref, path, validation_context, evaluated)
    else
      updated_context = merge_defs_into_context(validation_context, base_schema.defs)

      # Compile the pointer target against the matched resource base, but keep
      # the current validation context so reference entry records the resource
      # transition and preserves dynamic scope semantics.
      resolve_and_validate_jit(
        data,
        base_schema.raw,
        local_ref,
        path,
        updated_context,
        evaluated,
        base_schema.source_id
      )
    end
  end

  defp merge_defs_into_context(validation_context, new_defs) when is_map(new_defs) do
    merged_defs = Map.merge(validation_context.root_schema.defs, new_defs)
    updated_root = %{validation_context.root_schema | defs: merged_defs}
    %{validation_context | root_schema: updated_root}
  end

  defp check_registry_for_base(uri, registry) do
    {base, fragment} = URIUtil.split_fragment(uri)

    case {base, fragment, Map.get(registry, base)} do
      {_, nil, _} ->
        nil

      {_, _, nil} ->
        nil

      {_, fragment, schema} ->
        {:ok, schema, fragment}
    end
  end

  defp check_load_remote(loader, uri_to_load) when is_function(loader) do
    if URIUtil.remote_ref?(uri_to_load) or URIUtil.external_ref?(uri_to_load), do: :ok, else: :halt
  end
  defp check_load_remote(_, _), do: :halt

  defp built_in_defs_for_ref(_, nil, _schema), do: nil
  defp built_in_defs_for_ref(base_uri, ref, schema) do
    uri = uri_to_resolve(base_uri, ref)
    builtin_compiled_defs(URIUtil.base(uri), schema)
  end

  defp builtin_compiled_defs(base, %{draft: "draft7"} = schema) do
    Draft7Schemas.compiled_defs(base,
      format_assertion: schema.format_assertion,
      content_assertion: schema.content_assertion)
  end
  defp builtin_compiled_defs(base, %{draft: "draft2020_12"}), do: Draft202012Schemas.compiled_defs(base)

  @doc false
  def lookup_ref("#/" <> _ = ref, context), do: Map.get(context.local_refs, ref)
  def lookup_ref("#", context), do: Map.get(context.local_refs, "#")
  def lookup_ref("#" <> fragment = ref, context) do
    case URI.decode(fragment) do
      "/" <> _ -> Map.get(context.local_refs, ref)
      _ -> Map.get(context.root_schema.defs, uri_to_resolve(context.source_id, ref))
    end
  end
  def lookup_ref(uri, context), do: Map.get(context.root_schema.defs, uri)

  @doc false
  def local_refs_for(schema, root_schema) do
    # The root self-entry predates eager pointer compilation. Preserve those
    # targets' inherited dialect instead of recompiling with default vocabularies.
    if URIUtil.base(schema.source_id) == URIUtil.base(root_schema.source_id) and
         schema.raw === root_schema.raw do
      root_schema.local_refs
    else
      schema.local_refs
    end
  end

  defp resolve_scoped_ref(ref, context) do
    uri = if context.source_id == ref, do: ref, else: uri_to_resolve(context.source_id, ref)

    # Bare pointers in the merged registry have no resource ownership. Reuse
    # only the active raw root's aliases, including for normalized URN pointers.
    lookup_ref(uri, context) || Map.get(context.local_refs, ref)
  end

  defp uri_to_resolve(base_uri, "#" <> _ = ref) when base_uri != nil do
    base_uri = URIUtil.base(base_uri)
    URIUtil.join_fragment(base_uri, URIUtil.fragment(ref))
  end
  defp uri_to_resolve(base_uri, ref) when base_uri != nil do
    resolve_relative_uri(base_uri, ref)
  end
  defp uri_to_resolve(nil, ref) when ref != nil, do: ref
  defp uri_to_resolve(_, _), do: nil

  defp resolve_relative_uri(nil, ref), do: ref
  defp resolve_relative_uri(base_uri, ref_string) do
    cond do
      String.starts_with?(ref_string, base_uri <> "#/") ->
        String.replace(ref_string, base_uri, "")

      String.starts_with?(ref_string, base_uri <> "#") ->
        ref_string
      true ->
        case URI.parse(base_uri) do
          %{scheme: "urn"} ->
            ref_string

          _ ->
            if String.starts_with?(ref_string, "#") do
              ref_string
            else
              URIUtil.resolve(base_uri, ref_string)
            end
        end
    end
  end

  defp load_remote_schema(data, uri, current_path, validation_context, evaluated) do
    {base, fragment} = URIUtil.split_fragment(uri)

    case Map.get(validation_context.root_schema.defs, base) do
      nil ->
        case builtin_compiled_defs(base, validation_context.root_schema) do
          built_in_defs when is_map(built_in_defs) ->
            merged_context = merge_defs_into_context(validation_context, built_in_defs)
            compiled_remote = Map.fetch!(merged_context.root_schema.defs, base)
            validate_loaded_schema(data, compiled_remote, fragment, current_path, merged_context, evaluated)

          nil ->
            case load_external_schema(uri, base, validation_context) do
              {:ok, compiled_remote, merged_context} ->
                validate_loaded_schema(data, compiled_remote, fragment, current_path, merged_context, evaluated)

              :halt ->
                :halt

              {:error, reason} ->
                {:error, %ErrorContext{contrast: "load_remote", input: uri, error_detail: reason}}

              _ ->
                {:error, %ErrorContext{contrast: "invalid_loader_response", input: uri}}
            end
        end

      loaded_schema ->
        updated_context = %{validation_context |
          source_id: loaded_schema.source_id,
          raw: loaded_schema.raw,
          local_refs: local_refs_for(loaded_schema, validation_context.root_schema)
        }

        validate_ref(data, URIUtil.local_ref(fragment), {current_path, evaluated, updated_context})
    end
  end

  defp load_external_schema(uri, base, validation_context) do
    case validation_context.root_schema.loader do
      loader when is_function(loader) ->
        case loader.(base) do
          {:ok, remote_raw} ->
            compile_loaded_external_schema(remote_raw, uri, base, validation_context)

          other ->
            other
        end

      _ ->
        :halt
    end
  end

  defp compile_loaded_external_schema(%{document: document} = loaded, uri, original_base, validation_context)
       when is_map(document) or is_boolean(document) do
    base_uri = loaded |> Map.get(:base_uri) |> base_uri_or_original(original_base)
    compile_loaded_external_schema(document, uri, base_uri, validation_context)
  end

  defp compile_loaded_external_schema(remote_raw, uri, base, validation_context)
       when is_map(remote_raw) or is_boolean(remote_raw) do
    opts = [
      loader: validation_context.root_schema.loader,
      base_uri: base,
      format_assertion: validation_context.root_schema.format_assertion,
      content_assertion: validation_context.root_schema.content_assertion,
      draft: validation_context.root_schema.draft
    ]

    case Compiler.compile(remote_raw, opts) do
      {:ok, compiled_remote} ->
        merged_defs = Map.put(compiled_remote.defs || %{}, base, compiled_remote)

        # The canonical self-entry predates eager pointer compilation. Publish the
        # finalized cache under both retrieval and canonical resource identities.
        merged_defs =
          case URIUtil.base(compiled_remote.source_id) do
            canonical when is_binary(canonical) and canonical != "" ->
              Map.put(merged_defs, canonical, compiled_remote)
            _ ->
              merged_defs
          end

        merged_context = merge_defs_into_context(validation_context, merged_defs)
        {:ok, compiled_remote, merged_context}

      {:error, error} ->
        {:error, %ErrorContext{contrast: "compile_remote", input: uri, error_detail: error}}
    end
  end

  defp compile_loaded_external_schema(_remote_raw, uri, _base, _validation_context) do
    {:error, %ErrorContext{contrast: "invalid_loader_response", input: uri}}
  end

  defp base_uri_or_original(base_uri, _original_base) when is_binary(base_uri), do: base_uri
  defp base_uri_or_original(_base_uri, original_base), do: original_base

  defp validate_loaded_schema(data, compiled_schema, fragment, current_path, validation_context, evaluated) do
    updated_context = loaded_schema_context(validation_context, compiled_schema)

    if fragment != nil do
      validate_ref(data, URIUtil.local_ref(fragment), {current_path, evaluated, updated_context})
    else
      Validator.validate_reference_entry(compiled_schema, data, current_path, updated_context, evaluated)
    end
  end

  defp loaded_schema_context(validation_context, compiled_schema) do
    new_stack =
      if compiled_schema.source_id do
        [compiled_schema.source_id | validation_context.scope_stack]
      else
        validation_context.scope_stack
      end

    %{validation_context |
      scope_stack: new_stack,
      source_id: compiled_schema.source_id,
      raw: compiled_schema.raw,
      local_refs: local_refs_for(compiled_schema, validation_context.root_schema)
    }
  end

  defp resolve_and_validate_jit(
         data,
         raw_root,
         pointer,
         current_path,
         validation_context,
         evaluated,
         compile_base_uri \\ nil
       ) do
    case ExJSONPointer.resolve(raw_root, pointer) do
      {:ok, found_fragment} ->
        {base_uri, resource} = pointer_context(
          raw_root,
          pointer,
          compile_base_uri || validation_context.source_id,
          validation_context.root_schema.draft
        )
        opts = [
          loader: validation_context.root_schema.loader,
          base_uri: base_uri,
          format_assertion: validation_context.root_schema.format_assertion,
          content_assertion: validation_context.root_schema.content_assertion,
          draft: validation_context.root_schema.draft
        ]
        case Compiler.compile(found_fragment, opts) do
          {:ok, compiled_fragment} ->
            # A source transition must carry the owning resource, not the selected
            # leaf, so subsequent pointers resolve against the same URI and raw root.
            local_refs = if compiled_fragment.raw === resource, do: compiled_fragment.local_refs, else: %{}
            compiled_fragment = %{compiled_fragment | raw: resource, local_refs: local_refs}
            Validator.validate_reference_entry(compiled_fragment, data, current_path, validation_context, evaluated)

          {:error, error} ->
            {:error, %ErrorContext{contrast: "invalid_schema", input: pointer, error_detail: error}}
        end

      {:error, _token} ->
        {:error, %ErrorContext{contrast: "ref_not_found", input: pointer}}
    end
  end

  defp pointer_context(raw_root, pointer, resource_base, draft) do
    # The current resource's $id is already reflected in resource_base. Descendant
    # $ids along a pointer, however, must be applied before compiling its target.
    scope_root = if is_map(raw_root), do: Map.delete(raw_root, "$id"), else: raw_root

    case ResourceContext.resolve(scope_root, resource_base, URIUtil.fragment(pointer), draft: draft) do
      {:ok, %{inherited_base: base, resource: resource}} ->
        resource = if resource === scope_root, do: raw_root, else: resource
        {base, resource}
      :error ->
        {resource_base, raw_root}
    end
  end
end

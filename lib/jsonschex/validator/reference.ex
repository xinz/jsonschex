defmodule JSONSchex.Validator.Reference do
  @moduledoc """
  Resolves `$ref` and `$dynamicRef` during validation, including external
  document loading and JIT compilation of JSON Pointer references.
  """

  alias JSONSchex.Validator
  alias JSONSchex.{Compiler, Ref}
  alias JSONSchex.URIUtil
  alias JSONSchex.Draft202012.Schemas
  alias JSONSchex.Types.ErrorContext

  @doc """
  Resolves a `$dynamicRef` by checking if the static target has a matching
  `$dynamicAnchor`, then performing dynamic scope lookup through the scope stack.
  Falls back to static `$ref` resolution if no dynamic anchor is found.
  """
  def validate_dynamic_ref(data, ref_string, {path, evaluated, validation_context} = context) do
    anchor = URIUtil.fragment(ref_string)

    static_match =
      resolve_scoped_ref(
        validation_context.source_id,
        ref_string,
        validation_context.root_schema.defs
      )

    is_dynamic_candidate =
      anchor && static_match && is_map(static_match.raw) &&
        Map.get(static_match.raw, "$dynamicAnchor") == anchor

    if is_dynamic_candidate do
      dynamic_match =
        validation_context.scope_stack
        |> Enum.reverse()
        |> Enum.find_value(fn base_uri ->
          candidate_uri = URIUtil.with_fragment(base_uri, anchor)

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
        Validator.validate_entry(dynamic_match, data, path, validation_context, evaluated)
      else
        Validator.validate_entry(static_match, data, path, validation_context, evaluated)
      end
    else
      validate_ref(data, ref_string, context)
    end
  end

  @doc """
  Resolves and validates a static `$ref`.

  Looks up the target schema in the compiled `defs` registry. If not found
  locally and the reference is external, attempts to load it using the
  `loader`.

  The loader receives the resolved document URI without the fragment. Supports
  JSON Pointer references, anchor references, and absolute/relative URIs,
  including path-like local file refs.
  """
  def validate_ref(data, ref_string, {path, evaluated, validation_context}) do
    effective_context = effective_context_for_ref(validation_context, ref_string)

    case resolve_scoped_ref(
           effective_context.source_id,
           ref_string,
           effective_context.root_schema.defs
         ) do
      nil ->
        resolve_missing_ref(data, ref_string, path, effective_context, evaluated)

      schema ->
        Validator.validate_entry(schema, data, path, effective_context, evaluated)
    end
  end

  defp effective_context_for_ref(validation_context, ref_string) do
    case built_in_defs_for_ref(validation_context.source_id, ref_string) do
      nil ->
        validation_context

      defs ->
        merge_defs_into_context(validation_context, defs)
    end
  end

  defp resolve_missing_ref(data, ref_string, path, validation_context, evaluated) do
    uri_to_load = resolve_relative_uri(validation_context.source_id, ref_string)

    with nil <- check_registry_for_base(uri_to_load, validation_context.root_schema.defs),
         :ok <-
           check_load_remote(
             validation_context.root_schema.loader,
             ref_string,
             uri_to_load
           ),
         result <- load_remote_schema(data, uri_to_load, path, validation_context, evaluated) do
      result
    else
      {:ok, base_schema, fragment} when is_map(base_schema) ->
        resolve_registry_base_match(
          data,
          ref_string,
          path,
          validation_context,
          evaluated,
          base_schema,
          fragment
        )

      :halt ->
        resolve_and_validate_jit(
          data,
          validation_context.raw,
          ref_string,
          path,
          validation_context,
          evaluated
        )

      {:error, _} = error ->
        error
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
      resolve_and_validate_jit(
        data,
        validation_context.raw,
        local_ref,
        path,
        validation_context,
        evaluated
      )
    else
      updated_context = merge_defs_into_context(validation_context, base_schema.defs)
      validate_ref(data, local_ref, {path, evaluated, updated_context})
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

  defp check_load_remote(loader, ref_string, _uri_to_load)
       when is_function(loader) do
    if Ref.external_ref?(ref_string), do: :ok, else: :halt
  end

  defp check_load_remote(_, _, _), do: :halt

  defp built_in_defs_for_ref(_, nil), do: nil

  defp built_in_defs_for_ref(base_uri, ref) do
    uri = uri_to_resolve(base_uri, ref)
    {base, _fragment} = URIUtil.split_fragment(uri)
    Schemas.compiled_defs(base)
  end

  defp resolve_scoped_ref(base_uri, ref, registry) when base_uri == ref do
    Map.get(registry, ref)
  end

  defp resolve_scoped_ref(base_uri, ref, registry) do
    uri = uri_to_resolve(base_uri, ref)
    Map.get(registry, uri) || Map.get(registry, ref)
  end

  defp uri_to_resolve(base_uri, "#" <> _ = ref) when base_uri != nil do
    URIUtil.with_fragment(base_uri, URIUtil.fragment(ref))
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

      Ref.local_ref?(ref_string) ->
        URIUtil.with_fragment(base_uri, URIUtil.fragment(ref_string))

      true ->
        case URI.parse(base_uri) do
          %{scheme: "urn"} ->
            ref_string

          %{scheme: scheme} when scheme != nil ->
            URIUtil.resolve(base_uri, ref_string)

          _ ->
            resolve_path_like_uri(base_uri, ref_string)
        end
    end
  end

  defp resolve_path_like_uri(base_uri, ref_string) do
    {ref_path, fragment} = URIUtil.split_fragment(ref_string)

    resolved_path =
      cond do
        ref_path == "" ->
          URIUtil.base(base_uri)

        String.starts_with?(ref_path, "/") ->
          ref_path

        true ->
          base_uri
          |> URIUtil.base()
          |> path_dirname()
          |> join_and_normalize(ref_path)
      end

    if fragment in [nil, ""] do
      resolved_path
    else
      resolved_path <> "#" <> fragment
    end
  end

  defp load_remote_schema(data, uri, current_path, validation_context, evaluated) do
    {base, fragment} = URIUtil.split_fragment(uri)

    case Map.get(validation_context.root_schema.defs, base) do
      nil ->
        case Schemas.compiled_defs(base) do
          built_in_defs when is_map(built_in_defs) ->
            merged_context = merge_defs_into_context(validation_context, built_in_defs)
            compiled_remote = Map.fetch!(merged_context.root_schema.defs, base)

            validate_loaded_schema(
              data,
              compiled_remote,
              fragment,
              current_path,
              merged_context,
              evaluated
            )

          nil ->
            case load_external_schema(uri, base, validation_context) do
              {:ok, compiled_remote, merged_context} ->
                validate_loaded_schema(
                  data,
                  compiled_remote,
                  fragment,
                  current_path,
                  merged_context,
                  evaluated
                )

              :halt ->
                :halt

              {:error, reason} ->
                {:error, %ErrorContext{contrast: "load_remote", input: uri, error_detail: reason}}

              _ ->
                {:error, %ErrorContext{contrast: "invalid_loader_response", input: uri}}
            end
        end

      loaded_schema ->
        updated_context = %{
          validation_context
          | source_id: loaded_schema.source_id,
            raw: loaded_schema.raw
        }

        validate_ref(
          data,
          URIUtil.local_ref(fragment),
          {current_path, evaluated, updated_context}
        )
    end
  end

  defp load_external_schema(uri, base, validation_context) do
    case validation_context.root_schema.loader do
      loader when is_function(loader) ->
        case loader.(base) do
          {:ok, remote_raw_map} ->
            opts = [
              loader: validation_context.root_schema.loader,
              base_uri: base,
              format_assertion: validation_context.root_schema.format_assertion,
              content_assertion: validation_context.root_schema.content_assertion
            ]

            case Compiler.compile(remote_raw_map, opts) do
              {:ok, compiled_remote} ->
                merged_defs = Map.put(compiled_remote.defs || %{}, base, compiled_remote)
                merged_context = merge_defs_into_context(validation_context, merged_defs)
                {:ok, compiled_remote, merged_context}

              {:error, error} ->
                {:error,
                 %ErrorContext{contrast: "compile_remote", input: uri, error_detail: error}}
            end

          other ->
            other
        end

      _ ->
        :halt
    end
  end

  defp path_dirname(path) do
    case Path.dirname(path) do
      "." -> ""
      value -> value
    end
  end

  defp join_and_normalize("", path) do
    path
    |> Path.expand("/")
    |> String.trim_leading("/")
  end

  defp join_and_normalize(base, path) do
    if String.starts_with?(base, "/") do
      Path.expand(path, base)
    else
      base
      |> then(&Path.expand(path, "/" <> &1))
      |> String.trim_leading("/")
    end
  end

  defp validate_loaded_schema(
         data,
         compiled_schema,
         fragment,
         current_path,
         validation_context,
         evaluated
       ) do
    updated_context = loaded_schema_context(validation_context, compiled_schema)

    if fragment != nil do
      validate_ref(data, URIUtil.local_ref(fragment), {current_path, evaluated, updated_context})
    else
      Validator.validate_entry(compiled_schema, data, current_path, updated_context, evaluated)
    end
  end

  defp loaded_schema_context(validation_context, compiled_schema) do
    new_stack =
      if compiled_schema.source_id do
        [compiled_schema.source_id | validation_context.scope_stack]
      else
        validation_context.scope_stack
      end

    %{
      validation_context
      | scope_stack: new_stack,
        source_id: compiled_schema.source_id,
        raw: compiled_schema.raw
    }
  end

  defp resolve_and_validate_jit(
         data,
         raw_root,
         pointer,
         current_path,
         validation_context,
         evaluated
       ) do
    case resolve_jit_fragment(raw_root, pointer, validation_context) do
      {:ok, found_fragment} ->
        opts = [
          loader: validation_context.root_schema.loader,
          format_assertion: validation_context.root_schema.format_assertion,
          content_assertion: validation_context.root_schema.content_assertion
        ]

        case Compiler.compile(found_fragment, opts) do
          {:ok, compiled_fragment} ->
            Validator.validate_entry(
              compiled_fragment,
              data,
              current_path,
              validation_context,
              evaluated
            )

          {:error, error} ->
            {:error,
             %ErrorContext{contrast: "invalid_schema", input: pointer, error_detail: error}}
        end

      {:error, _token} ->
        {:error, %ErrorContext{contrast: "ref_not_found", input: pointer}}
    end
  end

  defp resolve_jit_fragment(raw_root, "#/" <> _ = pointer, validation_context) do
    case Ref.resolve(raw_root, pointer,
           source: validation_context.source_id,
           base_uri: validation_context.source_id
         ) do
      {:ok, %Ref.Resolution{target_value: found_fragment}} ->
        {:ok, found_fragment}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp resolve_jit_fragment(raw_root, pointer, _validation_context) do
    ExJSONPointer.resolve(raw_root, pointer)
  end
end

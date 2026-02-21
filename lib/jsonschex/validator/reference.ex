defmodule JSONSchex.Validator.Reference do
  @moduledoc """
  Resolves `$ref` and `$dynamicRef` during validation, including remote schema
  loading and JIT compilation of JSON Pointer references.
  """

  alias JSONSchex.Validator
  alias JSONSchex.Compiler
  alias JSONSchex.URIUtil
  alias JSONSchex.Types.ErrorContext

  @doc """
  Resolves a `$dynamicRef` by checking if the static target has a matching
  `$dynamicAnchor`, then performing dynamic scope lookup through the scope stack.
  Falls back to static `$ref` resolution if no dynamic anchor is found.
  """
  def validate_dynamic_ref(data, ref_string, {path, evaluated, validation_context} = context) do
    anchor =
      case String.split(ref_string, "#", parts: 2) do
        [_, a] when a != "" -> a
        _ -> nil
      end

    static_match = resolve_scoped_ref(validation_context.source_id, ref_string, validation_context.root_schema.defs)

    is_dynamic_candidate =
      anchor && static_match && is_map(static_match.raw) && Map.get(static_match.raw, "$dynamicAnchor") == anchor

    if is_dynamic_candidate do
      dynamic_match =
        validation_context.scope_stack
        |> Enum.reverse()
        |> Enum.find_value(fn base_uri ->
          candidate_uri = URIUtil.resolve(base_uri, "#" <> anchor)

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

  Looks up the target schema in the compiled `defs` registry. If not found locally
  and the reference points to a remote URI, attempts to load it using the `external_loader`.
  Supports JSON Pointer references, anchor references, and absolute/relative URIs.
  """
  def validate_ref(data, ref_string, {path, evaluated, validation_context}) do
    schema_match = resolve_scoped_ref(validation_context.source_id, ref_string, validation_context.root_schema.defs)

    case schema_match do
      nil ->
        uri_to_load = resolve_relative_uri(validation_context.source_id, ref_string)

        with nil <- check_registry_for_base(uri_to_load, validation_context.root_schema.defs),
             :ok <- check_load_remote(validation_context.root_schema.external_loader, uri_to_load),
             result <- load_remote_schema(data, uri_to_load, path, validation_context, evaluated) do
          result
        else
          {base_schema, fragment} when is_map(base_schema) ->
            updated_context = merge_defs_into_context(validation_context, base_schema.defs)
            validate_ref(data, "#" <> fragment, {path, evaluated, updated_context})

          :halt ->
            resolve_and_validate_jit(data, validation_context.raw, ref_string, path, validation_context, evaluated)

          {:error, _} = error ->
            error
        end

      schema ->
        Validator.validate_entry(schema, data, path, validation_context, evaluated)
    end
  end

  defp merge_defs_into_context(validation_context, new_defs) when is_map(new_defs) do
    merged_defs = Map.merge(validation_context.root_schema.defs, new_defs)
    updated_root = %{validation_context.root_schema | defs: merged_defs}
    %{validation_context | root_schema: updated_root}
  end

  defp check_registry_for_base(uri, registry) do
    case String.split(uri, "#", parts: 2) do
      [base, fragment] ->
        case Map.get(registry, base) do
          nil ->
            nil
          schema ->
            {schema, fragment}
        end
      _ ->
        nil
    end
  end

  defp check_load_remote(external_loader, uri_to_load) when is_function(external_loader) do
    if URIUtil.remote_ref?(uri_to_load), do: :ok, else: :halt
  end
  defp check_load_remote(_, _), do: :halt

  defp resolve_scoped_ref(base_uri, ref, registry) when base_uri == ref do
    Map.get(registry, ref)
  end
  defp resolve_scoped_ref(base_uri, ref, registry) do
    cond do
      base_uri && String.starts_with?(ref, "#") ->
        full_uri = base_uri <> ref
        Map.get(registry, full_uri) || Map.get(registry, ref)

      base_uri ->
        resolved = resolve_relative_uri(base_uri, ref)
        if resolved, do: Map.get(registry, resolved), else: nil

      base_uri == nil and ref != nil ->
        Map.get(registry, ref)

      true ->
        nil
    end
  end

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
          %{scheme: scheme} when scheme != nil ->
            URIUtil.resolve(base_uri, ref_string)
          _ ->
            ref_string
        end
    end
  end

  defp load_remote_schema(data, uri, current_path, validation_context, evaluated) do
    {base, fragment} =
      case String.split(uri, "#", parts: 2) do
        [base, ""] ->
          {base, nil}
        [base, fragment] ->
          {base, fragment}
        [base] ->
          {base, nil}
      end

    loaded_schema = Map.get(validation_context.root_schema.defs, base)
    if loaded_schema do
      updated_context = %{validation_context |
        source_id: loaded_schema.source_id,
        raw: loaded_schema.raw
      }
      local_ref = if fragment, do: "#" <> fragment, else: "#"
      validate_ref(data, local_ref, {current_path, evaluated, updated_context})
    else
      case validation_context.root_schema.external_loader.(uri) do
        {:ok, remote_raw_map} ->
          opts = [
            external_loader: validation_context.root_schema.external_loader,
            base_uri: base,
            format_assertion: validation_context.root_schema.format_assertion,
            content_assertion: validation_context.root_schema.content_assertion
          ]
          case Compiler.compile(remote_raw_map, opts) do
            {:ok, compiled_remote} ->
              new_stack =
                if compiled_remote.source_id do
                  [compiled_remote.source_id | validation_context.scope_stack]
                else
                  validation_context.scope_stack
                end

              merged_context = merge_defs_into_context(validation_context, compiled_remote.defs || %{})
              updated_context = %{merged_context |
                scope_stack: new_stack,
                source_id: compiled_remote.source_id,
                raw: compiled_remote.raw
              }

              if fragment != nil do
                validate_ref(data, "#" <> fragment, {current_path, evaluated, updated_context})
              else
                Validator.validate_entry(compiled_remote, data, current_path, updated_context, evaluated)
              end

            {:error, error} ->
              {:error, %ErrorContext{contrast: "compile_remote", input: uri, error_detail: error}}
          end
        :halt ->
          :halt
        {:error, reason} ->
          {:error, %ErrorContext{contrast: "load_remote", input: uri, error_detail: reason}}
        _ ->
          {:error, %ErrorContext{contrast: "invalid_loader_response", input: uri}}
      end
    end
  end

  defp resolve_and_validate_jit(data, raw_root, pointer, current_path, validation_context, evaluated) do
    case ExJSONPointer.resolve(raw_root, pointer) do
      {:ok, found_fragment} ->
        opts = [
          external_loader: validation_context.root_schema.external_loader,
          format_assertion: validation_context.root_schema.format_assertion,
          content_assertion: validation_context.root_schema.content_assertion
        ]
        case Compiler.compile(found_fragment, opts) do
          {:ok, compiled_fragment} ->
            Validator.validate_entry(compiled_fragment, data, current_path, validation_context, evaluated)

          {:error, error} ->
            {:error, %ErrorContext{contrast: "invalid_schema", input: pointer, error_detail: error}}
        end

      {:error, _token} ->
        {:error, %ErrorContext{contrast: "ref_not_found", input: pointer}}
    end
  end
end

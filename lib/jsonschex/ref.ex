defmodule JSONSchex.Ref do
  @moduledoc """
  Generic selected `$ref` resolver for JSON-like documents.

  `resolve_selected/2` walks maps and lists and resolves only `$ref` nodes that
  the caller selects. This keeps domain-specific knowledge (for example,
  OpenAPI Reference Object locations) outside JSONSchex while reusing the same
  low-level reference mechanics as JSON Schema: URI resolution, JSON Pointer
  lookup, external loading, base URI propagation, and cycle detection.
  """

  alias JSONSchex.URIUtil

  defmodule Error do
    @moduledoc """
    Error returned by `JSONSchex.Ref.resolve_selected/2`.

    Fields:

    - `:kind` — machine-readable error kind
    - `:path` — path to the selected node containing `$ref`
    - `:ref` — original `$ref` value when available
    - `:uri` — resolved URI/reference when available
    - `:reason` — loader, pointer, or validation detail
    """

    @type kind ::
            :missing_select
            | :invalid_select
            | :invalid_ref_value
            | :missing_base_uri
            | :missing_loader
            | :missing_external_document
            | :missing_target
            | :cycle_detected
            | :invalid_loader_response

    @type t :: %__MODULE__{
            kind: kind(),
            path: list(),
            ref: term(),
            uri: String.t() | nil,
            reason: term()
          }

    defexception [:kind, path: [], ref: nil, uri: nil, reason: nil]

    @impl true
    def message(%__MODULE__{} = error) do
      details =
        [
          if(error.path != [], do: "path=#{inspect(error.path)}", else: nil),
          if(error.ref != nil, do: "ref=#{inspect(error.ref)}", else: nil),
          if(error.uri != nil, do: "uri=#{inspect(error.uri)}", else: nil),
          if(error.reason != nil, do: "reason=#{inspect(error.reason)}", else: nil)
        ]
        |> Enum.reject(&is_nil/1)

      base = "selected ref resolution failed (#{error.kind})"
      if details == [], do: base, else: base <> ": " <> Enum.join(details, ", ")
    end
  end

  @type loader_result ::
          {:ok, map() | boolean()}
          | {:ok, %{required(:document) => map() | boolean(), optional(:base_uri) => String.t()}}
          | {:error, term()}

  @type loader :: (String.t() -> loader_result())
  @type selector :: (list(), map() -> boolean())

  @doc """
  Resolves selected `$ref` nodes in a JSON-like document.

  ## Options

  - `:select` — required `(path, node -> boolean())` callback. `path` points to
    the map containing `$ref`, not to the `$ref` key.
  - `:base_uri` — optional starting base URI/path for resolving relative
    external references.
  - `:loader` — optional loader for external resources.

  Selected `$ref` nodes are replaced by the resolved target value. Unselected
  `$ref` nodes are preserved and are not interpreted as references. When an
  external selected target is inlined, nested unselected `$ref` string values are
  rebased against the loaded resource's effective base URI so they continue to
  point at their original resource.

  ## Examples

  Resolve only the selected local `$ref` node:

      iex> document = %{
      ...>   "parameter" => %{"$ref" => "#/components/parameters/UserId"},
      ...>   "schema" => %{"$ref" => "#/components/schemas/User"},
      ...>   "components" => %{
      ...>     "parameters" => %{"UserId" => %{"name" => "id", "in" => "path"}},
      ...>     "schemas" => %{"User" => %{"type" => "object"}}
      ...>   }
      ...> }
      iex> select = fn
      ...>   ["parameter"], %{"$ref" => _} -> true
      ...>   _path, _node -> false
      ...> end
      iex> {:ok, resolved} = JSONSchex.Ref.resolve_selected(document, select: select)
      iex> resolved["parameter"]
      %{"in" => "path", "name" => "id"}
      iex> resolved["schema"]
      %{"$ref" => "#/components/schemas/User"}

  Resolve a selected external `$ref` with a loader:

      iex> document = %{"parameter" => %{"$ref" => "./common.yaml#/components/parameters/UserId"}}
      iex> loader = fn "/api/common.yaml" ->
      ...>   {:ok, %{"components" => %{"parameters" => %{"UserId" => %{"name" => "id", "in" => "path"}}}}}
      ...> end
      iex> {:ok, resolved} = JSONSchex.Ref.resolve_selected(document,
      ...>   base_uri: "/api/openapi.yaml",
      ...>   loader: loader,
      ...>   select: fn _path, %{"$ref" => _} -> true; _path, _node -> false end
      ...> )
      iex> resolved["parameter"]
      %{"in" => "path", "name" => "id"}
  """
  @spec resolve_selected(term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def resolve_selected(document, opts) when is_list(opts) do
    with {:ok, select} <- fetch_select(opts) do
      base_uri = Keyword.get(opts, :base_uri)

      state = %{
        select: select,
        loader: Keyword.get(opts, :loader),
        cache: %{}
      }

      case walk(document, [], document, base_uri, nil, state, []) do
        {:ok, resolved, _state} -> {:ok, resolved}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  def resolve_selected(_document, _opts) do
    {:error, error(:invalid_select, [], nil, nil, "options must be a keyword list")}
  end

  defp fetch_select(opts) do
    case Keyword.get(opts, :select) do
      select when is_function(select, 2) -> {:ok, select}
      nil -> {:error, error(:missing_select, [], nil, nil, "expected :select option")}
      other -> {:error, error(:invalid_select, [], nil, nil, {:expected_arity_2_function, other})}
    end
  end

  defp walk(%{"$ref" => _} = node, path, resource_document, current_base_uri, rebase_base_uri, state, stack) do
    if state.select.(Enum.reverse(path), node) do
      resolve_selected_node(node, path, resource_document, current_base_uri, rebase_base_uri, state, stack)
    else
      {:ok, rebase_unselected_ref(node, rebase_base_uri), state}
    end
  end

  defp walk(%{} = node, path, resource_document, current_base_uri, rebase_base_uri, state, stack) do
    walk_map(node, path, resource_document, current_base_uri, rebase_base_uri, state, stack)
  end

  defp walk(list, path, resource_document, current_base_uri, rebase_base_uri, state, stack) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], state}, fn {value, index}, {:ok, acc, state} ->
      case walk(value, [index | path], resource_document, current_base_uri, rebase_base_uri, state, stack) do
        {:ok, resolved_value, state} -> {:cont, {:ok, [resolved_value | acc], state}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, reversed, state} -> {:ok, Enum.reverse(reversed), state}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp walk(value, _path, _resource_document, _current_base_uri, _rebase_base_uri, state, _stack) do
    {:ok, value, state}
  end

  defp walk_map(node, path, resource_document, current_base_uri, rebase_base_uri, state, stack) do
    Enum.reduce_while(node, {:ok, %{}, state}, fn {key, value}, {:ok, acc, state} ->
      case walk(value, [key | path], resource_document, current_base_uri, rebase_base_uri, state, stack) do
        {:ok, resolved_value, state} -> {:cont, {:ok, Map.put(acc, key, resolved_value), state}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_selected_node(
         %{"$ref" => ref},
         path,
         resource_document,
         current_base_uri,
         rebase_base_uri,
         state,
         stack
       )
       when is_binary(ref) do
    with {:ok, resolved_uri} <- resolve_ref_uri(ref, path, current_base_uri),
         {:ok, target, target_base, fragment, state} <-
           resolve_target(ref, resolved_uri, path, resource_document, current_base_uri, state),
         target_uri <- target_uri(target_base, resolved_uri, fragment),
         :ok <- check_cycle(target_uri, ref, path, stack),
         {:ok, resolved_target, state} <-
           walk(
             target,
             path,
             target_resource_document(target, target_base, state, resource_document),
             target_base,
             target_rebase_base_uri(rebase_base_uri, current_base_uri, target_base),
             state,
             [target_uri | stack]
           ) do
      {:ok, resolved_target, state}
    end
  end

  defp resolve_selected_node(
         %{"$ref" => ref},
         path,
         _resource_document,
         _current_base_uri,
         _rebase_base_uri,
         _state,
         _stack
       ) do
    {:error, error(:invalid_ref_value, path, ref, nil, "selected $ref value must be a string")}
  end

  defp rebase_unselected_ref(%{"$ref" => ref} = node, rebase_base_uri)
       when is_binary(ref) and is_binary(rebase_base_uri) do
    Map.put(node, "$ref", URIUtil.resolve(rebase_base_uri, ref))
  end

  defp rebase_unselected_ref(node, _rebase_base_uri), do: node

  defp target_rebase_base_uri(nil, current_base_uri, target_base) when target_base == current_base_uri, do: nil
  defp target_rebase_base_uri(_rebase_base_uri, _current_base_uri, target_base), do: target_base

  defp resolve_ref_uri(ref, path, nil) do
    if relative_external_ref?(ref) do
      {:error, error(:missing_base_uri, path, ref, nil, "selected external relative ref requires :base_uri")}
    else
      {:ok, ref}
    end
  end

  defp resolve_ref_uri(ref, _path, current_base_uri), do: {:ok, URIUtil.resolve(current_base_uri, ref)}

  defp relative_external_ref?(ref) do
    {base, _fragment} = URIUtil.split_fragment(ref)

    cond do
      base == "" -> false
      URI.parse(base).scheme != nil -> false
      String.starts_with?(base, "/") -> false
      true -> true
    end
  end

  defp resolve_target(ref, resolved_uri, path, resource_document, current_base_uri, state) do
    {base, fragment} = URIUtil.split_fragment(resolved_uri)

    if local_base?(base, current_base_uri) do
      resolve_pointer(resource_document, ref, resolved_uri, fragment, path)
      |> case do
        {:ok, target} -> {:ok, target, current_base_uri, fragment, state}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      with {:ok, external_document, external_base_uri, state} <- load_external(base, ref, resolved_uri, path, state),
           {:ok, target} <- resolve_pointer(external_document, ref, URIUtil.with_fragment(external_base_uri, fragment), fragment, path) do
        {:ok, target, external_base_uri, fragment, state}
      end
    end
  end

  defp local_base?("", _current_base_uri), do: true
  defp local_base?(base, current_base_uri) when is_binary(base), do: base == current_base_uri

  defp resolve_pointer(document, ref, uri, fragment, path) do
    pointer = URIUtil.local_ref(fragment)

    case ExJSONPointer.resolve(document, pointer) do
      {:ok, target} ->
        {:ok, target}

      {:error, reason} ->
        {:error, error(:missing_target, path, ref, uri, reason)}
    end
  end

  defp load_external(base, ref, uri, path, state) do
    case Map.get(state.cache, base) do
      {document, effective_base} ->
        {:ok, document, effective_base, state}

      nil ->
        do_load_external(base, ref, uri, path, state)
    end
  end

  defp do_load_external(base, ref, uri, path, %{loader: loader} = state) when is_function(loader, 1) do
    case loader.(base) do
      {:ok, %{document: document} = loaded} when is_map(document) or is_boolean(document) ->
        effective_base = base_uri_or_original(Map.get(loaded, :base_uri), base)
        cache = state.cache |> Map.put(base, {document, effective_base}) |> Map.put(effective_base, {document, effective_base})
        {:ok, document, effective_base, %{state | cache: cache}}

      {:ok, document} when is_map(document) or is_boolean(document) ->
        cache = Map.put(state.cache, base, {document, base})
        {:ok, document, base, %{state | cache: cache}}

      {:error, reason} ->
        {:error, error(:missing_external_document, path, ref, uri, reason)}

      other ->
        {:error, error(:invalid_loader_response, path, ref, uri, other)}
    end
  end

  defp do_load_external(_base, ref, uri, path, state) do
    if is_nil(state.loader) do
      {:error, error(:missing_loader, path, ref, uri, "selected external ref requires :loader")}
    else
      {:error, error(:invalid_loader_response, path, ref, uri, state.loader)}
    end
  end

  defp base_uri_or_original(base_uri, _original_base) when is_binary(base_uri), do: base_uri
  defp base_uri_or_original(_base_uri, original_base), do: original_base

  defp target_uri(nil, resolved_uri, _fragment), do: resolved_uri
  defp target_uri(target_base_uri, _resolved_uri, fragment) do
    URIUtil.with_fragment(target_base_uri, fragment)
  end

  defp check_cycle(uri, ref, path, stack) do
    if uri in stack do
      {:error, error(:cycle_detected, path, ref, uri, "selected ref cycle detected")}
    else
      :ok
    end
  end

  defp target_resource_document(_target, target_base, %{cache: cache}, fallback_document) do
    case Map.get(cache, target_base) do
      {document, _effective_base} -> document
      nil -> fallback_document
    end
  end

  defp error(kind, path, ref, uri, reason) do
    %Error{kind: kind, path: path, ref: ref, uri: uri, reason: reason}
  end
end

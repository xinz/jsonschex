defmodule JSONSchex.Ref do
  @moduledoc """
  Structural `$ref` discovery and resolution helpers.

  This module exposes low-level, policy-free building blocks for downstream
  tooling that needs to inspect or resolve references before schema
  compilation.

  Unlike `JSONSchex.compile/2`, this API does **not** rewrite documents,
  interpret OpenAPI-specific behavior, or apply merge policy. It focuses on the
  mechanical side of references:

  - structurally scanning nested maps and lists for `$ref` entries
  - tracking the effective base URI at each location, honoring nested `$id`
  - resolving local JSON Pointer and anchor references
  - resolving external references through a caller-provided loader
  - traversing the transitive `$ref` graph with cycle detection
  - preserving source metadata for downstream diagnostics

  See the [Structural `$ref` guide](guide/ref.md) for a longer walkthrough.

  ## Main entry points

  - `scan/2` returns `%Location{}` values for every structural `$ref`
  - `resolve/3` resolves one location or raw ref string into a `%Resolution{}`
  - `walk/2` performs a depth-first transitive traversal and returns ordered
    `%Resolution{}`, `%Error{}`, and `%Cycle{}` events

  ## Options

  - `:source` — source identifier for the root document. This is primarily
    provenance metadata for returned `%Location{}`, `%Resolution{}`, `%Error{}`,
    and `%Cycle{}` values.
  - `:base_uri` — explicit starting base URI override used for reference
    resolution.
  - `:loader` — `(document_uri -> {:ok, document} | {:ok, %{document: document, source: source}} | {:error, term()})`
  - `:external_loader` — accepted as an alias for `:loader`

  If `:base_uri` is omitted and `:source` is a binary, `:source` is also used
  as the initial base URI. This is convenient when the source path or URI is
  both the document identifier and the desired reference base.

  When resolving a bare reference string, resolution starts from the root
  document context. To preserve nested `$id` scope, prefer passing a scanned
  `%Location{}` into `resolve/3`.

  ## Example

      iex> document = %{
      ...>   "$id" => "https://example.com/root.json",
      ...>   "$defs" => %{
      ...>     "user" => %{
      ...>       "$id" => "schemas/user.json",
      ...>       "$defs" => %{"name" => %{"type" => "string"}},
      ...>       "schema" => %{"$ref" => "#/$defs/name"}
      ...>     }
      ...>   }
      ...> }
      iex> [location] = JSONSchex.Ref.scan(document)
      iex> location.absolute_uri
      "https://example.com/schemas/user.json#/$defs/name"
      iex> {:ok, resolution} = JSONSchex.Ref.resolve(document, location, base_uri: "https://example.com/root.json")
      iex> resolution.target_value
      %{"type" => "string"}
  """

  alias JSONSchex.Draft202012.Schemas
  alias JSONSchex.URIUtil

  @type path_segment :: String.t() | non_neg_integer()
  @type path :: [path_segment]
  @type source :: term()
  @type document :: map() | list() | boolean()

  @typedoc "A document loader used for external reference resolution."
  @type loader_result ::
          {:ok, document()}
          | {:ok, %{required(:document) => document(), optional(:source) => source()}}
          | {:error, term()}

  @type loader :: (String.t() -> loader_result())

  defmodule Location do
    @moduledoc """
    A discovered `$ref` location.

    The `path` is reported from the root of the scanned document to the `$ref`
    key itself.
    """

    @enforce_keys [:raw_ref, :path]
    defstruct [
      :raw_ref,
      :path,
      :source,
      :base_uri,
      :absolute_uri,
      :fragment
    ]

    @type t :: %__MODULE__{
            raw_ref: String.t(),
            path: JSONSchex.Ref.path(),
            source: JSONSchex.Ref.source() | nil,
            base_uri: String.t() | nil,
            absolute_uri: String.t() | nil,
            fragment: String.t() | nil
          }
  end

  defmodule Resolution do
    @moduledoc """
    The result of resolving a single `$ref` location.

    `target_document` is the resolved target resource root. For embedded
    resources introduced by nested `$id`, this is the local subschema/resource
    rather than the original root document.
    """

    @enforce_keys [:location, :target_source, :target_document, :target_value]
    defstruct [
      :location,
      :target_uri,
      :target_source,
      :target_document,
      :target_value,
      :target_pointer
    ]

    @type t :: %__MODULE__{
            location: JSONSchex.Ref.Location.t(),
            target_uri: String.t() | nil,
            target_source: JSONSchex.Ref.source() | nil,
            target_document: JSONSchex.Ref.document(),
            target_value: term(),
            target_pointer: String.t() | nil
          }
  end

  defmodule Error do
    @moduledoc """
    Structured ref resolution error.
    """

    @enforce_keys [:kind]
    defstruct [
      :kind,
      :location,
      :target_uri,
      :details
    ]

    @type kind :: :invalid_ref | :missing_document | :missing_target | :invalid_loader_response

    @type t :: %__MODULE__{
            kind: kind(),
            location: JSONSchex.Ref.Location.t() | nil,
            target_uri: String.t() | nil,
            details: term()
          }
  end

  defmodule Cycle do
    @moduledoc """
    A cycle detected while transitively walking `$ref` targets.
    """

    @enforce_keys [:location, :target_uri, :trail]
    defstruct [
      :location,
      :target_uri,
      :trail
    ]

    @type t :: %__MODULE__{
            location: JSONSchex.Ref.Location.t(),
            target_uri: String.t(),
            trail: [String.t()]
          }
  end

  @typedoc "Ordered event emitted by `walk/2`."
  @type walk_event :: Resolution.t() | Error.t() | Cycle.t()

  @doc """
  Recursively scans a document for `$ref` locations.

  The traversal is structural: nested maps and lists are walked regardless of
  keyword meaning.

  Nested `$id` values update the effective `base_uri` recorded on each returned
  `%Location{}`.

  ## Example

      iex> document = %{
      ...>   "$id" => "https://example.com/root.json",
      ...>   "child" => %{
      ...>     "$id" => "schemas/user.json",
      ...>     "schema" => %{"$ref" => "#/$defs/name"}
      ...>   }
      ...> }
      iex> [location] = JSONSchex.Ref.scan(document)
      iex> location.path
      ["child", "schema", "$ref"]
      iex> location.base_uri
      "https://example.com/schemas/user.json"
  """
  @spec scan(document(), keyword()) :: [Location.t()]
  def scan(document, opts \\ [])
      when is_map(document) or is_list(document) or is_boolean(document) do
    source = Keyword.get(opts, :source)
    base_uri = initial_base_uri(opts, source)

    document
    |> do_scan([], source, base_uri, [])
    |> Enum.reverse()
  end

  @doc """
  Resolves a single `$ref` from the given document context.

  Passing a scanned `%Location{}` preserves nested `$id` scope. Passing a raw
  reference string resolves from the root document context derived from `opts`.

  External documents are loaded through `:loader` or `:external_loader`. The
  loader receives the resolved document URI without the fragment and may return
  either a document directly or `%{document: document, source: source}`.

  ## Example

      iex> document = %{
      ...>   "$defs" => %{"name" => %{"type" => "string"}},
      ...>   "schema" => %{"$ref" => "#/$defs/name"}
      ...> }
      iex> [location] = JSONSchex.Ref.scan(document)
      iex> {:ok, resolution} = JSONSchex.Ref.resolve(document, location)
      iex> resolution.target_pointer
      "#/$defs/name"
      iex> resolution.target_value
      %{"type" => "string"}
  """
  @spec resolve(document(), String.t() | Location.t(), keyword()) ::
          {:ok, Resolution.t()} | {:error, Error.t()}
  def resolve(document, ref_or_location, opts \\ [])

  def resolve(document, %Location{} = location, opts)
      when is_map(document) or is_list(document) or is_boolean(document) do
    {result, _cache} = resolve_location(document, location, opts, %{})
    result
  end

  def resolve(document, ref, opts)
      when (is_map(document) or is_list(document) or is_boolean(document)) and is_binary(ref) do
    source = Keyword.get(opts, :source)
    root_base_uri = initial_base_uri(opts, source)

    location =
      normalize_location(
        %Location{raw_ref: ref, path: [], source: source, base_uri: root_base_uri},
        source,
        root_base_uri
      )

    resolve(document, location, opts)
  end

  def resolve(_document, _ref_or_location, _opts) do
    {:error, %Error{kind: :invalid_ref, details: :expected_binary_ref_or_location}}
  end

  @doc """
  Transitively walks reachable `$ref` targets in depth-first order.

  The returned event list contains:

  - `%Resolution{}` for each successfully resolved location
  - `%Error{}` for each location that failed to resolve
  - `%Cycle{}` when a resolved target would recurse into an already-active trail

  Shared targets are only expanded once, but every location still produces its
  own `%Resolution{}` event.

  This function is inspection-oriented rather than fail-fast: successful edges,
  missing targets, and cycles are all returned in the same ordered result.

  ## Example

      iex> document = %{
      ...>   "$id" => "https://example.com/root.json",
      ...>   "$defs" => %{
      ...>     "a" => %{"$ref" => "#/$defs/b"},
      ...>     "b" => %{"$ref" => "#/$defs/a"}
      ...>   },
      ...>   "start" => %{"$ref" => "#/$defs/a"}
      ...> }
      iex> {:ok, events} = JSONSchex.Ref.walk(document, base_uri: "https://example.com/root.json")
      iex> Enum.any?(events, &match?(%JSONSchex.Ref.Cycle{}, &1))
      true
  """
  @spec walk(document(), keyword()) :: {:ok, [walk_event()]}
  def walk(document, opts \\ [])
      when is_map(document) or is_list(document) or is_boolean(document) do
    source = Keyword.get(opts, :source)
    base_uri = initial_base_uri(opts, source)
    loader = loader_from_opts(opts)

    state = %{
      events: [],
      active: MapSet.new(),
      expanded: MapSet.new(),
      seen_locations: MapSet.new(),
      cache: %{}
    }

    state = walk_document(document, document, source, base_uri, loader, state, [], [])

    {:ok, Enum.reverse(state.events)}
  end

  defp resolve_location(document, %Location{} = location, opts, cache) do
    source = location.source || Keyword.get(opts, :source)
    root_base_uri = initial_base_uri(opts, source)
    loader = loader_from_opts(opts)

    location = normalize_location(location, source, root_base_uri)
    index = build_index(document, source, root_base_uri)

    case resolve_target(index, location, loader, cache) do
      {:ok, target, updated_cache} ->
        {{:ok, build_resolution(location, target)}, updated_cache}

      {:error, %Error{} = error, updated_cache} ->
        {{:error, error}, updated_cache}
    end
  end

  defp walk_document(
         scan_document,
         resolve_document,
         source,
         base_uri,
         loader,
         state,
         trail,
         path_prefix
       ) do
    scan(scan_document, source: source, base_uri: base_uri)
    |> Enum.reduce(state, fn location, acc_state ->
      location = prefix_location_path(location, path_prefix)
      seen? = seen_location?(acc_state, location)
      acc_state = if seen?, do: acc_state, else: mark_seen_location(acc_state, location)

      opts = [source: source, base_uri: base_uri, loader: loader]
      {result, cache} = resolve_location(resolve_document, location, opts, acc_state.cache)
      acc_state = %{acc_state | cache: cache}

      case result do
        {:error, %Error{} = error} ->
          if seen?, do: acc_state, else: push_event(acc_state, error)

        {:ok, %Resolution{} = resolution} ->
          acc_state = if seen?, do: acc_state, else: push_event(acc_state, resolution)
          maybe_walk_resolution(acc_state, resolution, loader, trail)
      end
    end)
  end

  defp maybe_walk_resolution(state, %Resolution{} = resolution, loader, trail) do
    target_uri = resolution.target_uri

    cond do
      not walkable_document?(resolution.target_value) ->
        state

      not is_binary(target_uri) ->
        state

      MapSet.member?(state.active, target_uri) ->
        push_event(state, %Cycle{
          location: resolution.location,
          target_uri: target_uri,
          trail: Enum.reverse([target_uri | trail])
        })

      same_source_resource_root?(resolution) ->
        state

      MapSet.member?(state.expanded, target_uri) ->
        state

      true ->
        next_state = %{state | active: MapSet.put(state.active, target_uri)}

        next_state =
          walk_document(
            resolution.target_value,
            resolution.target_document,
            resolution.target_source,
            next_base_uri(resolution),
            loader,
            next_state,
            [target_uri | trail],
            path_prefix_from_resolution(resolution)
          )

        %{
          next_state
          | active: MapSet.delete(next_state.active, target_uri),
            expanded: MapSet.put(next_state.expanded, target_uri)
        }
    end
  end

  defp push_event(state, event) do
    %{state | events: [event | state.events]}
  end

  defp prefix_location_path(%Location{} = location, []), do: location

  defp prefix_location_path(%Location{} = location, prefix) when is_list(prefix) do
    %{location | path: prefix ++ location.path}
  end

  defp seen_location?(state, %Location{} = location) do
    MapSet.member?(state.seen_locations, location_key(location))
  end

  defp mark_seen_location(state, %Location{} = location) do
    %{state | seen_locations: MapSet.put(state.seen_locations, location_key(location))}
  end

  defp location_key(%Location{} = location) do
    {location.source, location.base_uri, location.path, location.absolute_uri}
  end

  defp path_prefix_from_resolution(%Resolution{target_pointer: target_pointer}) do
    pointer_to_path(target_pointer)
  end

  defp same_source_resource_root?(%Resolution{} = resolution) do
    resolution.target_value === resolution.target_document and
      resolution.target_source == resolution.location.source
  end

  defp next_base_uri(%Resolution{target_uri: target_uri, target_source: target_source}) do
    cond do
      is_binary(target_uri) ->
        base_of(target_uri)

      is_binary(target_source) ->
        target_source

      true ->
        nil
    end
  end

  defp walkable_document?(value) when is_map(value) or is_list(value) or is_boolean(value),
    do: true

  defp walkable_document?(_), do: false

  defp build_resolution(location, target) do
    %Resolution{
      location: location,
      target_uri: location.absolute_uri,
      target_source: target.source,
      target_document: target.document,
      target_value: target.value,
      target_pointer: target.pointer
    }
  end

  defp normalize_location(%Location{} = location, source, root_base_uri) do
    base_uri = location.base_uri || root_base_uri
    absolute_uri = location.absolute_uri || resolve_reference(base_uri, location.raw_ref)

    %Location{
      location
      | source: location.source || source,
        base_uri: base_uri,
        absolute_uri: absolute_uri,
        fragment: location.fragment || fragment_of(absolute_uri || location.raw_ref)
    }
  end

  defp do_scan(value, _path, _source, _base_uri, acc)
       when is_boolean(value) or is_binary(value) or is_number(value) or is_nil(value),
       do: acc

  defp do_scan(list, path, source, base_uri, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {item, index}, inner_acc ->
      do_scan(item, path ++ [index], source, base_uri, inner_acc)
    end)
  end

  defp do_scan(map, path, source, base_uri, acc) when is_map(map) do
    effective_base_uri = effective_base_uri(base_uri, map)

    acc =
      case Map.get(map, "$ref") do
        ref when is_binary(ref) ->
          absolute_uri = resolve_reference(effective_base_uri, ref)

          [
            %Location{
              raw_ref: ref,
              path: path ++ ["$ref"],
              source: source,
              base_uri: effective_base_uri,
              absolute_uri: absolute_uri,
              fragment: fragment_of(absolute_uri || ref)
            }
            | acc
          ]

        _ ->
          acc
      end

    map
    |> Enum.sort_by(&sort_entry/1)
    |> Enum.reduce(acc, fn {key, value}, inner_acc ->
      do_scan(value, path ++ [key], source, effective_base_uri, inner_acc)
    end)
  end

  defp build_index(document, source, base_uri) do
    index = %{resources: %{}, anchors: %{}}

    do_build_index(document, [], source, base_uri, document, index)
  end

  defp do_build_index(value, path, source, base_uri, _resource_document, index)
       when is_boolean(value) do
    resource_key = resource_key(base_uri)

    if path == [] do
      put_resource(index, resource_key, %{
        base_uri: resource_key,
        document: value,
        path: path,
        source: source
      })
    else
      index
    end
  end

  defp do_build_index(value, _path, _source, _base_uri, _resource_document, index)
       when is_binary(value) or is_number(value) or is_nil(value),
       do: index

  defp do_build_index(list, path, source, base_uri, resource_document, index)
       when is_list(list) do
    resource_document = if path == [], do: list, else: resource_document

    index =
      if path == [] do
        put_resource(index, resource_key(base_uri), %{
          base_uri: resource_key(base_uri),
          document: resource_document,
          path: path,
          source: source
        })
      else
        index
      end

    list
    |> Enum.with_index()
    |> Enum.reduce(index, fn {item, index_value}, inner_index ->
      do_build_index(
        item,
        path ++ [index_value],
        source,
        base_uri,
        resource_document,
        inner_index
      )
    end)
  end

  defp do_build_index(map, path, source, base_uri, resource_document, index) when is_map(map) do
    effective_base_uri = effective_base_uri(base_uri, map)

    resource_document =
      if path == [] or is_binary(Map.get(map, "$id")), do: map, else: resource_document

    index =
      if path == [] or is_binary(Map.get(map, "$id")) do
        put_resource(index, resource_key(effective_base_uri), %{
          base_uri: resource_key(effective_base_uri),
          document: resource_document,
          path: path,
          source: source
        })
      else
        index
      end

    index =
      index
      |> put_anchor(map, "$anchor", effective_base_uri, path, source, resource_document)
      |> put_anchor(map, "$dynamicAnchor", effective_base_uri, path, source, resource_document)

    map
    |> Enum.sort_by(&sort_entry/1)
    |> Enum.reduce(index, fn {key, value}, inner_index ->
      do_build_index(
        value,
        path ++ [key],
        source,
        effective_base_uri,
        resource_document,
        inner_index
      )
    end)
  end

  defp put_resource(index, key, resource) do
    update_in(index.resources, &Map.put_new(&1, key, resource))
  end

  defp put_anchor(index, map, keyword, base_uri, path, source, resource_document) do
    case Map.get(map, keyword) do
      anchor when is_binary(anchor) ->
        anchor_uri = with_optional_fragment(base_uri, anchor)

        entry = %{
          absolute_uri: anchor_uri,
          base_uri: resource_key(base_uri),
          document: resource_document,
          path: path,
          source: source,
          value: map
        }

        update_in(index.anchors, &Map.put_new(&1, anchor_uri, entry))

      _ ->
        index
    end
  end

  defp resolve_target(index, %Location{} = location, loader, cache) do
    case split_target(location.absolute_uri || location.raw_ref) do
      {:ok, target_base_uri, fragment} ->
        case Map.get(index.resources, target_base_uri) do
          nil ->
            resolve_external_target(target_base_uri, fragment, location, loader, cache)

          resource ->
            with_cache(resolve_within_index(index, resource, fragment, location), cache)
        end

      :error ->
        {:error, %Error{kind: :invalid_ref, location: location, details: location.raw_ref}, cache}
    end
  end

  defp resolve_external_target(target_base_uri, _fragment, location, _loader, cache)
       when target_base_uri in [nil, ""] do
    {:error,
     %Error{
       kind: :missing_target,
       location: location,
       target_uri: location.absolute_uri,
       details: :unknown_local_resource
     }, cache}
  end

  defp resolve_external_target(target_base_uri, fragment, location, loader, cache) do
    with {:ok, document, source, updated_cache} <-
           load_document(target_base_uri, loader, location, cache),
         index <- build_index(document, source, target_base_uri),
         resource when not is_nil(resource) <-
           Map.get(index.resources, resource_key(target_base_uri)) do
      with_cache(resolve_within_index(index, resource, fragment, location), updated_cache)
    else
      nil ->
        {:error,
         %Error{
           kind: :missing_target,
           location: location,
           target_uri: location.absolute_uri,
           details: :missing_external_resource
         }, cache}

      {:error, %Error{} = error, updated_cache} ->
        {:error, error, updated_cache}
    end
  end

  defp resolve_within_index(_index, resource, nil, _location) do
    {:ok,
     %{
       document: resource.document,
       pointer: nil,
       source: resource.source,
       value: resource.document
     }}
  end

  defp resolve_within_index(_index, resource, "/" <> _ = fragment, location) do
    pointer = URIUtil.local_ref(fragment)

    case ExJSONPointer.resolve(resource.document, pointer) do
      {:ok, value} ->
        {:ok,
         %{
           document: resource.document,
           pointer: pointer,
           source: resource.source,
           value: value
         }}

      {:error, reason} ->
        {:error,
         %Error{
           kind: :missing_target,
           location: location,
           target_uri: location.absolute_uri,
           details: reason
         }}
    end
  end

  defp resolve_within_index(index, _resource, fragment, location) do
    anchor_uri = with_optional_fragment(base_of(location.absolute_uri), fragment)

    case Map.get(index.anchors, anchor_uri) do
      nil ->
        {:error,
         %Error{
           kind: :missing_target,
           location: location,
           target_uri: location.absolute_uri,
           details: fragment
         }}

      anchor ->
        {:ok,
         %{
           document: anchor.document,
           pointer: path_to_pointer(anchor.path),
           source: anchor.source,
           value: anchor.value
         }}
    end
  end

  defp load_document(target_base_uri, loader, location, cache) do
    case Map.get(cache, target_base_uri) do
      %{document: document, source: source} ->
        {:ok, document, source, cache}

      nil ->
        case Schemas.fetch(target_base_uri) do
          {:ok, document} ->
            updated_cache = put_cached_document(cache, target_base_uri, document, target_base_uri)
            {:ok, document, target_base_uri, updated_cache}

          :error ->
            do_load_document(target_base_uri, loader, location, cache)
        end
    end
  end

  defp do_load_document(_target_base_uri, nil, location, cache) do
    {:error,
     %Error{
       kind: :missing_document,
       location: location,
       target_uri: location.absolute_uri,
       details: :loader_not_configured
     }, cache}
  end

  defp do_load_document(target_base_uri, loader, location, cache) when is_function(loader, 1) do
    case loader.(target_base_uri) do
      {:ok, %{document: document} = loaded} ->
        source = Map.get(loaded, :source, target_base_uri)
        updated_cache = put_cached_document(cache, target_base_uri, document, source)
        {:ok, document, source, updated_cache}

      {:ok, document} when is_map(document) or is_list(document) or is_boolean(document) ->
        updated_cache = put_cached_document(cache, target_base_uri, document, target_base_uri)
        {:ok, document, target_base_uri, updated_cache}

      {:error, reason} ->
        {:error,
         %Error{
           kind: :missing_document,
           location: location,
           target_uri: location.absolute_uri,
           details: reason
         }, cache}

      other ->
        {:error,
         %Error{
           kind: :invalid_loader_response,
           location: location,
           target_uri: location.absolute_uri,
           details: other
         }, cache}
    end
  end

  defp with_cache({:ok, target}, cache), do: {:ok, target, cache}
  defp with_cache({:error, %Error{} = error}, cache), do: {:error, error, cache}

  defp put_cached_document(cache, target_base_uri, document, source) do
    Map.put(cache, target_base_uri, %{document: document, source: source})
  end

  defp initial_base_uri(opts, source) do
    case Keyword.fetch(opts, :base_uri) do
      {:ok, value} -> value
      :error when is_binary(source) -> source
      :error -> nil
    end
  end

  defp loader_from_opts(opts) do
    Keyword.get(opts, :loader) || Keyword.get(opts, :external_loader)
  end

  defp effective_base_uri(base_uri, map) do
    case Map.get(map, "$id") do
      id when is_binary(id) -> resolve_reference(base_uri, id)
      _ -> base_uri
    end
  end

  defp resolve_reference(nil, uri), do: uri
  defp resolve_reference(base, nil), do: base

  defp resolve_reference(base, uri) when is_binary(base) and is_binary(uri) do
    cond do
      uri == "" ->
        base_of(base)

      absolute_uri?(uri) ->
        uri

      String.starts_with?(uri, "#") ->
        base = base_of(base)
        with_optional_fragment(base, String.trim_leading(uri, "#"))

      absolute_uri?(base) ->
        URIUtil.resolve(base, uri)

      true ->
        resolve_path_reference(base, uri)
    end
  end

  defp resolve_path_reference(base, uri) do
    {ref_path, fragment} = URIUtil.split_fragment(uri)

    resolved_path =
      cond do
        ref_path == "" ->
          base_of(base)

        String.starts_with?(ref_path, "/") ->
          ref_path

        true ->
          base
          |> base_of()
          |> path_dirname()
          |> join_and_normalize(ref_path)
      end

    with_optional_fragment(resolved_path, fragment)
  end

  defp absolute_uri?(value) when is_binary(value) do
    match?(%URI{scheme: scheme} when not is_nil(scheme), URI.parse(value))
  end

  defp absolute_uri?(_), do: false

  defp base_of(value) when is_binary(value) do
    value
    |> URIUtil.split_fragment()
    |> elem(0)
  end

  defp base_of(_), do: ""

  defp fragment_of(value) when is_binary(value), do: URIUtil.fragment(value)
  defp fragment_of(_), do: nil

  defp path_to_pointer([]), do: nil

  defp path_to_pointer(path) when is_list(path) do
    encoded = Enum.map(path, &encode_pointer_segment/1)
    "#/" <> Enum.join(encoded, "/")
  end

  defp pointer_to_path(nil), do: []
  defp pointer_to_path("#"), do: []

  defp pointer_to_path("#/" <> rest) do
    rest
    |> String.split("/", trim: true)
    |> Enum.map(&decode_pointer_segment/1)
  end

  defp pointer_to_path(_), do: []

  defp encode_pointer_segment(segment) when is_integer(segment), do: Integer.to_string(segment)

  defp encode_pointer_segment(segment) when is_binary(segment) do
    segment
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp decode_pointer_segment(segment) when is_binary(segment) do
    segment
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp split_target(value) when is_binary(value) do
    {base, fragment} = URIUtil.split_fragment(value)
    {:ok, resource_key(base), fragment}
  rescue
    _ -> :error
  end

  defp split_target(_), do: :error

  defp resource_key(nil), do: ""
  defp resource_key(value) when is_binary(value), do: value

  defp with_optional_fragment(base, nil), do: resource_key(base)
  defp with_optional_fragment(base, ""), do: resource_key(base)
  defp with_optional_fragment(base, fragment), do: resource_key(base) <> "#" <> fragment

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

  defp sort_entry({key, _value}) when is_binary(key), do: {0, key}
  defp sort_entry({key, _value}) when is_integer(key), do: {1, key}
  defp sort_entry({key, _value}), do: {2, inspect(key)}
end

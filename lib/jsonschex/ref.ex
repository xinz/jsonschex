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
  - `transform/3` applies a callback-driven, policy-free structural rewrite over
    discovered `$ref` locations
  - `rebase/3` rewrites a resource so its refs remain valid under a new root
    resource URI
  - `render_ref/3` renders a stable `$ref` string for a resolved target
  - `target_uri/1` returns a canonical absolute URI for a resolved target when available
  - `collect_external_resources/2` gathers reachable non-root resources keyed by canonical resource URI
  - `bundle/3` returns a structured bundle-oriented view with rebased root and collected resources
  - `index_walk_events/1` turns ordered walk events into a location-keyed index

  ## Options

  - `:source` — source identifier for the root document. This is primarily
    provenance metadata for returned `%Location{}`, `%Resolution{}`, `%Error{}`,
    and `%Cycle{}` values.
  - `:base_uri` — explicit starting base URI override used for reference
    resolution.
  - `:loader` — `(document_uri -> {:ok, document} | {:ok, %{document: document, source: source}} | {:error, term()})`

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
      :absolute_uri
    ]

    @type t :: %__MODULE__{
            raw_ref: String.t(),
            path: JSONSchex.Ref.path(),
            source: JSONSchex.Ref.source() | nil,
            base_uri: String.t() | nil,
            absolute_uri: String.t() | nil
          }

    @doc """
    Returns the path to the node containing the `$ref`, excluding the `$ref` key itself.
    """
    @spec node_path(t()) :: JSONSchex.Ref.path()
    def node_path(%__MODULE__{path: path}) when is_list(path) do
      case Enum.reverse(path) do
        ["$ref" | rest] -> Enum.reverse(rest)
        _ -> path
      end
    end
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
      :target_source,
      :target_document,
      :target_value,
      :target_pointer
    ]

    @type t :: %__MODULE__{
            location: JSONSchex.Ref.Location.t(),
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
      :details
    ]

    @type kind :: :invalid_ref | :missing_document | :missing_target | :invalid_loader_response

    @type t :: %__MODULE__{
            kind: kind(),
            location: JSONSchex.Ref.Location.t() | nil,
            details: term()
          }
  end

  defmodule Cycle do
    @moduledoc """
    A cycle detected while transitively walking `$ref` targets.
    """

    @enforce_keys [:location, :trail]
    defstruct [
      :location,
      :trail
    ]

    @type t :: %__MODULE__{
            location: JSONSchex.Ref.Location.t(),
            trail: [String.t()]
          }
  end

  @typedoc "Ordered event emitted by `walk/2`."
  @type walk_event :: Resolution.t() | Error.t() | Cycle.t()

  @typedoc "Stable key for indexing locations and walk events."
  @type location_key :: {source(), String.t() | nil, path(), String.t() | nil}

  @typedoc "Indexed view of walk events keyed by location."
  @type walk_index :: %{
          resolutions: %{optional(location_key()) => Resolution.t()},
          errors: %{optional(location_key()) => Error.t()},
          cycles: %{optional(location_key()) => Cycle.t()}
        }

  @typedoc "Collected external resource entry keyed by canonical resource URI."
  @type external_resource_entry :: %{
          required(:document) => document(),
          optional(:source) => source() | nil,
          required(:resolutions) => [Resolution.t()]
        }

  @typedoc "Collected external resources keyed by canonical resource URI."
  @type external_resource_index :: %{optional(String.t()) => external_resource_entry()}

  @typedoc "Bundle-oriented resource entry keyed by original canonical resource URI."
  @type bundle_resource_entry :: %{
          required(:document) => document(),
          required(:rebased_document) => document(),
          optional(:source) => source() | nil,
          required(:resolutions) => [Resolution.t()],
          required(:rebased_resource_uri) => String.t()
        }

  @typedoc "Bundle-oriented resource index keyed by original canonical resource URI."
  @type bundle_resource_index :: %{optional(String.t()) => bundle_resource_entry()}

  @typedoc "Structured bundle-oriented view built from a root document and reachable resources."
  @type bundle_result :: %{
          required(:root_document) => document(),
          required(:resources_by_uri) => external_resource_index(),
          required(:rebased_resources_by_uri) => %{optional(String.t()) => document()},
          required(:resource_uri_map) => %{optional(String.t()) => String.t()},
          required(:walk_events) => [walk_event()],
          required(:walk_index) => walk_index(),
          required(:location_index) => walk_index(),
          required(:resource_index) => bundle_resource_index()
        }

  @typedoc "Outcome passed to `transform/3` callbacks for a discovered location."
  @type transform_outcome ::
          {:ok, Resolution.t()} | {:cycle, Resolution.t(), Cycle.t()} | {:error, Error.t()}

  @typedoc "Return value expected from a `transform/3` callback."
  @type transform_callback_result :: {:replace, term()} | :keep | {:error, term()}

  @typedoc "Callback used by `transform/3`."
  @type transform_callback :: (Location.t(), transform_outcome() -> transform_callback_result())

  @typedoc "Rendering mode used by `render_ref/3`."
  @type render_mode :: :original | :absolute | :prefer_local | :mounted

  @doc """
  Returns `true` if the given ref is a same-document local ref.

  ## Examples

      iex> JSONSchex.Ref.local_ref?("#/$defs/name")
      true

      iex> JSONSchex.Ref.local_ref?("schemas/common.json#/$defs/name")
      false
  """
  @spec local_ref?(String.t()) :: boolean()
  def local_ref?("#" <> _), do: true
  def local_ref?(_), do: false

  @doc """
  Returns `true` if the given ref is external to the current document.

  ## Examples

      iex> JSONSchex.Ref.external_ref?("#/$defs/name")
      false

      iex> JSONSchex.Ref.external_ref?("schemas/common.json#/$defs/name")
      true
  """
  @spec external_ref?(String.t()) :: boolean()
  def external_ref?(ref) when is_binary(ref), do: not local_ref?(ref)
  def external_ref?(_), do: false

  @doc """
  Returns a stable key for indexing a `%Location{}`.
  """
  @spec location_key(Location.t()) :: location_key()
  def location_key(%Location{} = location) do
    {location.source, location.base_uri, location.path, location.absolute_uri}
  end

  @doc """
  Collects reachable external resources keyed by canonical resource URI.

  This helper builds on `walk/2` and groups successful resolutions whose target
  resources are outside the original input document resource set.

  Each entry contains:

  - `:document` — the resource root document
  - `:source` — the loaded document source, when available
  - `:resolutions` — all successful resolutions that targeted that resource

  Root resources that belong to the original input document are excluded, even
  when the input contains nested `$id` resources. Only successful reachable
  non-root resources are collected.

  ## Options

  This function accepts the same root-context options as `walk/2`:

  - `:source` — source identifier for the root document. This is used both as
    provenance metadata and, when `:base_uri` is omitted and `:source` is a
    binary, as the initial base URI.
  - `:base_uri` — explicit starting base URI override used for reference
    resolution.
  - `:loader` — `(document_uri -> {:ok, document} | {:ok, %{document: document, source: source}} | {:error, term()})`

  ## Notes

  - this helper only includes resources reached through successful
    `%Resolution{}` events
  - `%Error{}` and `%Cycle{}` events are ignored for collection purposes
  - the `:resolutions` list for each collected resource preserves every
    successful incoming resolution that targeted that resource

  ## Example

      iex> document = %{
      ...>   "$id" => "specs/root.json",
      ...>   "start" => %{"$ref" => "schemas/common.json#/schema"}
      ...> }
      iex> loader = fn
      ...>   "specs/schemas/common.json" ->
      ...>     {:ok,
      ...>      %{
      ...>        document: %{
      ...>          "$id" => "specs/schemas/common.json",
      ...>          "$defs" => %{"name" => %{"type" => "string"}},
      ...>          "schema" => %{"$ref" => "#/$defs/name"}
      ...>        },
      ...>        source: "specs/schemas/common.json"
      ...>      }}
      ...>   _ ->
      ...>     {:error, :enoent}
      ...> end
      iex> {:ok, resources} =
      ...>   JSONSchex.Ref.collect_external_resources(document,
      ...>     source: "specs/root.json",
      ...>     loader: loader
      ...>   )
      iex> Map.keys(resources)
      ["specs/schemas/common.json"]
      iex> resources["specs/schemas/common.json"].document["schema"]
      %{"$ref" => "#/$defs/name"}
  """
  @spec collect_external_resources(document(), keyword()) :: {:ok, external_resource_index()}
  def collect_external_resources(document, opts \\ [])
      when is_map(document) or is_list(document) or is_boolean(document) do
    source = Keyword.get(opts, :source)
    base_uri = initial_base_uri(opts, source)
    root_resource_uris = root_resource_uris(document, source, base_uri)

    {:ok, events} = walk(document, opts)

    resources =
      Enum.reduce(events, %{}, fn event, acc ->
        case event do
          %Resolution{} = resolution ->
            case resource_uri(resolution) do
              uri when is_binary(uri) ->
                if MapSet.member?(root_resource_uris, uri) do
                  acc
                else
                  Map.update(acc, uri, external_resource_entry(resolution), fn entry ->
                    append_external_resolution(entry, resolution)
                  end)
                end

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)
      |> normalize_external_resource_index()

    {:ok, resources}
  end

  @doc """
  Builds a structured bundle-oriented view of the root document and its reachable
  external resources.

  This helper combines:

  - `walk/2`
  - `index_walk_events/1`
  - `collect_external_resources/2`
  - `rebase/3`

  The returned result includes the rebased root document, original collected
  external resources keyed by canonical resource URI, rebased external resource
  documents keyed by their original canonical resource URI, a richer
  `resource_index`, the merged `resource_uri_map`, and the ordered and indexed
  walk output.

  ## Options

  This function accepts the same root-context options as `walk/2` and `rebase/3`:

  - `:source`
  - `:base_uri`
  - `:loader`
  - `:resource_uri_map`

  ## Example

      iex> document = %{
      ...>   "$id" => "specs/root.json",
      ...>   "start" => %{"$ref" => "schemas/common.json#/schema"}
      ...> }
      iex> loader = fn
      ...>   "specs/schemas/common.json" ->
      ...>     {:ok,
      ...>      %{
      ...>        document: %{
      ...>          "$id" => "specs/schemas/common.json",
      ...>          "$defs" => %{"name" => %{"type" => "string"}},
      ...>          "schema" => %{"$ref" => "#/$defs/name"}
      ...>        },
      ...>        source: "specs/schemas/common.json"
      ...>      }}
      ...>   _ ->
      ...>     {:error, :enoent}
      ...> end
      iex> {:ok, bundle} =
      ...>   JSONSchex.Ref.bundle(document, "specs/bundle/root.json",
      ...>     source: "specs/root.json",
      ...>     loader: loader,
      ...>     resource_uri_map: %{
      ...>       "specs/schemas/common.json" => "specs/bundle/common.json"
      ...>     }
      ...>   )
      iex> bundle.root_document["start"]
      %{"$ref" => "common.json#/schema"}
      iex> Map.keys(bundle.resources_by_uri)
      ["specs/schemas/common.json"]
      iex> bundle.rebased_resources_by_uri["specs/schemas/common.json"]["$id"]
      "specs/bundle/common.json"
      iex> bundle.location_index == bundle.walk_index
      true
      iex> bundle.resource_index["specs/schemas/common.json"].rebased_resource_uri
      "specs/bundle/common.json"
  """
  @spec bundle(document(), String.t(), keyword()) :: {:ok, bundle_result()} | {:error, term()}
  def bundle(document, target_base_uri, opts \\ [])
      when (is_map(document) or is_list(document) or is_boolean(document)) and
             is_binary(target_base_uri) do
    source = Keyword.get(opts, :source)
    current_base_uri = initial_base_uri(opts, source)
    root_resource_uri_map = build_rebase_resource_uri_map(document, current_base_uri, target_base_uri)
    resource_uri_map = Map.merge(resource_uri_map_from_opts(opts), root_resource_uri_map)
    rebase_opts = Keyword.put(opts, :resource_uri_map, resource_uri_map)

    with {:ok, walk_events} <- walk(document, opts),
         walk_index = index_walk_events(walk_events),
         {:ok, resources_by_uri} <- collect_external_resources(document, opts),
         {:ok, root_document} <- rebase(document, target_base_uri, rebase_opts),
         {:ok, rebased_resources_by_uri} <-
           rebase_external_resources(resources_by_uri, resource_uri_map) do
      resource_index =
        build_bundle_resource_index(resources_by_uri, rebased_resources_by_uri, resource_uri_map)

      {:ok,
       %{
         root_document: root_document,
         resources_by_uri: resources_by_uri,
         rebased_resources_by_uri: rebased_resources_by_uri,
         resource_uri_map: resource_uri_map,
         walk_events: walk_events,
         walk_index: walk_index,
         location_index: walk_index,
         resource_index: resource_index
       }}
    end
  end

  @doc """
  Indexes walk events by `location_key/1`.

  The returned map separates successful resolutions, errors, and cycles.

  ## Examples

      iex> location = %JSONSchex.Ref.Location{
      ...>   raw_ref: "#/$defs/name",
      ...>   path: ["schema", "$ref"],
      ...>   source: "https://example.com/root.json",
      ...>   base_uri: "https://example.com/root.json",
      ...>   absolute_uri: "https://example.com/root.json#/$defs/name"
      ...> }
      iex> resolution = %JSONSchex.Ref.Resolution{
      ...>   location: location,
      ...>   target_source: "https://example.com/root.json",
      ...>   target_document: %{},
      ...>   target_value: %{},
      ...>   target_pointer: "#/$defs/name"
      ...> }
      iex> index = JSONSchex.Ref.index_walk_events([resolution])
      iex> Map.has_key?(index.resolutions, JSONSchex.Ref.location_key(location))
      true
  """
  @spec index_walk_events([walk_event()]) :: walk_index()
  def index_walk_events(events) when is_list(events) do
    Enum.reduce(events, %{resolutions: %{}, errors: %{}, cycles: %{}}, fn event, acc ->
      case event do
        %Resolution{location: location} = resolution ->
          put_in(acc, [:resolutions, location_key(location)], resolution)

        %Error{location: location} = error when is_struct(location, Location) ->
          put_in(acc, [:errors, location_key(location)], error)

        %Cycle{location: location} = cycle ->
          put_in(acc, [:cycles, location_key(location)], cycle)

        _ ->
          acc
      end
    end)
  end

  @doc """
  Returns the resource URI represented by the given ref struct.

  For `%Location{}`, this is the current resource being scanned.
  For `%Resolution{}`, `%Error{}`, and `%Cycle{}`, this is the target resource.
  """
  @spec resource_uri(Location.t() | Resolution.t() | Error.t() | Cycle.t()) :: String.t() | nil
  def resource_uri(%Location{base_uri: base_uri}) when is_binary(base_uri),
    do: URIUtil.base(base_uri)

  def resource_uri(%Location{absolute_uri: absolute_uri}) when is_binary(absolute_uri),
    do: URIUtil.base(absolute_uri)

  def resource_uri(%Location{}), do: nil

  def resource_uri(%Resolution{location: location, target_source: target_source}) do
    cond do
      match?(%Location{absolute_uri: absolute_uri} when is_binary(absolute_uri), location) ->
        URIUtil.base(location.absolute_uri)

      is_binary(target_source) ->
        URIUtil.base(target_source)

      true ->
        nil
    end
  end

  def resource_uri(%Error{location: location}) do
    cond do
      match?(%Location{absolute_uri: absolute_uri} when is_binary(absolute_uri), location) ->
        URIUtil.base(location.absolute_uri)

      match?(%Location{}, location) ->
        resource_uri(location)

      true ->
        nil
    end
  end

  def resource_uri(%Cycle{location: location, trail: trail}) do
    cond do
      is_list(trail) and trail != [] and is_binary(hd(trail)) -> URIUtil.base(hd(trail))
      match?(%Location{}, location) -> resource_uri(location)
      true -> nil
    end
  end

  @doc """
  Returns the canonical absolute URI for a resolved target when it can be derived.

  This is primarily useful for downstream tooling that needs a stable identity
  key for resolved targets, such as rebasing or bundling logic.
  """
  @spec target_uri(Resolution.t()) :: String.t() | nil
  def target_uri(%Resolution{location: %Location{absolute_uri: absolute_uri}})
      when is_binary(absolute_uri),
      do: absolute_uri

  def target_uri(%Resolution{} = resolution) do
    target_resource = resource_uri(resolution)
    fragment = preferred_fragment(resolution)

    cond do
      is_binary(target_resource) and is_binary(fragment) ->
        target_resource <> "#" <> fragment

      is_binary(target_resource) and is_binary(resolution.target_pointer) ->
        target_resource <> resolution.target_pointer

      is_binary(target_resource) ->
        target_resource

      true ->
        nil
    end
  end

  @doc """
  Renders a `$ref` string for the given resolved target.

  Supported modes are:

  - `:original` — keep the original raw `$ref` from the source location
  - `:absolute` — render the target as an absolute resource URI plus fragment
  - `:prefer_local` — render a local fragment for same-resource targets, otherwise
    a relative ref when it can be computed safely, falling back to absolute
  - `:mounted` — render the target as it should appear from a rebased or mounted
    resource context

  The default mode is `:prefer_local`.

  `:mounted` expects:

  - `:mount_base_uri` — the rebased containing resource base URI

  and optionally:

  - `:resource_uri_map` — remaps target resource URIs before rendering

  ## Examples

      iex> location = %JSONSchex.Ref.Location{
      ...>   raw_ref: "#/$defs/name",
      ...>   path: ["schema", "$ref"],
      ...>   source: "https://example.com/root.json",
      ...>   base_uri: "https://example.com/root.json",
      ...>   absolute_uri: "https://example.com/root.json#/$defs/name"
      ...> }
      iex> resolution = %JSONSchex.Ref.Resolution{
      ...>   location: location,
      ...>   target_source: "https://example.com/root.json",
      ...>   target_document: %{"$defs" => %{"name" => %{"type" => "string"}}},
      ...>   target_value: %{"type" => "string"},
      ...>   target_pointer: "#/$defs/name"
      ...> }
      iex> JSONSchex.Ref.render_ref(location, resolution)
      "#/$defs/name"
      iex> JSONSchex.Ref.render_ref(location, resolution, mode: :absolute)
      "https://example.com/root.json#/$defs/name"
  """
  @spec render_ref(Location.t(), Resolution.t(), keyword()) :: String.t() | nil
  def render_ref(%Location{} = location, %Resolution{} = resolution, opts \\ []) do
    case Keyword.get(opts, :mode, :prefer_local) do
      :original ->
        render_original_ref(location, resolution)

      :absolute ->
        render_absolute_ref(resolution)

      :prefer_local ->
        render_prefer_local_ref(location, resolution)

      :mounted ->
        render_mounted_ref(location, resolution, opts)
    end
  end

  defp render_original_ref(%Location{raw_ref: raw_ref}, _resolution) when is_binary(raw_ref),
    do: raw_ref

  defp render_original_ref(_location, %Resolution{} = resolution),
    do: render_prefer_local_ref(nil, resolution)

  defp render_absolute_ref(%Resolution{} = resolution), do: target_uri(resolution)

  defp render_prefer_local_ref(%Location{} = location, %Resolution{} = resolution) do
    source_resource = resource_uri(location)
    target_resource = resource_uri(resolution)

    cond do
      is_binary(source_resource) and is_binary(target_resource) and
          source_resource == target_resource ->
        render_same_resource_ref(source_resource, resolution)

      is_binary(source_resource) and is_binary(target_resource) ->
        render_relative_resource_ref(source_resource, target_resource, resolution) ||
          render_absolute_ref(resolution)

      true ->
        render_absolute_ref(resolution)
    end
  end

  defp render_prefer_local_ref(_location, %Resolution{} = resolution),
    do: render_absolute_ref(resolution)

  defp render_mounted_ref(%Location{} = location, %Resolution{} = resolution, opts) do
    case Keyword.get(opts, :mount_base_uri) do
      mount_base_uri when is_binary(mount_base_uri) ->
        mount_resource = URIUtil.base(mount_base_uri)
        source_resource = resource_uri(location)

        resource_uri_map =
          opts
          |> resource_uri_map_from_opts()
          |> maybe_put_mounted_source_resource(source_resource, mount_resource)

        mounted_target_uri =
          rebase_target_uri(mount_resource, target_uri(resolution), resource_uri_map)

        render_rebased_target_uri(mount_resource, mounted_target_uri)

      _ ->
        render_absolute_ref(resolution)
    end
  end

  defp render_same_resource_ref(source_resource, %Resolution{} = resolution) do
    fragment = preferred_fragment(resolution)

    cond do
      is_binary(fragment) ->
        "#" <> fragment

      is_binary(resolution.target_pointer) ->
        resolution.target_pointer

      same_resource_root?(source_resource, resolution) ->
        "#"

      true ->
        nil
    end
  end

  defp render_relative_resource_ref(source_resource, target_resource, %Resolution{} = resolution) do
    with relative_resource when is_binary(relative_resource) <-
           relativize_resource_uri(source_resource, target_resource) do
      case preferred_fragment(resolution) do
        fragment when is_binary(fragment) ->
          relative_resource <> "#" <> fragment

        _ when is_binary(resolution.target_pointer) ->
          relative_resource <> resolution.target_pointer

        _ ->
          relative_resource
      end
    else
      _ -> nil
    end
  end

  defp preferred_fragment(%Resolution{location: %Location{absolute_uri: absolute_uri}})
       when is_binary(absolute_uri) do
    URIUtil.fragment(absolute_uri)
  end

  defp preferred_fragment(%Resolution{target_pointer: "#" <> fragment}) when is_binary(fragment),
    do: fragment

  defp preferred_fragment(_), do: nil

  defp same_resource_root?(source_resource, %Resolution{} = resolution) do
    absolute_uri =
      case resolution.location do
        %Location{absolute_uri: absolute_uri} when is_binary(absolute_uri) -> absolute_uri
        _ -> nil
      end

    resource_uri(resolution) == source_resource and
      ((is_binary(absolute_uri) and is_nil(URIUtil.fragment(absolute_uri))) or
         (is_nil(absolute_uri) and is_nil(resolution.target_pointer) and
            resolution.target_value === resolution.target_document))
  end

  defp relativize_resource_uri(source_resource, target_resource) do
    source = URI.parse(source_resource)
    target = URI.parse(target_resource)

    cond do
      path_like_resource?(source_resource) and path_like_resource?(target_resource) ->
        Path.relative_to(target_resource, path_dirname(source_resource))

      same_hierarchical_uri_origin?(source, target) and is_binary(source.path) and
          is_binary(target.path) ->
        relativize_hierarchical_uri_path(source.path, target.path)

      true ->
        nil
    end
  end

  defp relativize_hierarchical_uri_path(source_path, target_path)
       when is_binary(source_path) and is_binary(target_path) do
    source_dir =
      source_path
      |> String.trim_leading("/")
      |> path_dirname()

    target_path
    |> String.trim_leading("/")
    |> Path.relative_to(source_dir)
  end

  defp path_like_resource?(resource) when is_binary(resource) do
    match?(%URI{scheme: nil}, URI.parse(resource))
  end

  defp path_like_resource?(_), do: false

  defp same_hierarchical_uri_origin?(source, target) do
    source.scheme == target.scheme and source.host == target.host and source.port == target.port and
      source.scheme not in [nil, "urn"] and is_binary(source.path) and is_binary(target.path)
  end

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

  External documents are loaded through `:loader`. The loader receives the
  resolved document URI without the fragment and may return either a document
  directly or `%{document: document, source: source}`.

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

  @doc """
  Structurally transforms a document by applying a callback to each discovered `$ref` location.

  The callback receives the location and one of:

  - `{:ok, resolution}` for a successfully transformed target
  - `{:cycle, resolution, cycle}` when a target would recurse into an active trail
  - `{:error, error}` when a location could not be resolved

  Returning `{:replace, term}` replaces the node containing the `$ref`. Returning
  `:keep` leaves the current node in place. Returning `{:error, term}` aborts the
  transform.

  Nested refs inside successfully resolved targets are transformed before the
  callback runs for their successful parent location, making this API suitable
  for post-order expansion policies. When that happens, the nested
  `%Location{}` path is reported in the resolved target's own document context,
  not as a path prefixed by the original referring location.

  This function uses the same root-context options as `walk/2` and `resolve/3`.

  ## Options

  - `:source` — source identifier for the root document. This is primarily
    provenance metadata for returned `%Location{}`, `%Resolution{}`,
    `%Error{}`, and `%Cycle{}` values seen by the callback. If `:base_uri` is
    omitted and `:source` is a binary, `:source` is also used as the initial
    base URI.
  - `:base_uri` — explicit starting base URI override used for reference
    resolution.
  - `:loader` — `(document_uri -> {:ok, document} | {:ok, %{document: document, source: source}} | {:error, term()})`
  """
  @spec transform(document(), transform_callback(), keyword()) :: {:ok, term()} | {:error, term()}
  def transform(document, fun, opts \\ [])
      when (is_map(document) or is_list(document) or is_boolean(document)) and is_function(fun, 2) do
    source = Keyword.get(opts, :source)
    base_uri = initial_base_uri(opts, source)
    loader = loader_from_opts(opts)

    state = %{
      active: MapSet.new(),
      cache: %{},
      transformed_targets: %{}
    }

    case transform_node(document, [], document, source, base_uri, loader, fun, state, [], []) do
      {:ok, transformed_document, _state} ->
        {:ok, transformed_document}

      {:error, reason, _state} ->
        {:error, reason}
    end
  end

  @doc """
  Rewrites a resource so its refs remain valid under a new root resource URI.

  This helper preserves ref target semantics while changing the document's root
  resource identity. Nested relative `$id` values continue to derive from the
  rebased root. Existing absolute `$id` values remain unchanged.

  Refs that target resources inside the rebased document are rewritten to their
  rebased locations automatically. Refs targeting resources outside the
  document remain pointed at their original targets unless an explicit
  `:resource_uri_map` remaps those target resource URIs.

  ## Options

  - `:source` — source identifier for the current document provenance
  - `:base_uri` — current starting base URI used to interpret relative refs and `$id`
    values before rebasing
  - `:resource_uri_map` — map or keyword list of `old_resource_uri => new_resource_uri`
    overrides for target resources outside the current document
  """
  @spec rebase(document(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def rebase(document, target_base_uri, opts \\ [])
      when (is_map(document) or is_list(document) or is_boolean(document)) and
             is_binary(target_base_uri) do
    source = Keyword.get(opts, :source)
    current_base_uri = initial_base_uri(opts, source)
    resource_uri_map = resource_uri_map_from_opts(opts)
    internal_resource_uri_map = build_rebase_resource_uri_map(document, current_base_uri, target_base_uri)
    resource_uri_map = Map.merge(resource_uri_map, internal_resource_uri_map)

    case rebase_node(
           document,
           [],
           source,
           current_base_uri,
           target_base_uri,
           resource_uri_map
         ) do
      {:ok, rebased_document} ->
        rebased_document = maybe_put_root_id(rebased_document, target_base_uri)
        {:ok, rebased_document}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp rebase_node(
         value,
         _path,
         _source,
         _old_base_uri,
         _new_base_uri,
         _resource_uri_map
       )
       when is_boolean(value) or is_binary(value) or is_number(value) or is_nil(value) do
    {:ok, value}
  end

  defp rebase_node(
         list,
         path,
         source,
         old_base_uri,
         new_base_uri,
         resource_uri_map
       )
       when is_list(list) do
    Enum.reduce_while(Enum.with_index(list), {:ok, []}, fn {item, index}, {:ok, acc} ->
      case rebase_node(
             item,
             path ++ [index],
             source,
             old_base_uri,
             new_base_uri,
             resource_uri_map
           ) do
        {:ok, rebased_item} ->
          {:cont, {:ok, [rebased_item | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebase_node(
         map,
         path,
         source,
         old_base_uri,
         new_base_uri,
         resource_uri_map
       )
       when is_map(map) do
    old_effective_base_uri = effective_base_uri(old_base_uri, map)

    new_effective_base_uri =
      case path do
        [] -> new_base_uri
        _ -> effective_base_uri(new_base_uri, map)
      end

    map
    |> Enum.sort_by(&sort_entry/1)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case rebase_node(
             value,
             path ++ [key],
             source,
             old_effective_base_uri,
             new_effective_base_uri,
             resource_uri_map
           ) do
        {:ok, rebased_value} ->
          {:cont, {:ok, Map.put(acc, key, rebased_value)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rebased_map} ->
        rebased_map = maybe_put_root_id(rebased_map, path, new_base_uri)

        rebase_current_ref(
          rebased_map,
          path,
          source,
          old_effective_base_uri,
          new_effective_base_uri,
          resource_uri_map
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebase_current_ref(
         map,
         _path,
         _source,
         _old_effective_base_uri,
         _new_effective_base_uri,
         _resource_uri_map
       )
       when not is_map(map) do
    {:ok, map}
  end

  defp rebase_current_ref(
         map,
         path,
         source,
         old_effective_base_uri,
         new_effective_base_uri,
         resource_uri_map
       ) do
    case Map.get(map, "$ref") do
      ref when is_binary(ref) ->
        location =
          normalize_location(
            %Location{raw_ref: ref, path: path ++ ["$ref"], source: source, base_uri: old_effective_base_uri},
            source,
            old_effective_base_uri
          )

        rebased_ref = rebase_ref(new_effective_base_uri, location, resource_uri_map)
        {:ok, Map.put(map, "$ref", rebased_ref)}

      _ ->
        {:ok, map}
    end
  end

  defp rebase_ref(new_effective_base_uri, %Location{} = location, resource_uri_map) do
    source_resource = if is_binary(new_effective_base_uri), do: URIUtil.base(new_effective_base_uri), else: nil

    rebased_target_uri =
      rebase_target_uri(
        source_resource,
        rebase_target_reference(location, resource_uri_map),
        resource_uri_map
      )

    render_rebased_target_uri(source_resource, rebased_target_uri)
  end

  defp rebase_target_reference(%Location{raw_ref: raw_ref} = location, resource_uri_map)
       when is_binary(raw_ref) do
    case split_target(raw_ref) do
      {:ok, target_resource, _fragment} when is_binary(target_resource) ->
        if Map.has_key?(resource_uri_map, target_resource) do
          raw_ref
        else
          location.absolute_uri || raw_ref
        end

      _ ->
        location.absolute_uri || raw_ref
    end
  end

  defp rebase_target_reference(%Location{} = location, _resource_uri_map),
    do: location.absolute_uri || location.raw_ref

  defp rebase_target_uri(source_resource, target_uri, resource_uri_map) when is_binary(target_uri) do
    case split_target(target_uri) do
      {:ok, target_resource, fragment} ->
        target_resource =
          cond do
            target_resource in [nil, ""] and is_binary(source_resource) ->
              source_resource

            is_binary(target_resource) ->
              Map.get(resource_uri_map, target_resource, target_resource)

            true ->
              nil
          end

        if is_binary(target_resource) do
          with_optional_fragment(target_resource, fragment)
        else
          target_uri
        end

      :error ->
        target_uri
    end
  end

  defp rebase_target_uri(_source_resource, target_uri, _resource_uri_map), do: target_uri

  defp render_rebased_target_uri(source_resource, rebased_target_uri)
       when is_binary(rebased_target_uri) do
    case split_target(rebased_target_uri) do
      {:ok, target_resource, fragment} when is_binary(source_resource) and source_resource == target_resource ->
        URIUtil.local_ref(fragment)

      {:ok, target_resource, fragment} when is_binary(source_resource) and is_binary(target_resource) ->
        case relativize_resource_uri(source_resource, target_resource) do
          relative_resource when is_binary(relative_resource) ->
            with_optional_fragment(relative_resource, fragment)

          _ ->
            rebased_target_uri
        end

      _ ->
        rebased_target_uri
    end
  end

  defp render_rebased_target_uri(_source_resource, rebased_target_uri), do: rebased_target_uri

  defp transform_node(
         value,
         _path,
         _resolve_document,
         _source,
         _base_uri,
         _loader,
         _fun,
         state,
         _trail,
         _path_prefix
       )
       when is_boolean(value) or is_binary(value) or is_number(value) or is_nil(value) do
    {:ok, value, state}
  end

  defp transform_node(
         list,
         path,
         resolve_document,
         source,
         base_uri,
         loader,
         fun,
         state,
         trail,
         path_prefix
       )
       when is_list(list) do
    Enum.reduce_while(Enum.with_index(list), {:ok, [], state}, fn {item, index},
                                                                  {:ok, acc, acc_state} ->
      case transform_node(
             item,
             path ++ [index],
             resolve_document,
             source,
             base_uri,
             loader,
             fun,
             acc_state,
             trail,
             path_prefix
           ) do
        {:ok, transformed_item, next_state} ->
          {:cont, {:ok, [transformed_item | acc], next_state}}

        {:error, reason, next_state} ->
          {:halt, {:error, reason, next_state}}
      end
    end)
    |> case do
      {:ok, acc, next_state} -> {:ok, Enum.reverse(acc), next_state}
      {:error, reason, next_state} -> {:error, reason, next_state}
    end
  end

  defp transform_node(
         map,
         path,
         resolve_document,
         source,
         base_uri,
         loader,
         fun,
         state,
         trail,
         path_prefix
       )
       when is_map(map) do
    effective_base_uri = effective_base_uri(base_uri, map)

    case transform_map_entries(
           map,
           path,
           resolve_document,
           source,
           effective_base_uri,
           loader,
           fun,
           state,
           trail,
           path_prefix
         ) do
      {:ok, transformed_map, next_state} ->
        maybe_transform_current_location(
          transformed_map,
          path,
          resolve_document,
          source,
          effective_base_uri,
          loader,
          fun,
          next_state,
          trail,
          path_prefix
        )

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp transform_map_entries(
         map,
         path,
         resolve_document,
         source,
         base_uri,
         loader,
         fun,
         state,
         trail,
         path_prefix
       ) do
    map
    |> Enum.sort_by(&sort_entry/1)
    |> Enum.reduce_while({:ok, %{}, state}, fn {key, value}, {:ok, acc, acc_state} ->
      case transform_node(
             value,
             path ++ [key],
             resolve_document,
             source,
             base_uri,
             loader,
             fun,
             acc_state,
             trail,
             path_prefix
           ) do
        {:ok, transformed_value, next_state} ->
          {:cont, {:ok, Map.put(acc, key, transformed_value), next_state}}

        {:error, reason, next_state} ->
          {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp maybe_transform_current_location(
         map,
         path,
         resolve_document,
         source,
         base_uri,
         loader,
         fun,
         state,
         trail,
         path_prefix
       ) do
    case Map.get(map, "$ref") do
      ref when is_binary(ref) ->
        location =
          normalize_location(
            %Location{raw_ref: ref, path: path ++ ["$ref"], source: source, base_uri: base_uri},
            source,
            base_uri
          )
          |> prefix_location_path(path_prefix)

        opts = [source: source, base_uri: base_uri, loader: loader]
        {result, cache} = resolve_location(resolve_document, location, opts, state.cache)
        state = %{state | cache: cache}

        case result do
          {:error, %Error{} = error} ->
            apply_transform_callback(fun, location, {:error, error}, map, state)

          {:ok, %Resolution{} = resolution} ->
            case transform_resolution(resolution, loader, fun, state, trail) do
              {:ok, outcome, next_state} ->
                apply_transform_callback(fun, location, outcome, map, next_state)

              {:error, reason, next_state} ->
                {:error, reason, next_state}
            end
        end

      _ ->
        {:ok, map, state}
    end
  end

  defp transform_resolution(%Resolution{} = resolution, loader, fun, state, trail) do
    target_uri = target_uri(resolution)

    cond do
      not walkable_document?(resolution.target_value) ->
        {:ok, {:ok, resolution}, state}

      not is_binary(target_uri) ->
        {:ok, {:ok, resolution}, state}

      MapSet.member?(state.active, target_uri) ->
        cycle = %Cycle{
          location: resolution.location,
          trail: Enum.reverse([target_uri | trail])
        }

        {:ok, {:cycle, resolution, cycle}, state}

      same_source_resource_root?(resolution) ->
        {:ok, {:ok, resolution}, state}

      match?({:ok, _}, Map.fetch(state.transformed_targets, target_uri)) ->
        transformed_target = Map.fetch!(state.transformed_targets, target_uri)
        {:ok, {:ok, %{resolution | target_value: transformed_target}}, state}

      true ->
        next_state = %{state | active: MapSet.put(state.active, target_uri)}

        case transform_node(
               resolution.target_value,
               [],
               resolution.target_document,
               resolution.target_source,
               next_base_uri(resolution),
               loader,
               fun,
               next_state,
               [target_uri | trail],
               path_prefix_from_resolution(resolution)
             ) do
          {:ok, transformed_target, next_state} ->
            next_state = %{
              next_state
              | active: MapSet.delete(next_state.active, target_uri),
                transformed_targets:
                  Map.put(next_state.transformed_targets, target_uri, transformed_target)
            }

            {:ok, {:ok, %{resolution | target_value: transformed_target}}, next_state}

          {:error, reason, next_state} ->
            next_state = %{next_state | active: MapSet.delete(next_state.active, target_uri)}
            {:error, reason, next_state}
        end
    end
  end

  defp apply_transform_callback(fun, location, outcome, current_node, state) do
    case fun.(location, outcome) do
      {:replace, replacement} ->
        {:ok, replacement, state}

      :keep ->
        {:ok, current_node, state}

      {:error, reason} ->
        {:error, reason, state}
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
    target_uri = target_uri(resolution)

    cond do
      not walkable_document?(resolution.target_value) ->
        state

      not is_binary(target_uri) ->
        state

      MapSet.member?(state.active, target_uri) ->
        push_event(state, %Cycle{
          location: resolution.location,
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

  defp path_prefix_from_resolution(%Resolution{target_pointer: target_pointer}) do
    decode_target_pointer_path!(target_pointer)
  end

  defp same_source_resource_root?(%Resolution{} = resolution) do
    resolution.target_value === resolution.target_document and
      resolution.target_source == resolution.location.source
  end

  defp next_base_uri(%Resolution{target_source: target_source} = resolution) do
    target_uri = target_uri(resolution)

    cond do
      is_binary(target_uri) ->
        URIUtil.base(target_uri)

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
        absolute_uri: absolute_uri
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
              absolute_uri: absolute_uri
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
           details: reason
         }}
    end
  end

  defp resolve_within_index(index, _resource, fragment, location) do
    anchor_uri = with_optional_fragment(URIUtil.base(location.absolute_uri), fragment)

    case Map.get(index.anchors, anchor_uri) do
      nil ->
        {:error,
         %Error{
           kind: :missing_target,
           location: location,
           details: fragment
         }}

      anchor ->
        pointer =
          anchor.path
          |> ExJSONPointer.encode_path(format: "uri_fragment")
          |> normalize_root_target_pointer()

        {:ok,
         %{
           document: anchor.document,
           pointer: pointer,
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
           details: reason
         }, cache}

      other ->
        {:error,
         %Error{
           kind: :invalid_loader_response,
           location: location,
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
    Keyword.get(opts, :loader)
  end

  defp resource_uri_map_from_opts(opts) do
    opts
    |> Keyword.get(:resource_uri_map, %{})
    |> Map.new()
  end



  defp maybe_put_mounted_source_resource(resource_uri_map, source_resource, mount_resource)
       when is_binary(source_resource) and is_binary(mount_resource) do
    Map.put_new(resource_uri_map, source_resource, mount_resource)
  end

  defp maybe_put_mounted_source_resource(resource_uri_map, _source_resource, _mount_resource),
    do: resource_uri_map

  defp root_resource_uris(document, source, base_uri) do
    document
    |> build_index(source, base_uri)
    |> Map.fetch!(:resources)
    |> Map.keys()
    |> MapSet.new()
  end

  defp external_resource_entry(%Resolution{} = resolution) do
    %{
      document: resolution.target_document,
      source: resolution.target_source,
      resolutions: [resolution]
    }
  end

  defp append_external_resolution(entry, %Resolution{} = resolution) do
    Map.update!(entry, :resolutions, &[resolution | &1])
  end

  defp normalize_external_resource_index(resources_by_uri) when is_map(resources_by_uri) do
    Enum.into(resources_by_uri, %{}, fn {uri, entry} ->
      {uri, Map.update!(entry, :resolutions, &Enum.reverse/1)}
    end)
  end

  defp rebase_external_resources(resources_by_uri, resource_uri_map) when is_map(resources_by_uri) do
    Enum.reduce_while(resources_by_uri, {:ok, %{}}, fn {uri, entry}, {:ok, acc} ->
      target_base_uri = Map.get(resource_uri_map, uri, uri)
      source = Map.get(entry, :source)

      opts = [base_uri: uri, resource_uri_map: resource_uri_map]
      opts = if is_nil(source), do: opts, else: Keyword.put(opts, :source, source)

      case rebase(entry.document, target_base_uri, opts) do
        {:ok, rebased_document} ->
          {:cont, {:ok, Map.put(acc, uri, rebased_document)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_bundle_resource_index(resources_by_uri, rebased_resources_by_uri, resource_uri_map)
       when is_map(resources_by_uri) and is_map(rebased_resources_by_uri) and is_map(resource_uri_map) do
    Enum.reduce(resources_by_uri, %{}, fn {uri, entry}, acc ->
      Map.put(acc, uri, %{
        document: entry.document,
        rebased_document: Map.get(rebased_resources_by_uri, uri, entry.document),
        source: Map.get(entry, :source),
        resolutions: entry.resolutions,
        rebased_resource_uri: Map.get(resource_uri_map, uri, uri)
      })
    end)
  end

  defp build_rebase_resource_uri_map(document, current_base_uri, target_base_uri) do
    do_build_rebase_resource_uri_map(document, [], current_base_uri, target_base_uri, %{})
  end

  defp do_build_rebase_resource_uri_map(value, path, old_base_uri, new_base_uri, acc)
       when is_boolean(value) or is_binary(value) or is_number(value) or is_nil(value) do
    if path == [] do
      put_rebased_resource_uri(acc, old_base_uri, new_base_uri)
    else
      acc
    end
  end

  defp do_build_rebase_resource_uri_map(list, path, old_base_uri, new_base_uri, acc)
       when is_list(list) do
    acc =
      if path == [] do
        put_rebased_resource_uri(acc, old_base_uri, new_base_uri)
      else
        acc
      end

    Enum.reduce(Enum.with_index(list), acc, fn {item, index}, inner_acc ->
      do_build_rebase_resource_uri_map(
        item,
        path ++ [index],
        old_base_uri,
        new_base_uri,
        inner_acc
      )
    end)
  end

  defp do_build_rebase_resource_uri_map(map, path, old_base_uri, new_base_uri, acc)
       when is_map(map) do
    old_effective_base_uri = effective_base_uri(old_base_uri, map)

    new_effective_base_uri =
      case path do
        [] -> new_base_uri
        _ -> effective_base_uri(new_base_uri, map)
      end

    acc =
      if path == [] or is_binary(Map.get(map, "$id")) do
        put_rebased_resource_uri(acc, old_effective_base_uri, new_effective_base_uri)
      else
        acc
      end

    Enum.reduce(Enum.sort_by(map, &sort_entry/1), acc, fn {key, value}, inner_acc ->
      do_build_rebase_resource_uri_map(
        value,
        path ++ [key],
        old_effective_base_uri,
        new_effective_base_uri,
        inner_acc
      )
    end)
  end

  defp put_rebased_resource_uri(acc, old_resource_uri, new_resource_uri)
       when is_binary(old_resource_uri) and is_binary(new_resource_uri) do
    Map.put(acc, URIUtil.base(old_resource_uri), URIUtil.base(new_resource_uri))
  end

  defp put_rebased_resource_uri(acc, _old_resource_uri, _new_resource_uri), do: acc

  defp maybe_put_root_id(document, target_base_uri)
       when is_map(document) and is_binary(target_base_uri) do
    Map.put(document, "$id", target_base_uri)
  end

  defp maybe_put_root_id(document, _target_base_uri), do: document

  defp maybe_put_root_id(document, [], target_base_uri)
       when is_map(document) and is_binary(target_base_uri) do
    Map.put(document, "$id", target_base_uri)
  end

  defp maybe_put_root_id(document, _path, _target_base_uri), do: document

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
        URIUtil.base(base)

      base == uri ->
        uri

      absolute_uri?(uri) ->
        uri

      String.starts_with?(uri, "#") ->
        base = URIUtil.base(base)
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
          URIUtil.base(base)

        String.starts_with?(ref_path, "/") ->
          ref_path

        true ->
          base
          |> URIUtil.base()
          |> path_dirname()
          |> join_and_normalize(ref_path)
      end

    with_optional_fragment(resolved_path, fragment)
  end

  defp absolute_uri?(value) when is_binary(value) do
    match?(%URI{scheme: scheme} when not is_nil(scheme), URI.parse(value))
  end

  defp absolute_uri?(_), do: false

  defp decode_target_pointer_path!(nil), do: []

  defp decode_target_pointer_path!(target_pointer) when is_binary(target_pointer) do
    case ExJSONPointer.decode_path(target_pointer) do
      {:ok, path} ->
        path

      {:error, reason} ->
        raise RuntimeError,
              "invalid internal target_pointer #{inspect(target_pointer)}: #{inspect(reason)}"
    end
  end

  defp normalize_root_target_pointer("#"), do: nil
  defp normalize_root_target_pointer(pointer), do: pointer

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

defmodule JSONSchex.ScopeScanner do
  @moduledoc """
  Scans raw schemas and containing documents to discover resource identifiers,
  anchors, and local fragment references for the selected draft.

  The resulting registry is used by `JSONSchex.Compiler` to populate the `defs`
  field in the compiled `Schema`, enabling reference resolution during validation.
  Traversal is delegated to draft-specific scanners; Draft 2020-12 is the default.

  ## Examples

      iex> schema = %{
      ...>   "$id" => "https://example.com/schema",
      ...>   "$defs" => %{
      ...>     "user" => %{"$id" => "user", "type" => "object"}
      ...>   }
      ...> }
      iex> {registry, _refs} = JSONSchex.ScopeScanner.scan(schema)
      iex> Map.has_key?(registry, "https://example.com/schema")
      true
      iex> Map.has_key?(registry, "https://example.com/user")
      true

  """

  @typedoc "Raw schema resources indexed by resolved URI."
  @type registry :: %{optional(String.t()) => map()}

  @typedoc "The resource registry and local fragment references from the initial traversal."
  @type scan_result :: {registry(), MapSet.t(String.t())}

  @doc """
  Scans a raw schema and returns a tuple `{registry, refs}` where:
  - `registry` is a map of `{absolute_uri => raw_schema}`.
  - `refs` is a MapSet of local fragment references found during the initial traversal.

  The `:draft` option defaults to `"draft2020_12"`. Use `"draft7"` to ignore
  `$ref` siblings and newer-draft annotations and scan tuple `additionalItems`.
  Both drafts honor `:base_uri` as the initial URI for resolving resource IDs;
  omitting it retains the default `nil` base. Draft 7 also expands the registry
  through explicitly referenced pointer targets within their owning resource,
  without scanning unrelated ignored content. Additional discovery does not add
  root-document aliases to `refs`.
  """
  @spec scan(map() | boolean(), keyword()) :: scan_result()
  def scan(schema, opts \\ []) do
    scanner = scanner(opts)
    scanner.scan(schema, opts)
  end

  @doc """
  Scans maps and lists in a containing document for JSON Schema resource
  identifiers and references.

  This is intentionally broader than `scan/1`: fragment compilation may receive
  an OpenAPI document whose schema objects live under arbitrary paths such as
  `components.schemas` or `paths.*.requestBody.content.*.schema`.
  The `:draft` option controls Draft 7 `$ref` sibling and newer-keyword handling.
  Draft 7 filtering applies in schema context, not to arbitrary document names.
  Schema context is inferred from keyword value shapes or inherited from schema
  slots. The compiler also passes the selected entry's decoded `:schema_path`
  so annotation-only entry schemas do not depend on inference. Draft 7 registers
  `$id` resources and collects `$ref` fragments only; `$anchor`, `$dynamicAnchor`,
  and `$dynamicRef` never contribute metadata, even in unclassified document maps.
  Draft 7 also discovers resources inside explicitly referenced pointer targets,
  retaining the containing document or embedded resource as the pointer root.
  Draft 2020-12 scans every map/list node without requiring roles or a selected
  schema path.
  """
  @spec scan_all(term(), String.t() | nil, keyword()) :: scan_result()
  def scan_all(document, base_uri \\ nil, opts \\ []) do
    scanner = scanner(opts)
    scanner.scan_all(document, base_uri, opts)
  end

  @spec scanner(keyword()) :: module()
  defp scanner(opts) do
    case Keyword.get(opts, :draft, "draft2020_12") do
      "draft7" -> JSONSchex.Draft7.ScopeScanner
      _ -> JSONSchex.Draft202012.ScopeScanner
    end
  end
end

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

  @doc """
  Scans a raw schema and returns a tuple `{registry, refs}` where:
  - `registry` is a map of `{absolute_uri => raw_schema}`.
  - `refs` is a MapSet of explicitly defined local fragment references.

  The `:draft` option defaults to `"draft2020_12"`. Use `"draft7"` to ignore
  `$ref` siblings and newer-draft annotations and scan tuple `additionalItems`.
  """
  def scan(schema, opts \\ []) do
    scanner = scanner(opts)
    scanner.scan(schema)
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
  Draft 2020-12 scans every map/list node without requiring roles or a selected
  schema path.
  """
  def scan_all(document, base_uri \\ nil, opts \\ []) do
    scanner = scanner(opts)
    scanner.scan_all(document, base_uri, opts)
  end

  defp scanner(opts) do
    case Keyword.get(opts, :draft, "draft2020_12") do
      "draft7" -> JSONSchex.Draft7.ScopeScanner
      _ -> JSONSchex.Draft202012.ScopeScanner
    end
  end
end

defmodule JSONSchex do
  @moduledoc """
  JSON Schema Draft 2020-12 validator for Elixir.

  Compile a schema once, then validate data against it repeatedly:

      iex> schema = %{"type" => "integer", "minimum" => 10}
      iex> {:ok, compiled} = JSONSchex.compile(schema)
      iex> JSONSchex.validate(compiled, 15)
      :ok
      iex> {:error, [error]} = JSONSchex.validate(compiled, 5)
      iex> error.rule
      :minimum
      iex> JSONSchex.format_error(error)
      "Value 5 is less than minimum 10"

  With format assertion:

      iex> schema = %{"type" => "string", "format" => "email"}
      iex> {:ok, compiled} = JSONSchex.compile(schema, format_assertion: true)
      iex> JSONSchex.validate(compiled, "user@example.com")
      :ok
      iex> {:error, [error]} = JSONSchex.validate(compiled, "not-an-email")
      iex> error.rule
      :format
      iex> JSONSchex.format_error(error)
      ~s(Invalid email format: "not-an-email")

  For compile-time schema embedding, see:

  - `JSONSchex.Schema` for the `compile!/2` macro
  - `JSONSchex.Sigil` for the `~X` sigil

  `use JSONSchex` imports the `~X` sigil as a convenience.
  """

  alias JSONSchex.Compiler
  alias JSONSchex.Validator
  alias JSONSchex.Types.{Schema, Error}

  @doc """
  Compiles a raw JSON Schema into a reusable `Schema` struct.

  ## Options

  - `:loader` — `(uri -> {:ok, map()} | {:error, term()})` for remote `$ref` schemas
  - `:base_uri` — Starting base URI for resolving relative references
  - `:format_assertion` — Enable strict `format` validation (default: `false`)
  - `:content_assertion` — Enable strict content vocabulary validation (default: `false`)

  See the [Loader guide](guide/loader.md) and
  [Content and Format guide](guide/content_and_format.md) for details.

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "string"})
      iex> is_struct(schema, JSONSchex.Types.Schema)
      true

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "string", "format" => "email"}, format_assertion: true)
      iex> JSONSchex.validate(schema, "test@example.com")
      :ok
  """
  @spec compile(map() | boolean()) :: {:ok, Schema.t()} | {:error, Error.t()}
  defdelegate compile(schema, opts \\ []), to: Compiler

  @doc """
  Compiles a JSON Schema fragment from a containing document.

  This is useful when a schema lives inside a larger resource, such as an
  OpenAPI 3.1 document, and local references like `#/components/schemas/User`
  must resolve against that containing document rather than against the fragment
  map in isolation.

  ## Options

  - `:entry` — JSON Pointer or URI-reference style entrypoint (`#/...`, `/...`, or `path-or-uri#/...`). If it includes a base URI/path and `:base_uri` is omitted, that base is used for relative reference resolution.
  - `:base_uri` — optional starting base URI/path for resolving relative references when `:entry` is a document-local pointer
  - `:loader` — optional loader for external resources. It may return `{:ok, schema}` or `{:ok, %{document: schema, base_uri: base_uri}}`; wrapper metadata uses atom keys only.
  - `:format_assertion` — Enable strict `format` validation (default: `false`)
  - `:content_assertion` — Enable strict content vocabulary validation (default: `false`)

  Use a document-local entry such as `"#/components/schemas/User"` when the
  containing document's base is supplied separately with `:base_uri` or when no
  relative external refs are reachable. Use a URI-reference entry such as
  `"/api/openapi.yaml#/components/schemas/User"` when the entrypoint and base
  URI/path can be represented together.

  ## Examples

      iex> document = %{
      ...>   "components" => %{"schemas" => %{"Name" => %{"type" => "string"}}},
      ...>   "schema" => %{"$ref" => "#/components/schemas/Name"}
      ...> }
      iex> {:ok, schema} = JSONSchex.compile_fragment(document, entry: "#/schema")
      iex> JSONSchex.validate(schema, "Ada")
      :ok
      iex> {:error, [%{rule: :type}]} = JSONSchex.validate(schema, 123)

      iex> document = %{"schema" => %{"type" => "integer"}}
      iex> {:ok, schema} = JSONSchex.compile_fragment(document, entry: "/api/openapi.yaml#/schema")
      iex> JSONSchex.validate(schema, 42)
      :ok
  """
  @spec compile_fragment(map() | boolean(), keyword()) :: {:ok, Schema.t()} | {:error, Error.t()}
  defdelegate compile_fragment(document, opts), to: Compiler

  @doc """
  Bundles a JSON Schema fragment from a containing document into a standalone raw schema.

  This uses the same entrypoint and reference-context options as `compile_fragment/2`,
  follows only the schema graph reachable from the entrypoint, mounts reachable
  external resources under `$defs`, and returns a raw JSON Schema map or boolean
  that can be compiled later with `compile/2`. External refs in unrelated containing-
  document subtrees, inactive definitions, examples, and extension data are not loaded.

  ## Generated definitions

  A map bundle may contain generated entries under `$defs` whose names start with
  `jsonschex_`. These entries are required storage locations for containing-document
  context, external resources, and reachable anchors. Their exact keys are internal,
  may receive a numeric suffix to avoid a caller-owned definition, and are not a
  stable API. Resources retain their reference identity through `$id` and anchors;
  callers should compile the complete returned bundle and must not construct refs to
  generated paths such as `#/$defs/jsonschex_external_1`.

  Existing caller-owned `$defs` entries are preserved. If generated resources are
  required, an existing `$defs` value must be a map; otherwise bundling returns an
  `invalid_defs` error instead of replacing it.

  When an anchor can only be discovered through opaque containing-document data,
  a unique declaration is treated as the anchor target because JSONSchex has no
  domain-specific knowledge of containers such as OpenAPI components or extensions.
  Multiple distinct locations declaring the same anchor are reported as an
  `ambiguous_anchor` error. The loader is not invoked for any ambiguous candidate.

  ## Examples

      iex> document = %{
      ...>   "components" => %{"schemas" => %{"Name" => %{"type" => "string"}}},
      ...>   "schema" => %{"$ref" => "#/components/schemas/Name"}
      ...> }
      iex> {:ok, bundled} = JSONSchex.bundle_fragment(document, entry: "#/schema")
      iex> {:ok, schema} = JSONSchex.compile(bundled)
      iex> JSONSchex.validate(schema, "Ada")
      :ok
  """
  @spec bundle_fragment(map() | boolean(), keyword()) :: {:ok, map() | boolean()} | {:error, Error.t()}
  defdelegate bundle_fragment(document, opts), to: Compiler

  @doc """
  Validates data against a compiled schema.

  Returns `:ok` or `{:error, [Error.t()]}`. Use `JSONSchex.format_error/1` on
  individual errors to produce human-readable messages.

  ## Examples

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "integer"})
      iex> JSONSchex.validate(schema, 42)
      :ok

      iex> {:ok, schema} = JSONSchex.compile(%{"type" => "integer"})
      iex> {:error, errors} = JSONSchex.validate(schema, "not an integer")
      iex> [error] = errors
      iex> error.rule
      :type
      iex> error.path
      []
      iex> JSONSchex.format_error(error)
      "Expected type integer, got string"
  """
  @spec validate(Schema.t(), term()) :: :ok | {:error, list(Error.t())}
  defdelegate validate(schema, data), to: Validator

  @doc """
  Formats a validation error into a human-readable string.

  ## Examples

      iex> error = %JSONSchex.Types.Error{path: ["age", "user"], rule: :minimum, context: %JSONSchex.Types.ErrorContext{contrast: 0, input: -5}}
      iex> JSONSchex.format_error(error)
      "At /user/age: Value -5 is less than minimum 0"

      iex> {:error, error} = JSONSchex.compile(%{"type" => "1"})
      iex> JSONSchex.format_error(error)
      ~s(Keyword 'type' must be one of [string, integer, number, boolean, object, array, null], got: "1")

      iex> {:error, error} = JSONSchex.compile(%{"minimum" => "five"})
      iex> JSONSchex.format_error(error)
      ~s(Keyword 'minimum' must be a number, got: "five")

      iex> {:error, error} = JSONSchex.compile(%{"multipleOf" => -3})
      iex> JSONSchex.format_error(error)
      ~s(Keyword 'multipleOf' must be a strictly positive number, got: -3)

      iex> {:error, error} = JSONSchex.compile(%{"minLength" => -1})
      iex> JSONSchex.format_error(error)
      ~s(Keyword 'minLength' must be a non-negative integer, got: -1)

      iex> {:error, error} = JSONSchex.compile(%{"uniqueItems" => "yes"})
      iex> JSONSchex.format_error(error)
      ~s(Keyword 'uniqueItems' must be a boolean, got: "yes")
  """
  @spec format_error(Error.t()) :: String.t()
  defdelegate format_error(error), to: JSONSchex.ErrorFormatter, as: :format

  @doc """
  Imports the `~X` sigil for compile-time schema literals.

  For the explicit API, use `JSONSchex.Sigil` directly.
  """
  defmacro __using__(_opts) do
    quote do
      import JSONSchex.Sigil, only: [sigil_X: 2]
    end
  end
end

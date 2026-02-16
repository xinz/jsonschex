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
      "Format mismatch: email"
  """

  alias JSONSchex.Compiler
  alias JSONSchex.Validator
  alias JSONSchex.Types.{Schema, Error}

  @doc """
  Compiles a raw JSON Schema into a reusable `Schema` struct.

  ## Options

  - `:external_loader` — `(uri -> {:ok, map()} | {:error, term()})` for remote `$ref` schemas
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
  @spec compile(map() | boolean()) :: {:ok, Schema.t()} | {:error, JSONSchex.Types.CompileError.t()}
  defdelegate compile(schema, opts \\ []), to: Compiler

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
      "Expected type \\"integer\\", got \\"string\\""

  """
  @spec validate(Schema.t(), term()) :: :ok | {:error, list(Error.t())}
  defdelegate validate(schema, data), to: Validator

  @doc """
  Formats a validation error into a human-readable string.

  ## Examples

      iex> error = %JSONSchex.Types.Error{path: ["age", "user"], rule: :minimum, context: %{minimum: 0, actual: -5}}
      iex> JSONSchex.format_error(error)
      "At /user/age: Value -5 is less than minimum 0"

  """
  @spec format_error(Error.t()) :: String.t()
  defdelegate format_error(error), to: JSONSchex.ErrorFormatter, as: :format
end

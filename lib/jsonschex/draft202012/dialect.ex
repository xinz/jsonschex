defmodule JSONSchex.Draft202012.Dialect do
  @moduledoc """
  Draft 2020-12 dialect helpers for built-in dialect recognition and
  `$vocabulary` resolution.

  This module centralizes the Draft 2020-12-specific pieces that were previously
  embedded in the generic compiler flow:

  - recognition of the canonical Draft 2020-12 meta-schema URI
  - default active vocabularies for the built-in Draft 2020-12 dialect
  - extraction of enabled vocabularies from a meta-schema's `$vocabulary`
  - validation of required vocabularies against the implementation capability set
  - built-in dialect resolution for compiler delegation

  It is intentionally small and data-oriented so generic compiler code can
  delegate draft-specific decisions here.

  ## Examples

      iex> JSONSchex.Draft202012.Dialect.builtin_schema_uri()
      "https://json-schema.org/draft/2020-12/schema"

      iex> JSONSchex.Draft202012.Dialect.builtin_schema?(%{"$schema" => "https://json-schema.org/draft/2020-12/schema"})
      true

      iex> JSONSchex.Draft202012.Dialect.enabled_vocabularies(%{
      ...>   "$vocabulary" => %{
      ...>     "https://json-schema.org/draft/2020-12/vocab/core" => true,
      ...>     "https://json-schema.org/draft/2020-12/vocab/format-annotation" => false
      ...>   }
      ...> })
      ["https://json-schema.org/draft/2020-12/vocab/core",
       "https://json-schema.org/draft/2020-12/vocab/format-annotation"]

      iex> JSONSchex.Draft202012.Dialect.resolve_builtin(%{"$schema" => "https://json-schema.org/draft/2020-12/schema"})
      {:ok,
       ["https://json-schema.org/draft/2020-12/vocab/core",
        "https://json-schema.org/draft/2020-12/vocab/applicator",
        "https://json-schema.org/draft/2020-12/vocab/validation",
        "https://json-schema.org/draft/2020-12/vocab/unevaluated",
        "https://json-schema.org/draft/2020-12/vocab/format-annotation",
        "https://json-schema.org/draft/2020-12/vocab/content",
        "https://json-schema.org/draft/2020-12/vocab/meta-data"]}

      iex> JSONSchex.Draft202012.Dialect.resolve_builtin(%{"$schema" => "https://example.com/custom"})
      nil
  """

  alias JSONSchex.Draft202012.Vocabulary
  alias JSONSchex.Types.Error

  @base_uri "https://json-schema.org/draft/2020-12"
  @builtin_schema_uri @base_uri <> "/schema"
  @supported_vocabularies Vocabulary.defaults()
  @default_active_vocabularies Vocabulary.draft2020_12_defaults()

  @doc """
  Returns the canonical base URI for Draft 2020-12 resources.
  """
  @spec base_uri() :: String.t()
  def base_uri, do: @base_uri

  @doc """
  Returns the canonical built-in Draft 2020-12 meta-schema URI.
  """
  @spec builtin_schema_uri() :: String.t()
  def builtin_schema_uri, do: @builtin_schema_uri

  @doc """
  Returns `true` when the given schema declares the canonical built-in
  Draft 2020-12 meta-schema URI.
  """
  @spec builtin_schema?(map()) :: boolean()
  def builtin_schema?(%{"$schema" => @builtin_schema_uri}), do: true
  def builtin_schema?(_), do: false

  @doc """
  Returns the full set of vocabularies supported by the implementation for
  Draft 2020-12 vocabulary validation.
  """
  @spec supported_vocabularies() :: list(String.t())
  def supported_vocabularies, do: @supported_vocabularies

  @doc """
  Returns the default active vocabularies for the built-in Draft 2020-12
  dialect.

  This excludes `format-assertion`, matching the standard Draft 2020-12
  behavior.
  """
  @spec default_active_vocabularies() :: list(String.t())
  def default_active_vocabularies, do: @default_active_vocabularies

  @doc """
  Resolves the built-in Draft 2020-12 dialect for a schema.

  Returns `{:ok, vocabularies}` when the schema declares the canonical built-in
  Draft 2020-12 meta-schema URI, otherwise returns `nil`.
  """
  @spec resolve_builtin(map()) :: {:ok, list(String.t())} | nil
  def resolve_builtin(schema) when is_map(schema) do
    if builtin_schema?(schema) do
      {:ok, enabled_vocabularies(schema, default_active_vocabularies())}
    else
      nil
    end
  end

  def resolve_builtin(_), do: nil

  @doc """
  Returns the enabled vocabularies for a schema.

  If the schema declares `$vocabulary`, required vocabularies are always
  included, and optional vocabularies are included only when they are supported
  by the implementation. If `$vocabulary` is absent, the provided defaults are
  returned unchanged.
  """
  @spec enabled_vocabularies(map(), list(String.t())) :: list(String.t())
  def enabled_vocabularies(%{"$vocabulary" => vocabs_def}, _defaults) when is_map(vocabs_def) do
    vocabs_def
    |> Enum.filter(fn
      {_, true} -> true
      {uri, false} -> vocabulary_supported?(uri)
      _ -> false
    end)
    |> Enum.map(fn {uri, _required} -> uri end)
  end

  def enabled_vocabularies(_schema, defaults), do: defaults

  @doc """
  Validates that all required vocabularies declared by the schema are supported.

  Returns `:ok` when valid, otherwise returns a structured
  `:unsupported_vocabulary` error.
  """
  @spec validate_required_vocabularies(map()) :: :ok | {:error, Error.t()}
  def validate_required_vocabularies(%{"$vocabulary" => vocab}) when is_map(vocab) do
    Enum.reduce_while(vocab, :ok, fn {uri, required}, :ok ->
      if required == true and not vocabulary_supported?(uri) do
        {:halt, {:error, %Error{rule: :unsupported_vocabulary, path: ["$vocabulary", uri], value: true}}}
      else
        {:cont, :ok}
      end
    end)
  end

  def validate_required_vocabularies(_schema), do: :ok

  @doc """
  Returns `true` if the given vocabulary URI is supported by the implementation.
  """
  @spec vocabulary_supported?(String.t()) :: boolean()
  def vocabulary_supported?(uri) when is_binary(uri), do: uri in @supported_vocabularies
  def vocabulary_supported?(_), do: false
end
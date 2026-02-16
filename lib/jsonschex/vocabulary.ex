defmodule JSONSchex.Vocabulary do
  @moduledoc """
  Maps JSON Schema keywords to their Draft 2020-12 vocabulary URIs and defines
  the default vocabulary list.

  Used by `JSONSchex.Compiler` to check whether a keyword is allowed based on the
  active vocabulary set, and to resolve `$vocabulary` declarations.

  ## Examples

      iex> JSONSchex.Vocabulary.keyword("type")
      "https://json-schema.org/draft/2020-12/vocab/validation"

      iex> JSONSchex.Vocabulary.keyword("properties")
      "https://json-schema.org/draft/2020-12/vocab/applicator"

      iex> JSONSchex.Vocabulary.keyword("unknown")
      nil

  """

  @vocab_core "https://json-schema.org/draft/2020-12/vocab/core"
  @vocab_applicator "https://json-schema.org/draft/2020-12/vocab/applicator"
  @vocab_validation "https://json-schema.org/draft/2020-12/vocab/validation"
  @vocab_unevaluated "https://json-schema.org/draft/2020-12/vocab/unevaluated"
  @vocab_format_annotation "https://json-schema.org/draft/2020-12/vocab/format-annotation"
  @vocab_format_assertion "https://json-schema.org/draft/2020-12/vocab/format-assertion"
  @vocab_content "https://json-schema.org/draft/2020-12/vocab/content"
  @vocab_meta_data "https://json-schema.org/draft/2020-12/vocab/meta-data"

  @known_vocabularies [
    @vocab_core,
    @vocab_applicator,
    @vocab_validation,
    @vocab_unevaluated,
    @vocab_format_annotation,
    @vocab_format_assertion,
    @vocab_content,
    @vocab_meta_data
  ]

  @doc """
  Returns the list of default vocabularies supported by JSONSchex for Draft 2020-12.
  """
  @spec defaults() :: list()
  def defaults(), do: @known_vocabularies

  @doc "Returns the format-annotation vocabulary URI."
  def format_annotation(), do: @vocab_format_annotation

  @doc "Returns the format-assertion vocabulary URI."
  def format_assertion(), do: @vocab_format_assertion

  @doc """
  Returns the vocabulary URI for a given JSON Schema keyword, or `nil` if unknown.
  """

  def keyword("$id"), do: @vocab_core
  def keyword("$schema"), do: @vocab_core
  def keyword("$ref"), do: @vocab_core
  def keyword("$anchor"), do: @vocab_core
  def keyword("$dynamicRef"), do: @vocab_core
  def keyword("$dynamicAnchor"), do: @vocab_core
  def keyword("$vocabulary"), do: @vocab_core
  def keyword("$comment"), do: @vocab_core
  def keyword("$defs"), do: @vocab_core

  def keyword("type"), do: @vocab_validation
  def keyword("enum"), do: @vocab_validation
  def keyword("const"), do: @vocab_validation
  def keyword("multipleOf"), do: @vocab_validation
  def keyword("maximum"), do: @vocab_validation
  def keyword("minimum"), do: @vocab_validation
  def keyword("exclusiveMaximum"), do: @vocab_validation
  def keyword("exclusiveMinimum"), do: @vocab_validation
  def keyword("maxLength"), do: @vocab_validation
  def keyword("minLength"), do: @vocab_validation
  def keyword("pattern"), do: @vocab_validation
  def keyword("maxItems"), do: @vocab_validation
  def keyword("minItems"), do: @vocab_validation
  def keyword("uniqueItems"), do: @vocab_validation
  def keyword("maxContains"), do: @vocab_validation
  def keyword("minContains"), do: @vocab_validation
  def keyword("maxProperties"), do: @vocab_validation
  def keyword("minProperties"), do: @vocab_validation
  def keyword("required"), do: @vocab_validation
  def keyword("dependentRequired"), do: @vocab_validation

  def keyword("prefixItems"), do: @vocab_applicator
  def keyword("items"), do: @vocab_applicator
  def keyword("contains"), do: @vocab_applicator
  def keyword("additionalProperties"), do: @vocab_applicator
  def keyword("properties"), do: @vocab_applicator
  def keyword("patternProperties"), do: @vocab_applicator
  def keyword("dependentSchemas"), do: @vocab_applicator
  def keyword("propertyNames"), do: @vocab_applicator
  def keyword("if"), do: @vocab_applicator
  def keyword("then"), do: @vocab_applicator
  def keyword("else"), do: @vocab_applicator
  def keyword("allOf"), do: @vocab_applicator
  def keyword("oneOf"), do: @vocab_applicator
  def keyword("anyOf"), do: @vocab_applicator
  def keyword("not"), do: @vocab_applicator

  def keyword("unevaluatedItems"), do: @vocab_unevaluated
  def keyword("unevaluatedProperties"), do: @vocab_unevaluated

  def keyword("format"), do: @vocab_format_annotation

  def keyword("title"), do: @vocab_meta_data
  def keyword("description"), do: @vocab_meta_data
  def keyword("default"), do: @vocab_meta_data
  def keyword("deprecated"), do: @vocab_meta_data
  def keyword("readOnly"), do: @vocab_meta_data
  def keyword("writeOnly"), do: @vocab_meta_data
  def keyword("examples"), do: @vocab_meta_data

  def keyword("contentMediaType"), do: @vocab_content
  def keyword("contentEncoding"), do: @vocab_content
  def keyword("contentSchema"), do: @vocab_content

  def keyword(_), do: nil

end

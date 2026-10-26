defmodule JSONSchex.Draft7.Dialect do
  @moduledoc """
  Identifies the Draft 7 meta-schema and the keywords defined by that draft.

  Draft 7 predates `$vocabulary`, so it uses a keyword set rather than the
  Draft 2020-12 vocabulary URI map.
  """

  @base_uri "http://json-schema.org/draft-07/schema"
  @schema_uri @base_uri <> "#"

  @keywords MapSet.new(~w(
    $schema $id $ref $comment definitions
    type enum const multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
    maxLength minLength pattern maxItems minItems uniqueItems
    maxProperties minProperties required
    items additionalItems contains additionalProperties properties patternProperties
    dependencies propertyNames if then else allOf anyOf oneOf not
    format contentMediaType contentEncoding
    title description default readOnly writeOnly examples
  ))

  @doc "Returns the Draft 7 meta-schema URI without a fragment."
  def base_uri, do: @base_uri

  @doc "Returns the canonical Draft 7 meta-schema URI."
  def schema_uri, do: @schema_uri

  @doc "Recognizes the canonical Draft 7 meta-schema URI, with or without `#`."
  def builtin_schema?(%{"$schema" => uri}) when uri in [@base_uri, @schema_uri], do: true
  def builtin_schema?(_), do: false

  @doc "Returns whether a keyword belongs to Draft 7. Unknown keywords are annotations."
  def keyword?(keyword) when is_binary(keyword), do: MapSet.member?(@keywords, keyword)
  def keyword?(_), do: false
end

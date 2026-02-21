defmodule JSONSchex.Formats do
  @moduledoc """
  Implements validation logic for the 'format' keyword.

  ## Supported Formats

  The following format values are supported when `format_assertion: true` is enabled:

  - Date/Time: `date-time`, `date`, `time`, `duration`
  - Email: `email`, `idn-email`
  - Hostnames: `hostname`, `idn-hostname`
  - IP Addresses: `ipv4`, `ipv6`
  - URIs: `uri`, `uri-reference`, `iri`, `iri-reference`, `uri-template`
  - Identifiers: `uuid`
  - JSON Pointers: `json-pointer`, `relative-json-pointer`
  - Patterns: `regex`

  ## Behavior

  - Non-string data always passes format validation.
  - Unknown format values pass validation by default (per the JSON Schema specification).
  """

  @doc """
  Validates data against the specified format.

  Non-string data always passes. Unknown format values pass by default.

  ## Examples

      iex> JSONSchex.Formats.validate("email", "user@example.com")
      :ok

      iex> JSONSchex.Formats.validate("email", "not-an-email")
      {:error, "Format mismatch: email"}

      iex> JSONSchex.Formats.validate("email", 123)
      :ok

  """

  def validate(format, data) when is_binary(data) do
    if valid?(format, data), do: :ok, else: {:error, "Format mismatch: #{format}"}
  end
  def validate(_, _), do: :ok

  defp valid?("date-time", data) do
    JSONSchex.Formats.DateTime.valid?(data)
  end

  defp valid?("date", data) do
    match?({:ok, _}, Date.from_iso8601(data))
  end

  defp valid?("time", data) do
    JSONSchex.Formats.Time.valid?(data)
  end

  defp valid?("duration", data) do
    # ISO 8601 duration
    # weeks cannot be combined with other units.
    Regex.match?(~r/^P\d+W$/, data) or
      Regex.match?(~r/^P(?!$)((\d+Y)?(\d+M)?(\d+D)?)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$/, data)
  end

  defp valid?("email", data) do
    JSONSchex.Formats.Email.valid?(data)
  end

  defp valid?("idn-email", data) do
    JSONSchex.Formats.Email.valid_idn?(data)
  end

  defp valid?("hostname", data) do
    JSONSchex.Formats.Hostname.valid?(data)
  end

  defp valid?("idn-hostname", data) do
    JSONSchex.Formats.Hostname.valid_idn?(data)
  end

  defp valid?("ipv4", data) do
    JSONSchex.Formats.IP.valid_ipv4?(data)
  end

  defp valid?("ipv6", data) do
    JSONSchex.Formats.IP.valid_ipv6?(data)
  end

  defp valid?("uri", data) do
    match?({:ok, %URI{scheme: s}} when s != nil and s != "", URI.new(data))
  end

  defp valid?("uri-reference", data) do
    match?({:ok, _}, URI.new(data))
  end

  defp valid?("iri", data) do
    uri_string = replace_non_ascii_chars_by_uri_encode(data)
    valid?("uri", uri_string)
  end

  defp valid?("iri-reference", data) do
    uri_string = replace_non_ascii_chars_by_uri_encode(data)
    valid?("uri-reference", uri_string)
  end

  defp valid?("uri-template", data) do
    JSONSchex.Formats.URITemplate.valid?(data)
  end

  defp valid?("uuid", data) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, data)
  end

  defp valid?("json-pointer", data) do
    ExJSONPointer.valid_json_pointer?(data)
  end

  defp valid?("relative-json-pointer", data) do
    ExJSONPointer.valid_relative_json_pointer?(data)
  end

  defp valid?("regex", data) do
    JSONSchex.Formats.Regex.valid?(data)
  end

  defp valid?(_, _), do: true # Unknown formats pass by default

  defp replace_non_ascii_chars_by_uri_encode(data) do
    Regex.replace(~r/[^\x00-\x7F]/u, data, fn c ->
      URI.encode(c)
    end)
  end
end

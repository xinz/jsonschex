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

  import JSONSchex.Guards, only: [is_ascii_digit?: 1, is_ascii_hex?: 1]

  alias JSONSchex.Types.ErrorContext

  @doc """
  Validates data against the specified format.

  Non-string data always passes. Unknown format values pass by default.

  ## Examples

      iex> JSONSchex.Formats.validate("email", "user@example.com")
      :ok

      iex> JSONSchex.Formats.validate("email", "not-an-email")
      {:error, %JSONSchex.Types.ErrorContext{contrast: "email", input: "not-an-email"}}

      iex> JSONSchex.Formats.validate("email", 123)
      :ok

  """

  def validate(format, data) when is_binary(data) do
    if format_valid?(format, data), do: :ok, else: {:error, %ErrorContext{contrast: format, input: data}}
  end
  def validate(_, _), do: :ok

  @doc false
  @spec valid?(String.t(), term()) :: boolean()
  def valid?(format, data) when is_binary(data), do: format_valid?(format, data)
  def valid?(_, _), do: true

  defp format_valid?("date-time", data) do
    JSONSchex.Formats.DateTime.valid?(data)
  end

  # RFC 3339 `full-date` requires exactly four unsigned year digits. Elixir's
  # `Date.from_iso8601/1` also accepts signed years, so validate the lexical form
  # before delegating calendar and leap-year checks to `Date`.
  defp format_valid?("date", <<y1, y2, y3, y4, ?-, m1, m2, ?-, d1, d2>> = data)
       when is_ascii_digit?(y1) and is_ascii_digit?(y2) and is_ascii_digit?(y3) and is_ascii_digit?(y4) and
              is_ascii_digit?(m1) and is_ascii_digit?(m2) and is_ascii_digit?(d1) and is_ascii_digit?(d2) do
    match?({:ok, _}, Date.from_iso8601(data))
  end

  defp format_valid?("date", _data), do: false

  defp format_valid?("time", data) do
    JSONSchex.Formats.DateTime.valid_time?(data)
  end

  defp format_valid?("duration", <<?P, rest::binary>>) when rest != <<>> do
    # RFC 3339 Appendix A duration grammar.
    # Weeks cannot be combined with other units.
    # Date ordering is constrained to Y -> M -> D, but D cannot appear unless M is present
    # when Y is also present. Time ordering is constrained to H -> M -> S, but S cannot
    # appear unless M is present when H is also present.
    case rest do
      <<?T, time_rest::binary>> -> parse_duration_time(time_rest, :h, false)
      _ -> parse_duration_date_or_week(rest)
    end
  end

  defp format_valid?("duration", _data), do: false

  defp format_valid?("email", data) do
    JSONSchex.Formats.Email.valid?(data)
  end

  defp format_valid?("idn-email", data) do
    JSONSchex.Formats.Email.valid_idn?(data)
  end

  defp format_valid?("hostname", data) do
    JSONSchex.Formats.Hostname.valid?(data)
  end

  defp format_valid?("idn-hostname", data) do
    JSONSchex.Formats.Hostname.valid_idn?(data)
  end

  defp format_valid?("ipv4", data) do
    JSONSchex.Formats.IP.valid_ipv4?(data)
  end

  defp format_valid?("ipv6", data) do
    JSONSchex.Formats.IP.valid_ipv6?(data)
  end

  defp format_valid?("uri", data) do
    valid_percent_encoding?(data) and
      match?({:ok, %URI{scheme: s}} when s != nil and s != "", URI.new(data))
  end

  defp format_valid?("uri-reference", data) do
    valid_percent_encoding?(data) and
      match?({:ok, _}, URI.new(data))
  end

  defp format_valid?("iri", data) do
    uri_string = replace_non_ascii_chars_by_uri_encode(data)
    format_valid?("uri", uri_string)
  end

  defp format_valid?("iri-reference", data) do
    uri_string = replace_non_ascii_chars_by_uri_encode(data)
    format_valid?("uri-reference", uri_string)
  end

  defp format_valid?("uri-template", data) do
    JSONSchex.Formats.URITemplate.valid?(data)
  end

  defp format_valid?(
         "uuid",
         <<a1, a2, a3, a4, a5, a6, a7, a8, ?-, b1, b2, b3, b4, ?-, c1, c2, c3, c4, ?-,
           d1, d2, d3, d4, ?-, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12>>
       )
       when is_ascii_hex?(a1) and is_ascii_hex?(a2) and is_ascii_hex?(a3) and is_ascii_hex?(a4) and
              is_ascii_hex?(a5) and is_ascii_hex?(a6) and is_ascii_hex?(a7) and is_ascii_hex?(a8) and
              is_ascii_hex?(b1) and is_ascii_hex?(b2) and is_ascii_hex?(b3) and is_ascii_hex?(b4) and
              is_ascii_hex?(c1) and is_ascii_hex?(c2) and is_ascii_hex?(c3) and is_ascii_hex?(c4) and
              is_ascii_hex?(d1) and is_ascii_hex?(d2) and is_ascii_hex?(d3) and is_ascii_hex?(d4) and
              is_ascii_hex?(e1) and is_ascii_hex?(e2) and is_ascii_hex?(e3) and is_ascii_hex?(e4) and
              is_ascii_hex?(e5) and is_ascii_hex?(e6) and is_ascii_hex?(e7) and is_ascii_hex?(e8) and
              is_ascii_hex?(e9) and is_ascii_hex?(e10) and is_ascii_hex?(e11) and is_ascii_hex?(e12),
       do: true

  defp format_valid?("uuid", _data), do: false

  defp format_valid?("json-pointer", data) do
    ExJSONPointer.valid_json_pointer?(data)
  end

  defp format_valid?("relative-json-pointer", data) do
    Regex.match?(~r/\A(?:0|[1-9][0-9]*)(?:[+-](?:0|[1-9][0-9]*))?(?:\/(?:[^#].*)?|#)?\z/s, data) and
      ExJSONPointer.valid_relative_json_pointer?(data)
  end

  defp format_valid?("regex", data) do
    JSONSchex.Formats.Regex.valid?(data)
  end

  defp format_valid?(_, _), do: true # Unknown formats pass by default

  defp replace_non_ascii_chars_by_uri_encode(data) do
    Regex.replace(~r/[^\x00-\x7F]/u, data, fn c ->
      URI.encode(c)
    end)
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<?%, h1, h2, rest::binary>>)
       when is_ascii_hex?(h1) and is_ascii_hex?(h2),
       do: valid_percent_encoding?(rest)

  defp valid_percent_encoding?(<<?%, _::binary>>), do: false
  defp valid_percent_encoding?(<<_, rest::binary>>), do: valid_percent_encoding?(rest)

  defp parse_duration_date_or_week(bin) do
    case consume_digits(bin) do
      {:ok, <<?W>>} -> true
      {:ok, <<?Y, rest::binary>>} -> parse_duration_after_y(rest)
      {:ok, <<?M, rest::binary>>} -> parse_duration_after_m(rest)
      {:ok, <<?D, rest::binary>>} -> parse_duration_after_d(rest)
      _ -> false
    end
  end

  defp parse_duration_after_y(<<>>), do: true
  defp parse_duration_after_y(<<?T, rest::binary>>), do: parse_duration_time(rest, :h, false)

  defp parse_duration_after_y(bin) do
    case consume_digits(bin) do
      {:ok, <<?M, rest::binary>>} -> parse_duration_after_m(rest)
      _ -> false
    end
  end

  defp parse_duration_after_m(<<>>), do: true
  defp parse_duration_after_m(<<?T, rest::binary>>), do: parse_duration_time(rest, :h, false)

  defp parse_duration_after_m(bin) do
    case consume_digits(bin) do
      {:ok, <<?D, rest::binary>>} -> parse_duration_after_d(rest)
      _ -> false
    end
  end

  defp parse_duration_after_d(<<>>), do: true
  defp parse_duration_after_d(<<?T, rest::binary>>), do: parse_duration_time(rest, :h, false)
  defp parse_duration_after_d(_), do: false

  defp parse_duration_time(<<>>, _stage, seen_any), do: seen_any

  defp parse_duration_time(bin, :h, false) do
    case consume_digits(bin) do
      {:ok, <<?H, rest::binary>>} -> parse_duration_time(rest, :m, true)
      {:ok, <<?M, rest::binary>>} -> parse_duration_time(rest, :s, true)
      {:ok, <<?S>>} -> true
      _ -> false
    end
  end

  defp parse_duration_time(bin, :m, true) do
    case consume_digits(bin) do
      {:ok, <<?M, rest::binary>>} -> parse_duration_time(rest, :s, true)
      _ -> false
    end
  end

  defp parse_duration_time(bin, :s, true) do
    case consume_digits(bin) do
      {:ok, <<?S>>} -> true
      _ -> false
    end
  end

  defp parse_duration_time(_, _, _), do: false

  defp consume_digits(<<d, rest::binary>>) when is_ascii_digit?(d), do: {:ok, skip_digits(rest)}
  defp consume_digits(_), do: :error

  defp skip_digits(<<d, rest::binary>>) when is_ascii_digit?(d), do: skip_digits(rest)
  defp skip_digits(rest), do: rest
end

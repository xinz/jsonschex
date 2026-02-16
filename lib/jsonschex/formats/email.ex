defmodule JSONSchex.Formats.Email do
  @moduledoc """
  Validates `email` format according to RFC 5322 (Addr-Spec).
  Includes support for quoted strings in local part and IP literals in domain.
  """

  def valid?(data) when is_binary(data) and byte_size(data) > 254 do
    false
  end
  def valid?(data) when is_binary(data) do
    # Fast path: use :binary.split to find the last "@" without allocating
    # intermediate lists via String.split + List.pop_at + Enum.join.
    case split_local_domain(data) do
      {local, domain} -> validate_local(local) and validate_domain(domain)
      :error -> false
    end
  end

  def valid?(_), do: true

  def valid_idn?(data) when is_binary(data) and byte_size(data) > 254 do
    false
  end

  def valid_idn?(data) when is_binary(data) do
    case split_local_domain(data) do
      {local, domain} -> validate_local_idn(local) and validate_domain_idn(domain)
      :error -> false
    end
  end

  def valid_idn?(_), do: true

  # Splits an email into {local_part, domain} at the last "@".
  # Returns :error if there is no "@".
  defp split_local_domain(data) do
    case :binary.matches(data, "@") do
      [] ->
        :error

      [{pos, 1}] ->
        # Common case: exactly one "@" — zero-copy split
        <<local::binary-size(pos), ?@, domain::binary>> = data
        {local, domain}

      matches ->
        # Multiple "@" signs — split at the last one
        {pos, 1} = List.last(matches)
        <<local::binary-size(pos), ?@, domain::binary>> = data
        {local, domain}
    end
  end

  defp validate_local(local) when byte_size(local) == 0, do: false
  defp validate_local(local) when byte_size(local) > 64, do: false
  defp validate_local("\"" <> _ = local) do
    if String.ends_with?(local, "\"") do
      validate_quoted_local(local)
    else
      validate_unquoted_local(local)
    end
  end
  defp validate_local(local), do: validate_unquoted_local(local)

  defp validate_quoted_local("\"\""), do: false
  defp validate_quoted_local(local) do
    # Remove surrounding quotes
    inner = String.slice(local, 1..-2//1)
    validate_quoted_inner(inner)
  end

  # Valid: reached end of quoted content
  defp validate_quoted_inner(<<>>), do: true
  # Escaped character: skip the backslash and the following char
  defp validate_quoted_inner(<<?\\, _, rest::binary>>), do: validate_quoted_inner(rest)
  # Bare backslash at end or bare quote — invalid
  defp validate_quoted_inner(<<?\\>>), do: false
  defp validate_quoted_inner(<<?", _::binary>>), do: false
  # Any other character is allowed
  defp validate_quoted_inner(<<_, rest::binary>>), do: validate_quoted_inner(rest)

  defp validate_unquoted_local(local) do
    case local do
      # Leading dot
      <<?., _::binary>> -> false
      _ -> validate_unquoted_local_chars(local, false)
    end
  end

  # Reached end of string: valid only if we saw at least one char and last wasn't a dot
  defp validate_unquoted_local_chars(<<>>, _prev_dot), do: true

  # Dot handling: reject trailing dot (handled by reaching end after dot)
  # and consecutive dots
  defp validate_unquoted_local_chars(<<?., _::binary>>, true = _prev_was_dot), do: false
  defp validate_unquoted_local_chars(<<?., rest::binary>>, _prev_dot) do
    case rest do
      <<>> -> false  # trailing dot
      _ -> validate_unquoted_local_chars(rest, true)
    end
  end

  # Alphanumeric ranges (most common chars — checked first for speed)
  defp validate_unquoted_local_chars(<<c, rest::binary>>, _prev_dot)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 do
    validate_unquoted_local_chars(rest, false)
  end

  # Special characters allowed in unquoted local part (RFC 5321 atext)
  defp validate_unquoted_local_chars(<<c, rest::binary>>, _prev_dot)
       when c == ?! or c == ?# or c == ?$ or c == ?% or c == ?& or c == ?' or
            c == ?* or c == ?+ or c == ?- or c == ?/ or c == ?= or c == ?? or
            c == ?^ or c == ?_ or c == ?` or c == ?{ or c == ?| or c == ?} or
            c == ?~ do
    validate_unquoted_local_chars(rest, false)
  end

  # Any other character is invalid
  defp validate_unquoted_local_chars(_, _), do: false

  defp validate_local_idn(local) when byte_size(local) == 0, do: false

  defp validate_local_idn("\"" <> _ = local) do
    if String.ends_with?(local, "\"") do
      validate_quoted_local_idn(local)
    else
      validate_unquoted_local_idn(local)
    end
  end

  defp validate_local_idn(local), do: validate_unquoted_local_idn(local)

  defp validate_quoted_local_idn(local) do
    inner = String.slice(local, 1..-2//1)
    validate_quoted_inner(inner)
  end

  defp validate_unquoted_local_idn(local) do
    case local do
      <<?., _::binary>> -> false
      _ -> validate_unquoted_local_idn_chars(local, false)
    end
  end

  defp validate_unquoted_local_idn_chars(<<>>, _prev_dot), do: true

  defp validate_unquoted_local_idn_chars(<<?., _::binary>>, true = _prev_was_dot), do: false
  defp validate_unquoted_local_idn_chars(<<?., rest::binary>>, _prev_dot) do
    case rest do
      <<>> -> false
      _ -> validate_unquoted_local_idn_chars(rest, true)
    end
  end

  # ASCII alphanumeric
  defp validate_unquoted_local_idn_chars(<<c, rest::binary>>, _prev_dot)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 do
    validate_unquoted_local_idn_chars(rest, false)
  end

  # ASCII atext special characters
  defp validate_unquoted_local_idn_chars(<<c, rest::binary>>, _prev_dot)
       when c == ?! or c == ?# or c == ?$ or c == ?% or c == ?& or c == ?' or
            c == ?* or c == ?+ or c == ?- or c == ?/ or c == ?= or c == ?? or
            c == ?^ or c == ?_ or c == ?` or c == ?{ or c == ?| or c == ?} or
            c == ?~ do
    validate_unquoted_local_idn_chars(rest, false)
  end

  # Non-ASCII UTF-8 characters (byte >= 128 starts a multi-byte sequence)
  defp validate_unquoted_local_idn_chars(<<c, rest::binary>>, _prev_dot) when c > 127 do
    validate_unquoted_local_idn_chars(rest, false)
  end

  defp validate_unquoted_local_idn_chars(_, _), do: false

  defp validate_domain(""), do: false
  defp validate_domain(domain) when byte_size(domain) > 255, do: false
  defp validate_domain(domain) do
    if String.starts_with?(domain, "[") and String.ends_with?(domain, "]") do
      inner = String.slice(domain, 1..-2//1)
      validate_literal_domain(inner)
    else
      validate_hostname_domain(domain)
    end
  end

  defp validate_literal_domain("IPv6:" <> ip_str) do
    JSONSchex.Formats.IP.valid_ipv6?(ip_str)
  end

  defp validate_literal_domain(domain) do
    JSONSchex.Formats.IP.valid_ipv4?(domain)
  end

  defp validate_hostname_domain(domain) do
    JSONSchex.Formats.Hostname.valid?(domain)
  end

  defp validate_domain_idn(""), do: false
  defp validate_domain_idn(domain) when byte_size(domain) > 255, do: false

  defp validate_domain_idn(domain) do
    if String.starts_with?(domain, "[") and String.ends_with?(domain, "]") do
      inner = String.slice(domain, 1..-2//1)
      validate_literal_domain(inner)
    else
      JSONSchex.Formats.Hostname.valid_idn?(domain)
    end
  end
end

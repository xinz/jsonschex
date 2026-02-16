defmodule JSONSchex.Formats.Hostname do
  @moduledoc """
  Validates "hostname" format according to RFC 1123.
  """

  def valid?(data) when is_binary(data) do
    if not is_ascii?(data) do
      false
    else
      validate_ascii_hostname(data)
    end
  end

  def valid?(_), do: true

  if Code.ensure_loaded?(:idna) do
    def valid_idn?(data) when is_binary(data) do
      # 4 IDNA separators: `.`(<<0x002E::utf8>>), `。`(<<0x3002::utf8>>), `．`(<<0xFF0E::utf8>>), `｡`(<<0xFF61::utf8>>)
      # Check for empty labels (leading, trailing, or consecutive separators), for exampla(take the `.`(<<0x002E::utf8>>) as an example)
      #   * leading: .hello
      #   * trailing: hello.
      #   * consecutive separators: hello.。world
      if Regex.match?(~r/(^|[\.\x{3002}\x{FF0E}\x{FF61}])([\.\x{3002}\x{FF0E}\x{FF61}]|$)/u, data) do
        false
      else
        try do
          case :idna.to_ascii(String.to_charlist(data)) do
            res when is_list(res) -> true
            _ -> false
          end
        catch
          _, _ -> false
        end
      end
    end
  else
    def valid_idn?(data) when is_binary(data) do
      # Normalize IDNA separators to dots
      normalized = String.replace(data, ["\u3002", "\uFF0E", "\uFF61"], ".")

      if is_ascii?(normalized) do
        valid?(normalized)
      else
        raise "The optional dependency :idna is required to validate idn-hostname with non-ASCII characters. Please add it to your mix.exs deps."
      end
    end
  end

  def valid_idn?(_), do: true

  defp is_ascii?(<<>>), do: true
  defp is_ascii?(<<c, rest::binary>>) when c <= 127, do: is_ascii?(rest)
  defp is_ascii?(_), do: false

  defp validate_ascii_hostname(data) when byte_size(data) > 255, do: false

  defp validate_ascii_hostname(data) do
    labels = String.split(data, ".", trim: false)

    # Check for empty labels (covers leading/trailing dots and consecutive dots)
    if Enum.any?(labels, &(&1 == "")) do
      false
    else
      Enum.all?(labels, &valid_label?/1)
    end
  end

  defp valid_label?(label) when byte_size(label) > 63, do: false

  defp valid_label?(<<"xn--", _::binary>> = label) do
    validate_idn_label(String.downcase(label))
  end

  defp valid_label?(<<"Xn--", _::binary>> = label) do
    validate_idn_label(String.downcase(label))
  end

  defp valid_label?(<<"xN--", _::binary>> = label) do
    validate_idn_label(String.downcase(label))
  end

  defp valid_label?(<<"XN--", _::binary>> = label) do
    validate_idn_label(String.downcase(label))
  end

  defp valid_label?(label) do
    validate_std_label(label)
  end

  if Code.ensure_loaded?(:idna) do
    defp validate_idn_label(label) do
      try do
        # We use to_unicode to attempt decoding and validation of the A-label
        case :idna.to_unicode(String.to_charlist(label)) do
          {:error, _} -> false
          res when is_list(res) -> true
          _ -> false
        end
      catch
        _, _ -> false
      end
    end
  else
    defp validate_idn_label(_label) do
      raise "The optional dependency :idna is required to validate Punycode (A-label) hostnames. Please add it to your mix.exs deps."
    end
  end

  # Check for hyphens in 3rd and 4th position (indices 2 and 3)
  # Since we are here, we know it does NOT start with xn--/XN-- etc.
  defp validate_std_label(<<_, _, ?-, ?-, _::binary>>), do: false

  # Single character label
  defp validate_std_label(<<c>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true

  # Multi-character label: first and last must be alphanumeric, middle can include hyphens
  defp validate_std_label(<<first, rest::binary>>)
       when first in ?a..?z or first in ?A..?Z or first in ?0..?9 do
    validate_std_label_middle(rest)
  end

  defp validate_std_label(_), do: false

  # Last character — must be alphanumeric
  defp validate_std_label_middle(<<c>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true
  defp validate_std_label_middle(<<c>>), do: c != ?-  and false

  # Middle characters — alphanumeric or hyphen
  defp validate_std_label_middle(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?- do
    validate_std_label_middle(rest)
  end

  defp validate_std_label_middle(_), do: false
end

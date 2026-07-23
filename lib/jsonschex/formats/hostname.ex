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
      # 4 IDNA valid separators: `.`(<<0x002E::utf8>>), `。`(<<0x3002::utf8>>), `．`(<<0xFF0E::utf8>>), `｡`(<<0xFF61::utf8>>)
      normalized = String.replace(data, ["\u3002", "\uFF0E", "\uFF61"], ".")
      case check_and_split_hostname(normalized) do
        {:ok, labels} ->
          validate_idn_hostname(labels)
        _ ->
          false
      end
    end
  else
    defp is_ascii_and_size_le_253?(<<>>), do: true
    defp is_ascii_and_size_le_253?(data) do
      is_ascii_and_size_le_253?(data, 0)
    end

    defp is_ascii_and_size_le_253?(_data, count) when count > 253, do: false
    defp is_ascii_and_size_le_253?(<<c, rest::binary>>, count) when c <= 127, do: is_ascii_and_size_le_253?(rest, count + 1)
    defp is_ascii_and_size_le_253?(<<c, _rest::binary>>, _count) when c > 127, do: false
    defp is_ascii_and_size_le_253?(<<>>, count) when count >= 0 and count <= 253, do: true
    defp is_ascii_and_size_le_253?(_, _), do: false

    def valid_idn?(data) when is_binary(data) do
      # Normalize IDNA separators to dots
      normalized = String.replace(data, ["\u3002", "\uFF0E", "\uFF61"], ".")

      if is_ascii_and_size_le_253?(normalized) do
        validate_ascii_hostname(normalized)
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
    # Check for empty labels (covers leading/trailing dots and consecutive dots)
    case check_and_split_hostname(data) do
      {:ok, labels} ->
        Enum.all?(labels, &valid_label?/1)
      _ ->
        false
    end
  end

  defp check_and_split_hostname(data) do
    labels = String.split(data, ".", trim: false)
    if Enum.any?(labels, &(&1 == "")) do
      :error
    else
      {:ok, labels}
    end
  end

  defp valid_label?(label) when byte_size(label) > 63, do: false

  defp valid_label?(label) do
    if String.starts_with?(String.downcase(label), "xn--") do
      validate_idn_label(label)
    else
      validate_std_label(label)
    end
  end

  if Code.ensure_loaded?(:idna) do
    # IDNA encoding is permissive for some malformed A-labels. Validate an
    # A-label by decoding it, requiring non-ASCII content, and checking that
    # encoding the U-label produces the same canonical A-label.
    defp validate_idn_label(label) do
      try do
        normalized = String.downcase(label)
        ulabel = :idna.decode(String.to_charlist(normalized))
        contains_non_ascii? = Enum.any?(ulabel, &(&1 > 127))
        encoded = :idna.encode(ulabel, [:strict])

        contains_non_ascii? and List.to_string(encoded) == normalized
      catch
        _, _ -> false
      end
    end

    defp validate_idn_hostname(labels) do
      try do
        encoded_labels = Enum.map(labels, &encode_idn_label/1)
        ulabels = Enum.map(encoded_labels, &:idna.decode/1)
        encoded_length = encoded_labels |> Enum.intersperse(~c".") |> List.flatten() |> length()
        bidi_domain? = Enum.any?(ulabels, &contains_rtl?/1)

        encoded_length <= 253 and
          Enum.all?(Enum.zip([labels, encoded_labels, ulabels]), fn {label, encoded, ulabel} ->
            valid_idn_label?(label, encoded, ulabel, bidi_domain?)
          end)
      catch
        _, _ -> false
      end
    end

    defp encode_idn_label(label), do: :idna.encode(String.to_charlist(label), [:strict])

    defp valid_idn_label?(label, encoded, ulabel, bidi_domain?) do
      valid_label_for_idn?(label) and
        length(encoded) <= 63 and
        (not bidi_domain? or :idna_bidi.check_bidi(ulabel, true) == :ok)
    end

    defp valid_label_for_idn?(label) do
      if String.starts_with?(String.downcase(label), "xn--") do
        validate_idn_label(label)
      else
        is_ascii?(label) == false or validate_std_label(label)
      end
    end

    defp contains_rtl?(ulabel) do
      # :idna_bidi applies RFC 5893's complete label validation. Its generated
      # Unicode data identifies whether the domain contains an RTL label.
      Enum.any?(ulabel, fn codepoint ->
        :idna_data.bidirectional(codepoint) in [~c"R", ~c"AL", ~c"AN"]
      end)
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

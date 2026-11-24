defmodule JSONSchex.Formats.DateTime do
  @moduledoc """
  Validates RFC 3339 `date-time`, `date`, and `time` formats using pure binary pattern matching.
  """

  import JSONSchex.Guards, only: [is_ascii_digit?: 1]

  @doc """
  Validates an RFC 3339 `date-time` string (`YYYY-MM-DD[Tt]HH:MM:SS(.frac)?(Z|z|±HH:MM)`).
  """
  @spec valid?(term()) :: boolean()
  def valid?(
        <<y1, y2, y3, y4, ?-, m1, m2, ?-, d1, d2, sep, h1, h2, ?:, min1, min2, ?:, s1, s2,
          rest::binary>>
      )
      when is_ascii_digit?(y1) and is_ascii_digit?(y2) and is_ascii_digit?(y3) and is_ascii_digit?(y4) and
             is_ascii_digit?(m1) and is_ascii_digit?(m2) and is_ascii_digit?(d1) and is_ascii_digit?(d2) and
             (sep == ?T or sep == ?t) and
             is_ascii_digit?(h1) and is_ascii_digit?(h2) and
             is_ascii_digit?(min1) and is_ascii_digit?(min2) and
             is_ascii_digit?(s1) and is_ascii_digit?(s2) do
    year = (y1 - ?0) * 1000 + (y2 - ?0) * 100 + (y3 - ?0) * 10 + (y4 - ?0)
    month = (m1 - ?0) * 10 + (m2 - ?0)
    day = (d1 - ?0) * 10 + (d2 - ?0)

    if valid_date?(year, month, day) do
      validate_time_parts(h1, h2, min1, min2, s1, s2, rest)
    else
      false
    end
  end

  def valid?(_), do: false

  @doc """
  Validates an RFC 3339 `full-date` string (`YYYY-MM-DD`).
  """
  @spec valid_date?(term()) :: boolean()
  def valid_date?(<<y1, y2, y3, y4, ?-, m1, m2, ?-, d1, d2>>)
      when is_ascii_digit?(y1) and is_ascii_digit?(y2) and is_ascii_digit?(y3) and is_ascii_digit?(y4) and
             is_ascii_digit?(m1) and is_ascii_digit?(m2) and
             is_ascii_digit?(d1) and is_ascii_digit?(d2) do
    year = (y1 - ?0) * 1000 + (y2 - ?0) * 100 + (y3 - ?0) * 10 + (y4 - ?0)
    month = (m1 - ?0) * 10 + (m2 - ?0)
    day = (d1 - ?0) * 10 + (d2 - ?0)
    valid_date?(year, month, day)
  end

  def valid_date?(_), do: false

  @doc """
  Validates an RFC 3339 `full-time` string (`HH:MM:SS(.frac)?(Z|z|±HH:MM)`).
  """
  @spec valid_time?(term()) :: boolean()
  def valid_time?(<<h1, h2, ?:, min1, min2, ?:, s1, s2, rest::binary>>)
      when is_ascii_digit?(h1) and is_ascii_digit?(h2) and
             is_ascii_digit?(min1) and is_ascii_digit?(min2) and
             is_ascii_digit?(s1) and is_ascii_digit?(s2) do
    validate_time_parts(h1, h2, min1, min2, s1, s2, rest)
  end

  def valid_time?(_), do: false

  @compile {:inline, validate_time_parts: 7}
  defp validate_time_parts(h1, h2, min1, min2, s1, s2, rest) do
    hour = (h1 - ?0) * 10 + (h2 - ?0)
    minute = (min1 - ?0) * 10 + (min2 - ?0)
    second = (s1 - ?0) * 10 + (s2 - ?0)

    if hour <= 23 and minute <= 59 and second <= 60 do
      case parse_frac_and_tz(rest) do
        {:ok, tz_offset_minutes} ->
          if second == 60 do
            # RFC 3339 leap second is only valid at 23:59:60 UTC.
            utc_minutes = Integer.mod(hour * 60 + minute - tz_offset_minutes, 1440)
            utc_minutes == 1439
          else
            true
          end

        :error ->
          false
      end
    else
      false
    end
  end

  defp parse_frac_and_tz(<<?., d, rest::binary>>) when is_ascii_digit?(d),
    do: skip_digits_then_tz(rest)

  defp parse_frac_and_tz(rest), do: parse_tz(rest)

  defp skip_digits_then_tz(<<d, rest::binary>>) when is_ascii_digit?(d),
    do: skip_digits_then_tz(rest)

  defp skip_digits_then_tz(rest), do: parse_tz(rest)

  defp parse_tz(<<z>>) when z == ?Z or z == ?z, do: {:ok, 0}

  defp parse_tz(<<sign, oh1, oh2, ?:, om1, om2>>)
       when (sign == ?+ or sign == ?-) and
              is_ascii_digit?(oh1) and is_ascii_digit?(oh2) and
              is_ascii_digit?(om1) and is_ascii_digit?(om2) do
    oh = (oh1 - ?0) * 10 + (oh2 - ?0)
    om = (om1 - ?0) * 10 + (om2 - ?0)

    if oh <= 23 and om <= 59 do
      total = oh * 60 + om
      {:ok, if(sign == ?+, do: total, else: -total)}
    else
      :error
    end
  end

  defp parse_tz(_), do: :error

  defp valid_date?(year, month, day) when month in 1..12 and day >= 1 do
    day <= days_in_month(year, month)
  end

  defp valid_date?(_, _, _), do: false

  defp days_in_month(_year, month) when month in [1, 3, 5, 7, 8, 10, 12], do: 31
  defp days_in_month(_year, month) when month in [4, 6, 9, 11], do: 30

  defp days_in_month(year, 2) do
    if (rem(year, 4) == 0 and rem(year, 100) != 0) or rem(year, 400) == 0, do: 29, else: 28
  end
end

defmodule JSONSchex.Formats.DateTime do
  @moduledoc """
  Validates RFC 3339 `date-time` and `time` formats.
  """

  def valid?(data) do
    # RFC 3339 allows case-insensitive T and Z
    normalized =
      String.replace(data, ["t", "z"], fn <<char>> -> <<char-32>> end)

    case DateTime.from_iso8601(normalized) do
      {:ok, _, _} ->
        true

      {:error, :invalid_time} ->
        maybe_valid_leap_seconds?(normalized)

      _ ->
        false
    end
  end

  def valid_time?(data) do
    # RFC 3339 uses period for decimal separation, not comma (which ISO 8601 allows)
    if String.contains?(data, ",") do
      false
    else
      # RFC 3339 section 4.3 allows "-00:00" as an unknown local offset.
      # `DateTime.from_iso8601/2` parses it as an invalid format, so normalize it to "+00:00" for
      # structural validation while preserving the original acceptance semantics.
      normalized_time =
        if String.ends_with?(data, "-00:00") do
          String.replace_suffix(data, "-00:00", "+00:00")
        else
          data
        end

      # Prepend an arbitrary date so we can reuse the RFC 3339 date-time validation
      # logic, including offset handling, case-insensitive Z normalization, and leap seconds.
      valid?("2020-01-01T" <> normalized_time)
    end
  end

  defp maybe_valid_leap_seconds?(datetime) do
    # Handle leap seconds (60) which Elixir's Calendar.ISO rejects
    # Replace T<HH>:<MM>:60 with T<HH>:<MM>:59
    # Leap seconds are added as the last second of the day in UTC time.
    # Since we replaced 60 with 59, we expect the time to be 23:59:59 UTC.
    with true <- String.contains?(datetime, ":60"),
         {:cont, replaced} <- replace_leap_seconds_and_revalidate(datetime),
         {:ok, %{hour: 23, minute: 59, second: 59}, _} <- DateTime.from_iso8601(replaced) do
      true
    else
      _ ->
        false
    end
  end

  defp replace_leap_seconds_and_revalidate(datetime) do
    replaced = Regex.replace(~r/(T\d{2}:\d{2}):60/, datetime, "\\1:59", global: false)
    if replaced != datetime do
      {:cont, replaced}
    else
      :halt
    end
  end
end

defmodule JSONSchex.Formats.DateTime do
  @moduledoc """
  Validates "date-time" format according to RFC 3339.
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

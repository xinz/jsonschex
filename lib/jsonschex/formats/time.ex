defmodule JSONSchex.Formats.Time do
  @moduledoc """
  Validates "time" format according to RFC 3339.
  """

  def valid?(data) do
    # RFC 3339 uses period for decimal separation, not comma (which ISO 8601 allows)
    if String.contains?(data, ",") do
      false
    else
      # Prepend an arbitrary date so we can use the robust RFC 3339 logic
      # in JSONSchex.Formats.DateTime (which handles offsets, Z normalization, and leap seconds)
      JSONSchex.Formats.DateTime.valid?("2020-01-01T" <> data)
    end
  end
end

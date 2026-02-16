defmodule JSONSchex.Formats.URITemplate do
  @moduledoc """
  Validates `uri-template` format according to RFC 6570.
  """

  def valid?(data) do
    valid_expressions? =
      Regex.scan(~r/\{([^{}]*)\}/, data)
      |> Enum.all?(fn [_, content] ->
        valid_expression?(content)
      end)

    if valid_expressions? do
      remaining = Regex.replace(~r/\{([^{}]*)\}/, data, "")
      not String.contains?(remaining, ["{", "}"])
    else
      false
    end
  end

  defp valid_expression?(content) do
    # content is the string inside { }
    # check for optional operators
    varlist =
      if String.match?(content, ~r/^[+#.\/;?&]/) do
        String.slice(content, 1..-1//1)
      else
        content
      end

    if varlist == "" do
      false
    else
      varlist
      |> String.split(",")
      |> Enum.all?(&valid_varspec?/1)
    end
  end

  defp valid_varspec?(spec) do
    # varspec = varname [ modifier-level4 ]
    # varname = varchar *( ["."] varchar )
    # varchar = ALPHA / DIGIT / "_" / pct-encoded
    # see https://datatracker.ietf.org/doc/html/rfc6570#section-1.5
    Regex.match?(
      ~r/^(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})+(?:\.(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})+)*(?:\*|:\d+)?$/,
      spec
    )
  end

end

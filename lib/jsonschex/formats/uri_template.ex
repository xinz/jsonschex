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
      # Keep literal segments separate: an expression cannot complete a percent escape.
      Regex.split(~r/\{[^{}]*\}/, data)
      |> Enum.all?(&valid_literal?/1)
    else
      false
    end
  end

  defp valid_literal?(literal) do
    # RFC 6570 sections 1.5/2.1, including erratum 6937 allowing literal apostrophes.
    Regex.match?(
      ~r/
      \A(?:
        [\x21\x23-\x24\x26-\x3B\x3D\x3F-\x5B\x5D\x5F\x61-\x7A\x7E]
        | %[0-9A-Fa-f]{2}
        | [\x{A0}-\x{D7FF}\x{F900}-\x{FDCF}\x{FDF0}-\x{FFEF}]
        | [\x{10000}-\x{1FFFD}\x{20000}-\x{2FFFD}\x{30000}-\x{3FFFD}]
        | [\x{40000}-\x{4FFFD}\x{50000}-\x{5FFFD}\x{60000}-\x{6FFFD}]
        | [\x{70000}-\x{7FFFD}\x{80000}-\x{8FFFD}\x{90000}-\x{9FFFD}]
        | [\x{A0000}-\x{AFFFD}\x{B0000}-\x{BFFFD}\x{C0000}-\x{CFFFD}]
        | [\x{D0000}-\x{DFFFD}\x{E1000}-\x{EFFFD}]
        | [\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}\x{100000}-\x{10FFFD}]
      )*\z
      /ux,
      literal
    )
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
      ~r/\A(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})+(?:\.(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})+)*(?:\*|:[1-9][0-9]{0,3})?\z/,
      spec
    )
  end

end

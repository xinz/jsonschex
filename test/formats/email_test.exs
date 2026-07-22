defmodule JSONSchex.Formats.EmailTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Formats.Email

  test "idn-email rejects a local part containing a lone UTF-16 surrogate" do
    email = <<0xED, 0xA0, 0x80>> <> "@example.com"

    refute String.valid?(email)
    refute Email.valid_idn?(email)
  end
end

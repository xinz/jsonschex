defmodule JSONSchex.Formats.EmailTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Formats.Email

  test "email splits at the last at-sign, including quoted local parts" do
    assert Email.valid?("user@example.com")
    assert Email.valid?(~s("user@name"@example.com))
    refute Email.valid?("user@name@example.com")
    refute Email.valid?("example.com")
  end

  test "idn-email splits UTF-8 local parts using byte offsets" do
    assert Email.valid_idn?("üser@example.com")
    assert Email.valid_idn?(~s("üser@name"@example.com))
    refute Email.valid_idn?("üser@name@example.com")
    refute Email.valid_idn?("üser")
  end

  test "idn-email rejects a local part containing a lone UTF-16 surrogate" do
    email = <<0xED, 0xA0, 0x80>> <> "@example.com"

    refute String.valid?(email)
    refute Email.valid_idn?(email)
  end

  test "idn-email accepts a domain label that is not in Unicode NFC" do
    domain = "cafe\u0301.com"

    refute domain == :unicode.characters_to_nfc_binary(domain)
    assert Email.valid_idn?("user@" <> domain)
  end
end

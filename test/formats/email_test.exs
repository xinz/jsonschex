defmodule JSONSchex.Formats.EmailTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Formats.Email

  test "email splits at the last at-sign, including quoted local parts" do
    assert Email.valid?("user@example.com")
    assert Email.valid?(~s("user@name"@example.com))
    refute Email.valid?("user@name@example.com")
    refute Email.valid?("example.com")
  end

  test "email and idn-email accept case-insensitive IPv6 literal tags" do
    for tag <- ["IPv6", "ipv6", "IPV6", "iPv6"] do
      assert Email.valid?("a@[#{tag}:::1]")
      assert Email.valid_idn?("a@[#{tag}:::1]")
      refute Email.valid?("a@[#{tag}:not-an-ip]")
      refute Email.valid_idn?("a@[#{tag}:not-an-ip]")
    end

    refute Email.valid?("a@[ipv5:::1]")
  end

  test "email accepts an empty quoted local part but not a missing local part" do
    assert Email.valid?(~s(""@iana.org))
    assert Email.valid_idn?(~s(""@iana.org))
    refute Email.valid?("@iana.org")
    refute Email.valid_idn?("@iana.org")
  end

  test "email accepts ASCII quoted pairs but rejects non-ASCII quoted content" do
    assert Email.valid?(~S("test\"name"@iana.org))
    assert Email.valid?(~S("test\\name"@iana.org))
    refute Email.valid?(~s("test\\©"@iana.org))
    refute Email.valid?(~s("üser"@iana.org))
  end

  test "idn-email preserves Unicode support in quoted local parts" do
    assert Email.valid_idn?(~s("üser"@iana.org))
    assert Email.valid_idn?(~s("test\\©"@iana.org))
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

defmodule JSONSchex.Formats.HostnameTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Formats.Hostname

  test "idn-hostname rejects malformed and overlong A-label hostnames" do
    refute Hostname.valid_idn?("xn--example-")
    refute Hostname.valid_idn?("xn---9uc")

    hostname =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." <>
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." <>
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa." <>
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    refute Hostname.valid_idn?(hostname)
  end

  test "idn-hostname applies Bidi rules to Unicode and A-label forms" do
    refute Hostname.valid_idn?("0a.א")
    refute Hostname.valid_idn?("0a.xn--4db")

    assert Hostname.valid_idn?("example.א")
    assert Hostname.valid_idn?("example.xn--4db")
  end
end

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

  test "idn-hostname applies non-transitional UTS 46 mapping and NFC normalization" do
    for hostname <- ["１２３", "cafe\u0301.com", "a\u200Bb", "ｘｎ--nxasmq6b", "faß.de"] do
      assert Hostname.valid_idn?(hostname), "Expected valid IDN hostname: #{inspect(hostname)}"
    end

    refute Hostname.valid_idn?("a\u200Cb")
    refute Hostname.valid_idn?("\u200B")
    refute Hostname.valid_idn?("a.\u200B.b")
  end

  test "idn-hostname validates label and domain lengths after mapping" do
    label = String.duplicate("ａ", 63)

    assert Hostname.valid_idn?(label)
    refute Hostname.valid_idn?(label <> "ａ")
    assert Hostname.valid_idn?(Enum.join([label, label, label, String.duplicate("ａ", 61)], "."))
    refute Hostname.valid_idn?(Enum.join([label, label, label, String.duplicate("ａ", 62)], "."))
  end

  test "idn-hostname validates A-labels and Bidi rules produced by mapping" do
    refute Hostname.valid_idn?("ｘｎ--example-")
    refute Hostname.valid_idn?("ｘｎ---9uc")
    refute Hostname.valid_idn?("０a.א")
    assert Hostname.valid_idn?("ｅxample.א")
  end

  test "hostname does not apply IDN compatibility mapping" do
    refute Hostname.valid?("１２３")
    refute Hostname.valid?("ｘｎ--nxasmq6b")
  end

  test "idn-hostname applies Bidi rules to Unicode and A-label forms" do
    refute Hostname.valid_idn?("0a.א")
    refute Hostname.valid_idn?("0a.xn--4db")

    assert Hostname.valid_idn?("example.א")
    assert Hostname.valid_idn?("example.xn--4db")
  end
end

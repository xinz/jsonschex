defmodule JSONSchex.Formats.IPTest do
  use ExUnit.Case, async: true

  alias JSONSchex.Formats.IP

  test "validates IPv4 dotted-decimal addresses" do
    for address <- ["0.0.0.0", "1.2.3.4", "127.0.0.1", "255.255.255.255"] do
      assert IP.valid_ipv4?(address), "expected #{address} to be valid"
    end
  end

  test "rejects malformed IPv4 addresses" do
    for address <- [
          "",
          "1.2.3",
          "1.2.3.4.5",
          "01.2.3.4",
          "256.0.0.1",
          "1.2.3.1234",
          "1..3.4",
          "1.2.3.a"
        ] do
      refute IP.valid_ipv4?(address), "expected #{address} to be invalid"
    end
  end
end

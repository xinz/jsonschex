defmodule JSONSchex.Test.DepsIdnaLoadedTest do
  use ExUnit.Case, async: false

  # This test manipulates global code loading state, so it must be run synchronously.
  # We assume :idna is present in the environment (via mix.exs) for these tests.

  @hostname_source "lib/jsonschex/formats/hostname.ex"

  test "validates punycode when idna is loaded (standard path)" do
    # Ensure :idna is available
    assert Code.ensure_loaded?(:idna), ":idna should be loaded for this test to be meaningful"

    # Ensure Hostname is compiled with :idna support
    # (recompile to be safe against side-effects from other tests)
    recompile_hostname()

    # Should be valid and use the real :idna library
    assert JSONSchex.Formats.Hostname.valid?("xn--Example-2n0l.com") == true
  end

  test "raises when idna is missing and punycode is encountered (dynamic unload)" do
    with_idna_unloaded(fn ->
      assert_raise RuntimeError, ~r/The optional dependency :idna is required/, fn ->
        JSONSchex.Formats.Hostname.valid?("xn--Example-2n0l.com")
      end
    end)
  end

  test "validates idn-hostname without idna (fallback logic)" do
    with_idna_unloaded(fn ->
      # 1. ASCII with standard dots should pass
      assert JSONSchex.Formats.Hostname.valid_idn?("example.com") == true

      # 2. ASCII with IDNA separators should pass (normalization)
      assert JSONSchex.Formats.Hostname.valid_idn?("example。com") == true
      assert JSONSchex.Formats.Hostname.valid_idn?("example．com") == true
      assert JSONSchex.Formats.Hostname.valid_idn?("example｡com") == true

      # 3. Non-ASCII characters should raise
      assert_raise RuntimeError, ~r/The optional dependency :idna is required/, fn ->
        JSONSchex.Formats.Hostname.valid_idn?("exämple.com")
      end
    end)
  end

  defp with_idna_unloaded(callback) do
    # 1. Locate :idna artifact path
    {:module, :idna} = Code.ensure_loaded(:idna)
    idna_beam_path = :code.which(:idna)
    idna_ebin_dir = Path.dirname(idna_beam_path)

    try do
      # 2. Unload :idna and remove its directory from the code path
      :code.purge(:idna)
      :code.delete(:idna)
      Code.delete_path(idna_ebin_dir)

      refute Code.ensure_loaded?(:idna)

      # 3. Recompile JSONSchex.Formats.Hostname without :idna
      recompile_hostname()

      callback.()
    after
      # 4. Restore global state
      Code.prepend_path(idna_ebin_dir)

      if Code.ensure_loaded?(:idna) do
        # 5. Recompile Hostname back to original state (with :idna support)
        recompile_hostname()
      else
        IO.warn("Failed to restore :idna after test. Subsequent tests may fail.")
      end
    end
  end

  defp recompile_hostname do
    # Suppress "redefining module JSONSchex.Formats.Hostname" warnings
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_file(@hostname_source)
    end)
  end
end

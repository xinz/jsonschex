defmodule JSONSchex.Test.RefIdentity do
  use ExUnit.Case

  @retrieval_bases [
    http: "https://example.com/ref-identity.json",
    filesystem: Path.expand("ref_identity_test.exs", __DIR__)
  ]

  for {draft, draft_opts} <- [{"draft7", [draft: "draft7"]}, {"default Draft 2020-12", []}] do
    for {base_kind, base_uri} <- @retrieval_bases do
      test "empty self reference accepts nested objects with a #{base_kind} retrieval base in #{draft}" do
        # No ID registers the retrieval URI, so the reference must use the current raw root.
        assert {:ok, compiled} = JSONSchex.compile(recursive_schema(),
          [base_uri: unquote(base_uri)] ++ unquote(draft_opts))

        assert :ok == JSONSchex.validate(compiled, %{"next" => %{"next" => %{}}})
      end

      test "empty self reference rejects a nested scalar with a #{base_kind} retrieval base in #{draft}" do
        assert {:ok, compiled} = JSONSchex.compile(recursive_schema(),
          [base_uri: unquote(base_uri)] ++ unquote(draft_opts))

        assert {:error, [%{rule: :type, path: ["next"], context: %{contrast: "object"}}]} =
                 JSONSchex.validate(compiled, %{"next" => 1})
      end
    end

    test "empty self reference does not reload an unregistered retrieval URI in #{draft}" do
      for {_base_kind, base_uri} <- @retrieval_bases do
        opts = unquote(draft_opts) ++ [base_uri: base_uri, loader: &unexpected_loader/1]
        assert {:ok, compiled} = JSONSchex.compile(recursive_schema(), opts)
        assert :ok == JSONSchex.validate(compiled, %{"next" => %{"next" => %{}}})
        assert {:error, [%{rule: :type, path: ["next"], context: %{contrast: "object"}}]} =
                 JSONSchex.validate(compiled, %{"next" => 1})
      end
    end

    test "empty self reference preserves nil-base, declared-ID, and URN controls in #{draft}" do
      contexts = [
        {"nil retrieval base", recursive_schema(), []},
        {"declared HTTP root ID",
         Map.put(recursive_schema(), "$id", "https://example.com/declared-root.json"),
         [base_uri: "https://example.com/retrieved-root.json"]},
        {"URN retrieval base", recursive_schema(), [base_uri: "urn:example:ref-identity"]}
      ]

      for {label, schema, context_opts} <- contexts do
        opts = unquote(draft_opts) ++ context_opts ++ [loader: &unexpected_loader/1]
        assert {:ok, compiled} = JSONSchex.compile(schema, opts)
        assert :ok == JSONSchex.validate(compiled, %{"next" => %{"next" => %{}}}), label
        assert {:error, [%{rule: :type, path: ["next"], context: %{contrast: "object"}}]} =
                 JSONSchex.validate(compiled, %{"next" => 1})
      end
    end

    test "absolute current-resource URN pointers remain local in #{draft}" do
      uri = "urn:example:ref-identity"
      schema = %{
        "$id" => uri,
        "type" => "object",
        "definitions" => %{"value" => %{"type" => "integer"}},
        "properties" => %{"value" => %{"$ref" => uri <> "#/definitions/value"}}
      }

      assert {:ok, compiled} = JSONSchex.compile(schema,
        unquote(draft_opts) ++ [loader: &unexpected_loader/1])

      # An eager unqualified alias would hide whether absolute URN normalization works.
      refute Map.has_key?(compiled.defs, "#/definitions/value")
      assert :ok == JSONSchex.validate(compiled, %{"value" => 1})
      assert {:error, [%{rule: :type, path: ["value"], context: %{contrast: "integer"}}]} =
               JSONSchex.validate(compiled, %{"value" => "1"})
    end
  end

  test "Draft 7 JIT hash reference clears an inherited named fragment and accepts the root integer" do
    {compiled, uri} = compile_remote_entry!("#")
    assert :ok == validate_remote(compiled, uri, 1)
  end

  test "Draft 7 JIT hash reference rejects a string accepted only by the named ancestor" do
    {compiled, uri} = compile_remote_entry!("#")
    assert {:error, [%{rule: :type, path: [], context: %{contrast: "integer"}}]} =
             validate_remote(compiled, uri, "1")
  end

  test "Draft 7 JIT empty reference resets an inherited named fragment to the root" do
    {compiled, uri} = compile_remote_entry!("")
    assert :ok == validate_remote(compiled, uri, 1)
    assert {:error, [%{rule: :type, path: [], context: %{contrast: "integer"}}]} =
             validate_remote(compiled, uri, "1")
  end

  test "Draft 7 JIT hash reference preserves root lookup without an ancestor fragment" do
    {compiled, uri} = compile_remote_entry!("#", nil)
    assert :ok == validate_remote(compiled, uri, 1)
    assert {:error, [%{rule: :type, path: [], context: %{contrast: "integer"}}]} =
             validate_remote(compiled, uri, "1")
  end

  test "Draft 7 JIT reference replaces an inherited fragment with a different named fragment" do
    {compiled, uri} = compile_remote_entry!("#other")
    assert :ok == validate_remote(compiled, uri, true)
    assert {:error, [%{rule: :type, path: [], context: %{contrast: "boolean"}}]} =
             validate_remote(compiled, uri, 1)
  end

  defp recursive_schema do
    %{
      "type" => "object",
      "properties" => %{"next" => %{"$ref" => ""}}
    }
  end

  defp compile_remote_entry!(ref, ancestor_id \\ "#named") do
    uri = "https://example.com/ref-identity-remote.json"
    parent = self()
    named = %{"type" => "string", "entry" => %{"$ref" => ref}}
    named = if ancestor_id, do: Map.put(named, "$id", ancestor_id), else: named

    # The entry is explicitly selected from annotation data, so its local reference
    # cannot publish an eager alias that masks the inherited fragment identity.
    remote = %{
      "$id" => uri,
      "type" => "integer",
      "definitions" => %{
        "named" => named,
        "other" => %{"$id" => "#other", "type" => "boolean"}
      }
    }

    loader = fn
      ^uri ->
        send(parent, {:loaded, uri})
        {:ok, remote}
      other ->
        unexpected_loader(other)
    end

    assert {:ok, compiled} = JSONSchex.compile(
      %{"$ref" => uri <> "#/definitions/named/entry"}, draft: "draft7", loader: loader)
    refute Map.has_key?(compiled.defs, "#")
    refute_received {:loaded, _}
    {compiled, uri}
  end

  defp validate_remote(compiled, uri, data) do
    result = JSONSchex.validate(compiled, data)
    assert_received {:loaded, ^uri}
    refute_received {:loaded, _}
    result
  end

  defp unexpected_loader(uri), do: flunk("Unexpected external schema load: #{inspect(uri)}")
end

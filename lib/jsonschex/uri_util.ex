defmodule JSONSchex.URIUtil do
  @moduledoc """
  Utilities for URI resolution and manipulation.
  """

  @doc """
  Resolves a relative URI against a base URI.
  Safely handles cases where URIs are invalid or nil.

  If merging fails (e.g. invalid URI format), it falls back to returning the child URI
  (or the base if child is nil).

  ## Examples

      iex> JSONSchex.URIUtil.resolve("https://example.com/schema.json", "user.json")
      "https://example.com/user.json"

      iex> JSONSchex.URIUtil.resolve("https://example.com/schemas/", "#/definitions/user")
      "https://example.com/schemas/#/definitions/user"

      iex> JSONSchex.URIUtil.resolve(nil, "https://example.com/schema.json")
      "https://example.com/schema.json"

  """
  @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve(nil, uri), do: uri
  def resolve(base, nil), do: base
  def resolve(base, uri) when is_binary(base) and is_binary(uri) do
    cond do
      filesystem_path_uri?(base) ->
        resolve_filesystem_path(base, uri)

      true ->
        try do
          base |> URI.merge(uri) |> URI.to_string()
        rescue
          _ -> uri
        end
    end
  end

  @doc """
  Splits a URI or reference into `{base, fragment}`.

  Only the first literal `#` separates the base from the fragment. The fragment
  is returned without that leading `#`. If no fragment is present, the second
  element is `nil`. An empty fragment (`"#"`) is also normalized to `nil`.

  ## Examples

      iex> JSONSchex.URIUtil.split_fragment("https://example.com/schema")
      {"https://example.com/schema", nil}

      iex> JSONSchex.URIUtil.split_fragment("https://example.com/schema#meta")
      {"https://example.com/schema", "meta"}

      iex> JSONSchex.URIUtil.split_fragment("#/$defs/foo")
      {"", "/$defs/foo"}

      iex> JSONSchex.URIUtil.split_fragment("https://example.com/schema#")
      {"https://example.com/schema", nil}
  """
  @spec split_fragment(String.t()) :: {String.t(), String.t() | nil}
  def split_fragment(""), do: {"", nil}
  def split_fragment("#"), do: {"", nil}
  def split_fragment(uri) when is_binary(uri) do
    case :binary.split(uri, "#", []) do
      [base, ""] -> {base, nil}
      [base, fragment] -> {base, fragment}
      [base] -> {base, nil}
    end
  end

  @doc """
  Returns the URI or reference without its fragment.

  Removes the first literal `#` and everything after it, without decoding or
  normalizing the URI. Fragment-only references return `""`; a missing URI
  remains `nil`, so absence is not confused with an explicitly empty reference.
  Callers that require an empty resource key can normalize with `base(uri) || ""`.

  ## Examples

      iex> JSONSchex.URIUtil.base("https://example.com/schema#meta")
      "https://example.com/schema"

      iex> JSONSchex.URIUtil.base("schema.json?version=1#/definitions/value")
      "schema.json?version=1"

      iex> JSONSchex.URIUtil.base("urn:example:schema")
      "urn:example:schema"

      iex> JSONSchex.URIUtil.base("#/definitions/value")
      ""

      iex> JSONSchex.URIUtil.base("")
      ""

      iex> JSONSchex.URIUtil.base(nil)
      nil
  """
  @spec base(String.t() | nil) :: String.t() | nil
  def base(nil), do: nil
  def base(uri) when is_binary(uri) do
    case :binary.match(uri, "#") do
      {offset, 1} -> binary_part(uri, 0, offset)
      _ -> uri
    end
  end

  @doc """
  Returns only the fragment portion of a URI or reference, without the leading `#`.

  ## Examples

      iex> JSONSchex.URIUtil.fragment("https://example.com/schema#meta")
      "meta"

      iex> JSONSchex.URIUtil.fragment("#/$defs/foo")
      "/$defs/foo"

      iex> JSONSchex.URIUtil.fragment("https://example.com/schema")
      nil
  """
  @spec fragment(String.t()) :: String.t() | nil
  def fragment(uri) when is_binary(uri) do
    {_base, fragment} = split_fragment(uri)
    fragment
  end

  @doc """
  Joins a fragment-free base URI and a fragment into a URI reference.

  The fragment should be provided without the leading `#`. Passing `nil` returns
  the base unchanged; an empty fragment appends `#`. No URI parsing, encoding,
  normalization, or replacement of an existing fragment is performed.

  ## Examples

      iex> JSONSchex.URIUtil.join_fragment("https://example.com/schema", "meta")
      "https://example.com/schema#meta"

      iex> JSONSchex.URIUtil.join_fragment("https://example.com/schema", "/$defs/foo")
      "https://example.com/schema#/$defs/foo"

      iex> JSONSchex.URIUtil.join_fragment("https://example.com/schema", nil)
      "https://example.com/schema"

      iex> JSONSchex.URIUtil.join_fragment("https://example.com/schema", "")
      "https://example.com/schema#"

      iex> JSONSchex.URIUtil.join_fragment("", "/$defs/foo")
      "#/$defs/foo"
  """
  @spec join_fragment(String.t(), String.t() | nil) :: String.t()
  def join_fragment(base, nil) when is_binary(base), do: base
  def join_fragment(base, fragment) when is_binary(base) and is_binary(fragment), do: base <> "#" <> fragment

  @doc "Deprecated alias for `join_fragment/2`."
  @deprecated "Use join_fragment/2 instead"
  @spec with_fragment(String.t(), String.t() | nil) :: String.t()
  defdelegate with_fragment(base, fragment), to: __MODULE__, as: :join_fragment

  @doc """
  Converts a fragment into a local reference string.

  The fragment should be provided without the leading `#`. Passing `nil` returns `"#"`.

  ## Examples

      iex> JSONSchex.URIUtil.local_ref("meta")
      "#meta"

      iex> JSONSchex.URIUtil.local_ref("/$defs/foo")
      "#/$defs/foo"

      iex> JSONSchex.URIUtil.local_ref(nil)
      "#"
  """
  @spec local_ref(String.t() | nil) :: String.t()
  def local_ref(nil), do: "#"
  def local_ref(fragment) when is_binary(fragment), do: "#" <> fragment

  @doc """
  Checks if a reference string represents a remote URI (http or https).

  ## Examples

      iex> JSONSchex.URIUtil.remote_ref?("https://example.com/schema.json")
      true

      iex> JSONSchex.URIUtil.remote_ref?("http://example.com/schema.json")
      true

      iex> JSONSchex.URIUtil.remote_ref?("#/definitions/user")
      false

      iex> JSONSchex.URIUtil.remote_ref?("urn:uuid:12345")
      false

  """
  @spec remote_ref?(String.t()) :: boolean()
  # Optimization: Use binary pattern matching with case-insensitive check
  def remote_ref?(<<h, t, t2, p, ?:, ?/, ?/, _rest::binary>>)
      when (h == ?h or h == ?H) and (t == ?t or t == ?T) and (t2 == ?t or t2 == ?T) and (p == ?p or p == ?P),
      do: true
  def remote_ref?(<<h, t, t2, p, s, ?:, ?/, ?/, _rest::binary>>)
      when (h == ?h or h == ?H) and (t == ?t or t == ?T) and (t2 == ?t or t2 == ?T) and
           (p == ?p or p == ?P) and (s == ?s or s == ?S),
      do: true
  def remote_ref?(_), do: false

  @doc false
  def external_ref?(ref) when is_binary(ref), do: base(ref) != ""

  def external_ref?(_), do: false

  defp filesystem_path_uri?(uri) when is_binary(uri) do
    String.starts_with?(uri, "/") and URI.parse(uri).scheme == nil
  end

  defp resolve_filesystem_path(base, "#" <> _ = fragment_ref) do
    base_without_fragment = base(base)
    base_without_fragment <> fragment_ref
  end

  defp resolve_filesystem_path(base, uri) do
    case URI.parse(uri) do
      %{scheme: scheme} when is_binary(scheme) ->
        uri

      _ ->
        {uri_path, uri_fragment} = split_fragment(uri)

        resolved_path =
          if String.starts_with?(uri_path, "/") do
            uri_path
          else
            base_path = base(base)
            expanded_path = Path.expand(uri_path, Path.dirname(base_path))

            if String.ends_with?(uri_path, "/") do
              expanded_path <> "/"
            else
              expanded_path
            end
          end

        join_fragment(resolved_path, uri_fragment)
    end
  end
end

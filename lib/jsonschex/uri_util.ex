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
  def resolve(base, uri) do
    try do
      base |> URI.merge(uri) |> URI.to_string()
    rescue
      _ -> uri
    end
  end

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
end

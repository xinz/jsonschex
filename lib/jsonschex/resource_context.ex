defmodule JSONSchex.ResourceContext do
  @moduledoc false

  alias JSONSchex.URIUtil

  @type t :: %{
          target: term(),
          resource: term(),
          resource_base: String.t() | nil,
          inherited_base: String.t() | nil,
          resources: [{map(), String.t() | nil}]
        }

  @doc false
  @spec resolve(term(), String.t() | nil, String.t() | nil) :: {:ok, t()} | :error
  def resolve(document, initial_base, fragment) do
    with {:ok, tokens} <- decode_tokens(fragment) do
      walk(document, tokens, initial_base, document, initial_base, [])
    else
      _ -> :error
    end
  end

  defp decode_tokens(nil), do: {:ok, []}
  defp decode_tokens(fragment) when is_binary(fragment) do
    ExJSONPointer.decode_path("#" <> fragment)
  end

  defp walk(value, [], current_base, resource, resource_base, resources) do
    case value do
      %{"$id" => id} when is_binary(id) ->
        {:ok,
         %{
           target: value,
           resource: value,
           resource_base: current_base,
           inherited_base: current_base,
           resources: Enum.reverse([{value, current_base} | resources])
         }}

      _ ->
        {:ok,
         %{
           target: value,
           resource: resource,
           resource_base: resource_base,
           inherited_base: current_base,
           resources: Enum.reverse(resources)
         }}
    end
  end

  defp walk(map, [token | rest], current_base, resource, resource_base, resources) when is_map(map) do
    {current_base, resource, resource_base, resources} =
      case Map.get(map, "$id") do
        id when is_binary(id) ->
          {URIUtil.resolve(current_base, id), map, current_base, [{map, current_base} | resources]}

        _ ->
          {current_base, resource, resource_base, resources}
      end

    case Map.fetch(map, token) do
      {:ok, value} -> walk(value, rest, current_base, resource, resource_base, resources)
      :error -> :error
    end
  end

  defp walk(list, [token | rest], current_base, resource, resource_base, resources) when is_list(list) do
    case Integer.parse(token) do
      {index, ""} when index >= 0 ->
        case Enum.fetch(list, index) do
          {:ok, value} -> walk(value, rest, current_base, resource, resource_base, resources)
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp walk(_value, _tokens, _current_base, _resource, _resource_base, _resources), do: :error
end

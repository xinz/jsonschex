defmodule JSONSchex.JSON do
  @moduledoc false

  # Delegates to JSON in Elixir v1.18+ or Jason for earlier versions

  cond do
    Code.ensure_loaded?(JSON) ->
      defdelegate decode(data), to: JSON
      defdelegate decode!(data), to: JSON
      defdelegate encode!(data), to: JSON
      defdelegate encode_to_iodata!(data), to: JSON

    Code.ensure_loaded?(Jason) ->
      defdelegate decode(data), to: Jason
      defdelegate decode!(data), to: Jason
      defdelegate encode!(data), to: Jason
      defdelegate encode_to_iodata!(data), to: Jason

    true ->
      message = """
      Missing a compatible JSON library, add `{:jason, "~> 1.0"}` to your deps in mix.exs
      """

      IO.warn(message, Macro.Env.stacktrace(__ENV__))
  end
end

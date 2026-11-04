defmodule JSONSchex.Validator.Pattern do
  @moduledoc false

  alias JSONSchex.Types.{Error, ErrorContext}

  @run_options [:report_errors, {:capture, :none}]

  @doc false
  @spec match?(Regex.t(), String.t(), list()) :: boolean()
  def match?(%Regex{re_pattern: compiled} = regex, subject, path) when is_binary(subject) do
    case :re.run(subject, compiled, @run_options) do
      :match ->
        true

      :nomatch ->
        false

      {:error, reason} ->
        # Only the public validation boundary catches this tag. An ordinary
        # validation error could be inverted by not or ignored by a combinator.
        throw({__MODULE__,
               %Error{
                 path: path,
                 rule: :indeterminate_pattern,
                 value: subject,
                 context: %ErrorContext{contrast: regex, input: subject, error_detail: reason}
               }})
    end
  end

end

defmodule JSONSchex.Types do
  @moduledoc """
  Defines the core data structures used by JSONSchex.
  """

  defmodule Schema do
    @moduledoc """
    A compiled JSON Schema, containing executable validation rules and a
    definition registry for reference resolution.
    """
    @type t :: %__MODULE__{
      rules: list(JSONSchex.Types.Rule.t()),
      defs: map() | nil,
      # Used for error reporting context
      source_id: String.t() | nil,
      raw: map() | nil,
      external_loader: (String.t() -> {:ok, map()} | {:error, term()}) | nil,
      format_assertion: boolean(),
      content_assertion: boolean()
    }
    defstruct [:rules, :defs, :source_id, :raw, :external_loader, format_assertion: false, content_assertion: false]
  end

  defmodule ValidationContext do
    @moduledoc """
    Lightweight runtime context threaded through validation.

    Holds a reference to the immutable root `Schema` and carries per-scope
    state (scope stack, current source ID, raw schema) that changes as
    validation descends through `$id` boundaries.
    """
    @type t :: %__MODULE__{
      root_schema: JSONSchex.Types.Schema.t(),
      scope_stack: list(String.t()),
      source_id: String.t() | nil,
      raw: map() | nil
    }
    defstruct [
      :root_schema,
      :source_id,
      :raw,
      scope_stack: []
    ]
  end

  defmodule Rule do
    @moduledoc """
    A single compiled validation step.

    The `validator` function accepts `(data, {path, evaluated, context})` and returns
    `:ok`, `{:ok, evaluated_keys}`, or `{:error, errors}`.
    """
    @type t :: %__MODULE__{
      name: atom(),
      params: term(),
      validator: (term(), term() -> {:ok, MapSet.t()} | {:error, list()})
    }
    defstruct [:name, :params, :validator]
  end

  defmodule Error do
    @moduledoc """
    A validation error with path, rule, and optional message/context.

    Use `JSONSchex.format_error/1` to produce a human-readable string.
    """
    @type t :: %__MODULE__{
      path: list(),
      rule: atom(),
      message: String.t() | nil,
      context: map() | nil
    }
    defstruct [:path, :rule, :message, :context, :value]

    defimpl String.Chars do
      def to_string(t) do
        JSONSchex.ErrorFormatter.format(t)
      end
    end

  end

  defmodule CompileError do
    @moduledoc """
    An error encountered during schema compilation.
    """
    @type error :: :unsupported_vocabulary | :invalid_regex


    @type t :: %__MODULE__{
      error: error(),
      path: list() | nil,
      value: term() | nil,
      message: term() | nil
    }
    defstruct [:error, :path, :value, :message]

  end
end

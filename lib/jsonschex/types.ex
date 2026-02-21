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
      context: JSONSchex.Types.ErrorContext.t() | nil,
      value: term() | nil
    }
    defstruct [:path, :rule, :context, :value]

    defimpl String.Chars do
      def to_string(t) do
        JSONSchex.ErrorFormatter.format(t)
      end
    end

  end

  defmodule ErrorContext do
    @moduledoc """
    Structured detail carried by `JSONSchex.Types.Error` and `JSONSchex.Types.CompileError`.

    The three fields have consistent, role-based meanings across all validation rules:

    - `contrast` — The **schema constraint** that was not satisfied.
      Examples: the expected type (`"integer"`), a numeric limit (`10`),
      a list of allowed values, the required regex pattern.

    - `input` — The **processed representation** of the failing value.
      This is not always the raw input; it may be a derived quantity such as
      a string's codepoint length (for `minLength`/`maxLength`) or the inferred
      type name (for `type`). For remote-ref errors it holds the URI string.

    - `error_detail` — **Ancillary detail** needed to disambiguate error variants
      or carry supplementary information. Examples: a regex compilation error
      message, the string `"min"` / `"max"` to distinguish `contains` violations,
      or a nested `CompileError` from a remote schema.

    Use `JSONSchex.format_error/1` (or `to_string/1`) to turn an error into a
    human-readable message rather than inspecting these fields directly.
    """
    @type t :: %__MODULE__{
      contrast: term() | nil,
      input: term() | nil,
      error_detail: term() | nil
    }
    defstruct [:contrast, :input, :error_detail]
  end

  defmodule CompileError do
    @moduledoc """
    An error encountered during schema compilation.
    """
    @type error :: :unsupported_vocabulary | :invalid_regex | :invalid_keyword_value

    @type t :: %__MODULE__{
      error: error(),
      path: list() | nil,
      value: term() | nil,
      context: ErrorContext.t() | nil
    }
    defstruct [:error, :path, :value, :context]

    @non_neg_int_keywords ~w(minLength maxLength minProperties maxProperties minItems maxItems)
    @numeric_keywords ~w(minimum maximum exclusiveMinimum exclusiveMaximum)
    @valid_types ~w(string integer number boolean object array null)

    @doc false
    defguard is_non_neg_int_keywords?(value) when value in @non_neg_int_keywords

    @doc false
    defguard is_numeric_keywords?(value) when value in @numeric_keywords

    @doc false
    def valid_types, do: @valid_types

    @doc false
    defguard is_valid_types?(value) when value in @valid_types

    defimpl String.Chars do
      def to_string(t) do
        JSONSchex.ErrorFormatter.format(t)
      end
    end

  end
end

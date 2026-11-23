defmodule JSONSchex.Schema do
  @moduledoc """
  Compile-time helpers for embedding compiled JSON Schemas directly into modules.

  Use `compile!/2` when the schema is fully known at compile time, such as in
  generated modules, router metadata, module attributes, Plug/Phoenix code, and
  test fixtures.

  ## Examples

      iex> require JSONSchex.Schema
      iex> schema = JSONSchex.Schema.compile!(%{"type" => "integer", "minimum" => 10})
      iex> JSONSchex.validate(schema, 10)
      :ok

      iex> defmodule JSONSchexSchemaMacroExample do
      ...>   require JSONSchex.Schema
      ...>   @schema JSONSchex.Schema.compile!(%{"type" => "string", "format" => "email"}, format_assertion: true)
      ...>   def schema, do: @schema
      ...> end
      iex> {:error, [_]} = JSONSchex.validate(JSONSchexSchemaMacroExample.schema(), "not-an-email")
  """

  alias JSONSchex.Compiler
  alias JSONSchex.StaticCompiler
  alias JSONSchex.Types.{Error, Schema}

  @doc """
  Compiles a static schema literal at compile time and embeds the compiled
  `JSONSchex.Types.Schema` directly into the caller module.

  The schema argument must be a compile-time literal map or boolean. Options
  must also be compile-time literals. If you pass `:loader`, prefer a
  remote capture such as `&MyLoader.fetch/1` so the compiled schema remains
  embeddable.

  ## Options

  The available options are the same as `JSONSchex.compile/2`:

  - `:loader` — `(uri -> {:ok, map()} | {:error, term()})` for remote `$ref` schemas
  - `:base_uri` — Starting base URI for resolving relative references
  - `:format_assertion` — Explicitly enable `format` validation (default: `false`); an active Draft 2020-12 format-assertion vocabulary also enables it.
  - `:content_assertion` — Enable strict content vocabulary validation (default: `false`)
  - `:draft` — Use `"draft7"` or `"draft2020_12"` (strings, not atoms). A recognized root `$schema` selects the draft when
    this option is omitted; a conflicting option raises a compile error. Without either, Draft 2020-12 is the default.

  ## Examples

      iex> require JSONSchex.Schema
      iex> schema = JSONSchex.Schema.compile!(%{"type" => "string", "format" => "email"}, format_assertion: true)
      iex> {:error, [_]} = JSONSchex.validate(schema, "not-an-email")

      iex> draft7 = JSONSchex.Schema.compile!(%{"$schema" => "http://json-schema.org/draft-07/schema#", "items" => [%{"type" => "integer"}], "additionalItems" => false})
      iex> JSONSchex.validate(draft7, [1])
      :ok
      iex> match?({:error, [_ | _]}, JSONSchex.validate(draft7, [1, 2]))
      true
  """
  defmacro compile!(schema_ast, opts_ast \\ []) do
    compile_ast!(schema_ast, opts_ast, __CALLER__)
  end

  @doc """
  Compiles a static JSON Schema fragment at compile time and embeds the compiled
  `JSONSchex.Types.Schema` directly into the caller module.

  Accepts a containing document plus options. Local references inside the
  fragment resolve against the containing document, which is useful for OpenAPI
  3.1 request/response schemas.

  ## Examples

      iex> require JSONSchex.Schema
      iex> schema = JSONSchex.Schema.compile_fragment!(
      ...>   %{"components" => %{"schemas" => %{"Name" => %{"type" => "string"}}}, "schema" => %{"$ref" => "#/components/schemas/Name"}},
      ...>   entry: "#/schema"
      ...> )
      iex> JSONSchex.validate(schema, "Alice")
      :ok
  """
  defmacro compile_fragment!(document_ast, opts_ast) do
    compile_fragment_ast!(document_ast, opts_ast, __CALLER__)
  end

  @doc """
  Generates compile-time JIT-friendly validator function(s) from a static schema.

  Accepts a raw map/boolean literal (with optional compiler `opts`), a `~X` sigil,
  a `compile!/2` / `compile_fragment!/2` expression, or a module attribute (`@schema`)
  holding any of the above.

  When `name` does not end with `?` (e.g., `:validate_user`), this macro defines:

  - `validate_user?(data) :: boolean()` — a specialized, short-circuiting predicate
    with the same branch-skipping behavior as `JSONSchex.valid?/2`.
  - `validate_user(data) :: :ok | {:error, [JSONSchex.Types.Error.t()]}` — returns
    the same diagnostics as `JSONSchex.validate/2`, including regex engine errors.
    For fully specialized checks that cannot signal a regex engine error, a
    successful predicate returns `:ok` without running detailed validation.

  When `name` ends with `?` (e.g., `:valid_user?`), only the boolean predicate
  `valid_user?/1` is generated.

  `use JSONSchex` automatically imports both `~X` and `defvalidator/2,3`.

  Any keywords outside the static subset (such as `$ref`, `$dynamicRef`, or
  `unevaluatedProperties`) transparently fall back to the embedded compiled schema,
  preserving full JSON Schema specification compliance.

  ## Examples

      iex> defmodule JSONSchexDefvalidatorExample do
      ...>   use JSONSchex
      ...>   defvalidator :validate_user, ~X|%{"type" => "object", "required" => ["name", "age"], "properties" => %{"name" => %{"type" => "string", "minLength" => 1}, "age" => %{"type" => "integer", "minimum" => 0}}}|
      ...>   @email_schema %{"type" => "string", "format" => "email"}
      ...>   defvalidator :validate_email, @email_schema, format_assertion: true
      ...> end
      iex> JSONSchexDefvalidatorExample.validate_user?(%{"name" => "Ada", "age" => 36})
      true
      iex> JSONSchexDefvalidatorExample.validate_user(%{"name" => "Ada", "age" => 36})
      :ok
      iex> {:error, [%{rule: :minimum}]} = JSONSchexDefvalidatorExample.validate_user(%{"name" => "Ada", "age" => -1})
      iex> JSONSchexDefvalidatorExample.validate_email("ada@example.com")
      :ok
      iex> {:error, [%{rule: :format}]} = JSONSchexDefvalidatorExample.validate_email("not-an-email")
  """
  defmacro defvalidator(name, schema_ast, opts_ast \\ []) when is_atom(name) do
    defvalidator_ast!(name, schema_ast, opts_ast, __CALLER__)
  end

  @doc false
  def defvalidator_ast!(name, schema_ast, opts_ast, caller) do
    if contains_module_attribute?(schema_ast) or contains_module_attribute?(opts_ast) do
      quote do
        JSONSchex.Schema.__define_validator__(
          unquote(name),
          unquote(schema_ast),
          unquote(opts_ast),
          __ENV__
        )
      end
    else
      opts = static_term!(opts_ast, caller, "options", "JSONSchex.Schema.defvalidator/3")
      schema = static_term!(schema_ast, caller, "schema", "JSONSchex.Schema.defvalidator/3")
      build_defvalidator_quoted!(name, schema, opts, caller)
    end
  end

  @doc false
  def __define_validator__(name, schema, opts, env) do
    quoted = build_defvalidator_quoted!(name, schema, opts, env)
    Code.eval_quoted(quoted, [], env)
  end

  defp build_defvalidator_quoted!(name, schema, opts, caller) do
    source = "JSONSchex.Schema.defvalidator/3"

    compiled =
      case schema do
        %Schema{} = already_compiled ->
          if opts != [] do
            raise_compile_error!(
              caller,
              "#{source} does not accept options when given an already-compiled schema; " <>
                "pass options to ~X or JSONSchex.Schema.compile!/2 instead"
            )
          end

          already_compiled

        raw ->
          compile_schema_value!(raw, opts, caller, source)
      end

    {body_ast, helper_defs, may_abort_on_pattern?} =
      try do
        StaticCompiler.compile(name, compiled)
      rescue
        error in ArgumentError ->
          raise_compile_error!(
            caller,
            "#{source} could not embed the compiled schema: #{Exception.message(error)}. " <>
              "Use only compile-time embeddable values such as literals and remote captures like &Mod.fun/1."
          )
      end

    data_var = Macro.var(:data, StaticCompiler)

    predicate_body =
      if may_abort_on_pattern? do
        quote do
          try do
            unquote(body_ast)
          catch
            {JSONSchex.Validator.Pattern, %JSONSchex.Types.Error{}} -> false
          end
        end
      else
        body_ast
      end

    name_str = Atom.to_string(name)

    if String.ends_with?(name_str, "?") do
      quote do
        @spec unquote(name)(term()) :: boolean()
        def unquote(name)(unquote(data_var)) do
          unquote(predicate_body)
        end

        unquote_splicing(helper_defs)
      end
    else
      escaped_compiled = escape_embeddable!(compiled, caller, source)
      pred_name = String.to_atom(name_str <> "?")
      detailed = quote do: JSONSchex.validate(unquote(escaped_compiled), data)

      # A boolean success does not rule out a regex error in a skipped branch.
      # Choose the diagnostic path at compile time; never run a loader twice here.
      diagnostic_body =
        if may_abort_on_pattern? do
          detailed
        else
          quote do: if(unquote(pred_name)(data), do: :ok, else: unquote(detailed))
        end

      quote do
        @spec unquote(name)(term()) :: :ok | {:error, list(JSONSchex.Types.Error.t())}
        def unquote(name)(data), do: unquote(diagnostic_body)

        @spec unquote(pred_name)(term()) :: boolean()
        def unquote(pred_name)(unquote(data_var)) do
          unquote(predicate_body)
        end

        unquote_splicing(helper_defs)
      end
    end
  end

  @doc false
  def compile_ast!(schema_ast, opts_ast, caller) do
    if contains_module_attribute?(schema_ast) or contains_module_attribute?(opts_ast) do
      quote do
        JSONSchex.Schema.embed!(
          unquote(schema_ast),
          unquote(opts_ast),
          unquote(caller.file),
          unquote(caller.line)
        )
      end
    else
      compile_literal_ast!(schema_ast, opts_ast, caller)
    end
  end

  @doc false
  def embed!(schema, opts, file, line) do
    compile_schema_value!(schema, opts, %{file: file, line: line}, "JSONSchex.Schema.compile!/2")
  end

  @doc false
  def compile_fragment_ast!(document_ast, opts_ast, caller) do
    if contains_module_attribute?(document_ast) or contains_module_attribute?(opts_ast) do
      quote do
        JSONSchex.Schema.embed_fragment!(
          unquote(document_ast),
          unquote(opts_ast),
          unquote(caller.file),
          unquote(caller.line)
        )
      end
    else
      compile_fragment_literal_ast!(document_ast, opts_ast, caller)
    end
  end

  @doc false
  def embed_fragment!(document, opts, file, line) do
    compile_fragment_value!(document, opts, %{file: file, line: line})
  end

  defp compile_literal_ast!(schema_ast, opts_ast, caller) do
    source = "JSONSchex.Schema.compile!/2"
    schema = static_term!(schema_ast, caller, "schema", source)
    opts = static_term!(opts_ast, caller, "options", source)

    schema
    |> compile_schema_value!(opts, caller, source)
    |> escape_embeddable!(caller, source)
  end

  defp compile_schema_value!(schema, _opts, caller, source)
       when not (is_map(schema) or is_boolean(schema)) do
    raise_compile_error!(
      caller,
      "#{source} expects a compile-time map or boolean schema literal"
    )
  end

  defp compile_schema_value!(schema, opts, caller, source) do
    if not Keyword.keyword?(opts) do
      raise_compile_error!(
        caller,
        "#{source} expects options to be a compile-time keyword list"
      )
    end

    case Compiler.compile(schema, opts) do
      {:ok, compiled} ->
        compiled

      {:error, %Error{} = error} ->
        raise_compile_error!(
          caller,
          "#{source} failed: #{JSONSchex.format_error(error)}"
        )

      {:error, error} ->
        raise_compile_error!(caller, "#{source} failed: #{inspect(error)}")
    end
  end

  defp compile_fragment_literal_ast!(document_ast, opts_ast, caller) do
    source = "JSONSchex.Schema.compile_fragment!/2"
    document = static_term!(document_ast, caller, "document", source)
    opts = static_term!(opts_ast, caller, "options", source)

    document
    |> compile_fragment_value!(opts, caller)
    |> escape_embeddable!(caller, source)
  end

  defp compile_fragment_value!(document, opts, caller) do
    if not Keyword.keyword?(opts) do
      raise_compile_error!(
        caller,
        "JSONSchex.Schema.compile_fragment!/2 expects options to be a compile-time keyword list"
      )
    end

    case Compiler.compile_fragment(document, opts) do
      {:ok, compiled} ->
        compiled

      {:error, %Error{} = error} ->
        raise_compile_error!(
          caller,
          "JSONSchex.Schema.compile_fragment!/2 failed: #{JSONSchex.format_error(error)}"
        )
    end
  end

  defp escape_embeddable!(compiled, caller, source) do
    Macro.escape(compiled)
  rescue
    error in ArgumentError ->
      raise_compile_error!(
        caller,
        "#{source} could not embed the compiled schema: #{Exception.message(error)}. " <>
          "Use only compile-time embeddable values such as literals and remote captures like &Mod.fun/1."
      )
  end

  defp static_term!(ast, caller, label, source) do
    case quoted_static_to_term(ast, caller) do
      {:ok, value} ->
        value

      :error ->
        raise_compile_error!(
          caller,
          "#{source} expects #{label} to be fully known at compile time"
        )
    end
  end

  defp quoted_static_to_term(ast, caller) do
    ast = Macro.expand(ast, caller)

    case ast do
      {:__block__, _, [expr]} ->
        quoted_static_to_term(expr, caller)

      ast ->
        if Macro.quoted_literal?(ast) do
          {:ok, literal_ast_to_term(ast, caller)}
        else
          nonliteral_static_to_term(ast, caller)
        end
    end
  end

  defp literal_ast_to_term(ast, caller) do
    {value, _binding} = Code.eval_quoted(ast, [], caller)
    value
  end

  defp nonliteral_static_to_term(ast, caller) when is_list(ast) do
    with {:ok, values} <- reduce_static_terms(ast, caller) do
      {:ok, Enum.reverse(values)}
    end
  end

  defp nonliteral_static_to_term({:%{}, _, pairs}, caller) when is_list(pairs) do
    with {:ok, kvs} <- reduce_static_terms(pairs, caller) do
      {:ok, Map.new(Enum.reverse(kvs))}
    end
  end

  defp nonliteral_static_to_term({:{}, _, elems}, caller) when is_list(elems) do
    with {:ok, values} <- reduce_static_terms(elems, caller) do
      {:ok, values |> Enum.reverse() |> List.to_tuple()}
    end
  end

  defp nonliteral_static_to_term({:-, _, [value]}, _caller) when is_number(value),
    do: {:ok, -value}

  defp nonliteral_static_to_term({:+, _, [value]}, _caller) when is_number(value),
    do: {:ok, value}

  defp nonliteral_static_to_term({{:., _, [:re, :import]}, _, [exported_ast]}, caller) do
    if Code.ensure_loaded?(:re) and function_exported?(:re, :import, 1) do
      with {:ok, exported} when is_tuple(exported) and elem(exported, 0) == :re_exported_pattern <-
             quoted_static_to_term(exported_ast, caller) do
        {:ok, apply(:re, :import, [exported])}
      else
        _ -> :error
      end
    else
      :error
    end
  end

  defp nonliteral_static_to_term(ast, caller) when is_tuple(ast) do
    case remote_capture_to_term(ast, caller) do
      {:ok, _} = result ->
        result

      :error ->
        if ast_node?(ast) do
          :error
        else
          with {:ok, values} <- ast |> Tuple.to_list() |> reduce_static_terms(caller) do
            {:ok, values |> Enum.reverse() |> List.to_tuple()}
          end
        end
    end
  end

  defp nonliteral_static_to_term(_, _caller), do: :error

  defp reduce_static_terms(enumerable, caller) do
    Enum.reduce_while(enumerable, {:ok, []}, fn item, {:ok, acc} ->
      case quoted_static_to_term(item, caller) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp remote_capture_to_term(
         {:&, _, [{:/, _, [{{:., _, [module_ast, function_name]}, _, []}, arity]}]},
         caller
       )
       when is_atom(function_name) and is_integer(arity) do
    module = Macro.expand(module_ast, caller)

    if is_atom(module) do
      {:ok, Function.capture(module, function_name, arity)}
    else
      :error
    end
  end

  defp remote_capture_to_term(_, _caller), do: :error

  defp ast_node?({name, meta, context})
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_list(context)),
       do: true

  defp ast_node?(_), do: false

  defp contains_module_attribute?(ast) do
    Macro.prewalk(ast, nil, fn
      {:@, _, _} = node, acc ->
        throw({"contains_module_attribute", node, acc})

      node, acc ->
        {node, acc}
    end)

    false
  catch
    {"contains_module_attribute", _node, _acc} ->
      true
  end

  defp raise_compile_error!(caller, description) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: description
  end
end

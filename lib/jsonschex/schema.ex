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
  alias JSONSchex.Types.Error

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
  - `:format_assertion` — Enable strict `format` validation (default: `false`)
  - `:content_assertion` — Enable strict content vocabulary validation (default: `false`)

  ## Examples

      iex> require JSONSchex.Schema
      iex> schema = JSONSchex.Schema.compile!(%{"type" => "string", "format" => "email"}, format_assertion: true)
      iex> {:error, [_]} = JSONSchex.validate(schema, "not-an-email")
  """
  defmacro compile!(schema_ast, opts_ast \\ []) do
    compile_ast!(schema_ast, opts_ast, __CALLER__)
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
    compile_schema_value!(schema, opts, %{file: file, line: line})
  end

  defp compile_literal_ast!(schema_ast, opts_ast, caller) do
    schema = static_term!(schema_ast, caller, "schema")
    opts = static_term!(opts_ast, caller, "options")

    schema
    |> compile_schema_value!(opts, caller)
    |> escape_embeddable!(caller)
  end

  defp compile_schema_value!(schema, _opts, caller)
       when not (is_map(schema) or is_boolean(schema)) do
    raise_compile_error!(
      caller,
      "JSONSchex.Schema.compile!/2 expects a compile-time map or boolean schema literal"
    )
  end

  defp compile_schema_value!(schema, opts, caller) do
    if not Keyword.keyword?(opts) do
      raise_compile_error!(
        caller,
        "JSONSchex.Schema.compile!/2 expects options to be a compile-time keyword list"
      )
    end

    case Compiler.compile(schema, opts) do
      {:ok, compiled} ->
        compiled

      {:error, %Error{} = error} ->
        raise_compile_error!(
          caller,
          "JSONSchex.Schema.compile!/2 failed: #{JSONSchex.format_error(error)}"
        )

      {:error, error} ->
        raise_compile_error!(caller, "JSONSchex.Schema.compile!/2 failed: #{inspect(error)}")
    end
  end

  defp escape_embeddable!(compiled, caller) do
    Macro.escape(compiled)
  rescue
    error in ArgumentError ->
      raise_compile_error!(
        caller,
        "JSONSchex.Schema.compile!/2 could not embed the compiled schema: #{Exception.message(error)}. " <>
          "Use only compile-time embeddable values such as literals and remote captures like &Mod.fun/1."
      )
  end

  defp static_term!(ast, caller, label) do
    case quoted_static_to_term(ast, caller) do
      {:ok, value} ->
        value

      :error ->
        raise_compile_error!(
          caller,
          "JSONSchex.Schema.compile!/2 expects #{label} to be fully known at compile time"
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

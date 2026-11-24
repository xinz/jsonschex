defmodule JSONSchex.Test.SuiteRunner do
  alias JSONSchex.Draft202012.Dialect, as: Draft202012Dialect
  alias JSONSchex.Draft7.Dialect, as: Draft7Dialect
  alias JSONSchex.JSON

  @default_draft "draft2020_12"

  # -------------------------------------------------------------------------
  # Mode 1: Run a Single File (default draft: Draft 2020-12)
  # -------------------------------------------------------------------------
  defmacro run_suite(path_ast) do
    {path, _} = Code.eval_quoted(path_ast)
    run_suite_ast(path, [])
  end

  # -------------------------------------------------------------------------
  # Mode 2: Run a Directory or Single File with Options / Filtering
  # -------------------------------------------------------------------------
  defmacro run_suite(path_ast, opts_ast) do
    {path, _} = Code.eval_quoted(path_ast)
    {opts, _} = Code.eval_quoted(opts_ast)
    run_suite_ast(path, opts)
  end

  @doc """
  Checks whether a JSON Schema Test Suite `compatibility` constraint string
  applies to `version_under_test` (e.g. `7` for Draft 7, `2020` for Draft 2020-12).

  Implements the matching algorithm specified in `validation/README.md`.
  """
  def compatible?(nil, _version_under_test), do: true

  def compatible?(compatibility, version_under_test)
      when is_binary(compatibility) and is_integer(version_under_test) do
    compatibility
    |> String.split(",")
    |> Enum.reduce_while(true, fn raw_constraint, _acc ->
      {operator, version} = parse_compatibility_constraint(String.trim(raw_constraint))

      is_valid =
        case operator do
          "" -> version_under_test >= version
          ">=" -> version_under_test >= version
          "<=" -> version_under_test <= version
          "=" -> version_under_test == version
        end

      if version_under_test <= version do
        {:halt, is_valid}
      else
        {:cont, is_valid}
      end
    end)
  end

  defp parse_compatibility_constraint(constraint) do
    case Regex.run(~r/^(<=|>=|=)?(\d+)$/, constraint) do
      [_, operator, version] ->
        {operator, String.to_integer(version)}

      _ ->
        raise ArgumentError, "Invalid compatibility constraint: #{inspect(constraint)}"
    end
  end

  # -------------------------------------------------------------------------
  # Shared Logic (Private)
  # -------------------------------------------------------------------------

  defp run_suite_ast(path, opts) do
    draft = Keyword.get(opts, :draft) || @default_draft
    ignore_suites = Keyword.get(opts, :ignore_suites, [])

    if File.regular?(path) do
      filename_display = Path.basename(path, ".json")
      test_nodes = generate_tests_for_file(path, draft, filename_display, ignore_suites)
      {:__block__, [], test_nodes}
    else
      ignore_files = Keyword.get(opts, :ignore_files, [])
      ignore_directories = Keyword.get(opts, :ignore_directories, [])

      files =
        Path.wildcard(Path.join(path, "**/*.json"))
        |> Enum.sort()
        |> Enum.filter(fn file_path ->
          relative_path = Path.relative_to(file_path, path)
          keyword_filename = String.replace_suffix(relative_path, ".json", "")

          excluded_dir? =
            Enum.any?(ignore_directories, fn ignore_dir ->
              normalized = String.trim_trailing(ignore_dir, "/")
              relative_path == normalized or String.starts_with?(relative_path, normalized <> "/")
            end)

          excluded_file? = keyword_filename in ignore_files

          not excluded_dir? and not excluded_file?
        end)

      if files == [] do
        IO.warn("No JSON files found in directory: #{inspect(path)}")
      end

      test_nodes =
        for file <- files do
          relative_display =
            file
            |> Path.relative_to(path)
            |> String.replace_suffix(".json", "")

          generate_tests_for_file(file, draft, relative_display, ignore_suites)
        end
        |> List.flatten()
        |> Enum.reject(&is_nil/1)

      {:__block__, [], test_nodes}
    end
  end

  defp generate_tests_for_file(file, draft, filename_display, ignore_suites) do
    # Parse JSON at compile time
    definitions = decode_suite_file(file)
    version_under_test = draft_to_version(draft)
    default_schema_uri = draft_to_schema_uri(draft)

    add_content_assertion =
      String.ends_with?(file, "optional/content.json")

    # A single file may contain multiple "suites" (describe blocks)
    for suite <- definitions,
        compatible?(suite["compatibility"], version_under_test),
        not suite_ignored?(filename_display, suite["description"], ignore_suites) do
      suite_desc = suite["description"]
      tags = suite["tags"] || []
      add_format_assertion = "format-assertion" in tags
      schema = maybe_put_default_schema(suite["schema"], default_schema_uri)
      external_schemas = suite["externalSchemas"] || %{}
      tests = suite["tests"]

      # Unroll Test Cases
      individual_tests =
        for case_data <- tests do
          description = case_data["description"]
          data = case_data["data"]
          expected_valid = case_data["valid"]

          # Conditional Assertion Logic (Avoids dead code warnings)
          assertion_block =
            if expected_valid do
              quote do
                case result do
                  :ok ->
                    :ok

                  {:error, errors} ->
                    flunk("""
                    Expected VALID, got ERRORS.
                    File: #{unquote(file)}
                    Suite: #{unquote(suite_desc)}
                    Case: #{unquote(description)}
                    Data: #{inspect(data)}
                    Errors: #{inspect(errors)}
                    """)
                end
              end
            else
              quote do
                case result do
                  {:error, _} ->
                    :ok

                  :ok ->
                    flunk("""
                    Expected INVALID, got VALID.
                    File: #{unquote(file)}
                    Suite: #{unquote(suite_desc)}
                    Case: #{unquote(description)}
                    Data: #{inspect(data)}
                    """)
                end
              end
            end

          # The Actual Test AST
          quote do
            @tag :jsts
            test unquote("Case: #{description}") do
              loader =
                JSONSchex.Test.SuiteLoader.loader(
                  unquote(Macro.escape(external_schemas)),
                  default_schema_uri: unquote(default_schema_uri)
                )

              opts = [loader: loader, draft: unquote(draft)]

              opts =
                if unquote(add_format_assertion) do
                  opts ++ [format_assertion: true]
                else
                  opts
                end

              opts =
                if unquote(add_content_assertion) do
                  opts ++ [content_assertion: true]
                else
                  opts
                end

              compiled_result = JSONSchex.compile(unquote(Macro.escape(schema)), opts)

              data = unquote(Macro.escape(data))

              case compiled_result do
                {:ok, compiled} ->
                  result = JSONSchex.validate(compiled, data)
                  unquote(assertion_block)
                  assert JSONSchex.valid?(compiled, data) == unquote(expected_valid)

                {:error, msg} ->
                  flunk("Schema Compilation Failed: #{inspect(msg)}")
              end
            end
          end
        end

      # Wrap in Describe
      quote do
        describe unquote("JSTS: #{filename_display} - #{suite_desc}") do
          unquote(individual_tests)
        end
      end
    end
  end

  defp suite_ignored?(filename_display, suite_desc, ignore_suites) do
    Enum.any?(ignore_suites, fn
      {^filename_display, ^suite_desc} -> true
      ^suite_desc -> true
      _ -> false
    end)
  end

  defp draft_to_version("draft7"), do: 7
  defp draft_to_version("draft2020_12"), do: 2020

  defp draft_to_version(draft) do
    raise ArgumentError, "Unsupported draft for SuiteRunner: #{inspect(draft)}"
  end

  defp draft_to_schema_uri("draft7"), do: Draft7Dialect.schema_uri()
  defp draft_to_schema_uri("draft2020_12"), do: Draft202012Dialect.builtin_schema_uri()

  defp maybe_put_default_schema(schema, default_schema_uri)
       when is_map(schema) and is_binary(default_schema_uri) do
    Map.put_new(schema, "$schema", default_schema_uri)
  end

  defp maybe_put_default_schema(schema, _default_schema_uri), do: schema

  defp decode_suite_file(file) do
    case file |> File.read!() |> JSON.decode!() do
      %{"tests" => suites} when is_list(suites) -> suites
      suites when is_list(suites) -> suites
    end
  end

  defmacro __using__(_opts) do
    quote do
      import JSONSchex.Test.SuiteRunner
    end
  end
end

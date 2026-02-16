defmodule JSONSchex.Test.SuiteRunner do

  alias JSONSchex.JSON

  # -------------------------------------------------------------------------
  # Mode 1: Run a Single File (New)
  # -------------------------------------------------------------------------
  defmacro run_suite(file_path_ast) do
    # 1. Resolve the single path
    {file_path, _} = Code.eval_quoted(file_path_ast)

    # 2. Generate tests for just this file
    test_nodes = generate_tests_for_file(file_path)

    {:__block__, [], test_nodes}
  end

  # -------------------------------------------------------------------------
  # Mode 2: Run a Directory with Filtering (Existing)
  # -------------------------------------------------------------------------
  defmacro run_suite(directory_ast, ignore_list_ast) do
    # 1. Resolve Arguments
    {directory, _} = Code.eval_quoted(directory_ast)
    {ignore_list, _} = Code.eval_quoted(ignore_list_ast)

    ignore_files = Keyword.get(ignore_list, :ignore_files, [])
    ignore_directories = Keyword.get(ignore_list, :ignore_directories, [])

    # 2. File Discovery & Filtering
    files =
      Path.wildcard(Path.join(directory, "**/*.json"))
      |> Enum.filter(fn path ->
        relative_path = Path.relative_to(path, directory)
        keyword_filename = String.replace_suffix(relative_path, ".json", "")

        excluded_dir? =
          Enum.any?(ignore_directories, fn ignore_dir ->
            String.starts_with?(relative_path, ignore_dir)
          end)

        excluded_file? = keyword_filename in ignore_files

        not excluded_dir? and not excluded_file?
      end)

    if files == [] do
      IO.warn("No JSON files found in directory: #{inspect(directory)}")
    end

    # 3. Generate Test Code
    test_nodes =
      for file <- files do
        # REUSE: Call the shared generator
        generate_tests_for_file(file)
      end
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    {:__block__, [], test_nodes}
  end

  # -------------------------------------------------------------------------
  # Shared Logic (Private)
  # -------------------------------------------------------------------------

  defp generate_tests_for_file(file) do
    # Parse JSON at compile time
    definitions = File.read!(file) |> JSON.decode!()
    filename_display = Path.basename(file, ".json")
    hardcode_tmp_ignore_cases = []

    add_format_assertion =
      if String.contains?(file, "optional/format"), do: true, else: false

    # A single file may contain multiple "suites" (describe blocks)
    for {suite, _index} <- Enum.with_index(definitions) do
      suite_desc = suite["description"]
      schema = suite["schema"]
      tests = suite["tests"]

      if suite_desc not in hardcode_tmp_ignore_cases do
        # Unroll Test Cases
        individual_tests =
          for {case_data, _} <- Enum.with_index(tests) do
            description = case_data["description"]

            data = case_data["data"]
            expected_valid = case_data["valid"]

            # Conditional Assertion Logic (Avoids dead code warnings)
            assertion_block =
              if expected_valid do
                quote do
                  case result do
                    :ok -> :ok
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
                    {:error, _} -> :ok
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
                opts = [external_loader: &JSONSchex.Test.SuiteLoader.load/1]
                opts =
                  if unquote(add_format_assertion) do
                    opts ++ [format_assertion: true]
                  else
                    opts
                  end
                compiled_result = JSONSchex.compile(unquote(Macro.escape(schema)), opts)

                data = unquote(Macro.escape(data))

                case compiled_result do
                  {:ok, compiled} ->
                    result = JSONSchex.validate(compiled, data)
                    unquote(assertion_block)

                  {:error, msg} ->
                    flunk("Schema Compilation Failed: #{msg}")
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
  end

  defmacro __using__(_opts) do
    quote do
      import JSONSchex.Test.SuiteRunner
    end
  end
end

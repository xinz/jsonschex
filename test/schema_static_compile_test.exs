defmodule JSONSchex.Test.SchemaStaticCompile.AttributeModule do
  require JSONSchex.Schema

  @raw_schema %{"type" => "string", "format" => "email"}
  @compiled JSONSchex.Schema.compile!(@raw_schema, format_assertion: true)

  def schema, do: @compiled
end

defmodule JSONSchex.Test.SchemaStaticCompile.SigilModule do
  import JSONSchex.Sigil, only: [sigil_X: 2]

  @compiled ~X|%{"type" => "integer", "minimum" => 5}|

  def schema, do: @compiled
end

defmodule JSONSchex.Test.SchemaStaticCompile.UseModule do
  use JSONSchex

  @compiled ~X|%{"type" => "string", "format" => "email"}|f

  def schema, do: @compiled
end

defmodule JSONSchex.Test.SchemaStaticCompile.LoaderModule do
  require JSONSchex.Schema

  def load("https://example.com/integer") do
    {:ok, %{"type" => "integer"}}
  end

  @compiled JSONSchex.Schema.compile!(%{"$ref" => "https://example.com/integer"},
              loader: &__MODULE__.load/1
            )

  def schema, do: @compiled
end

defmodule JSONSchex.Test.SchemaStaticCompile.Draft7Module do
  require JSONSchex.Schema

  @compiled JSONSchex.Schema.compile!(
              %{"items" => [%{"type" => "integer"}], "additionalItems" => false},
              draft: "draft7"
            )

  def schema, do: @compiled
end

defmodule JSONSchex.Test.SchemaStaticCompile do
  use ExUnit.Case

  doctest JSONSchex.Schema
  doctest JSONSchex.Sigil

  defp compile_error!(source, file) do
    assert_raise CompileError, fn ->
      Code.compile_string(source, file)
    end
  end

  test "compile!/2 embeds compiled schemas in module attributes" do
    schema = JSONSchex.Test.SchemaStaticCompile.AttributeModule.schema()

    assert :ok == JSONSchex.validate(schema, "user@example.com")
    assert {:error, [error]} = JSONSchex.validate(schema, "not-an-email")
    assert error.rule == :format
  end

  test "~X compiles Elixir schema literals" do
    schema = JSONSchex.Test.SchemaStaticCompile.SigilModule.schema()

    assert :ok == JSONSchex.validate(schema, 5)
    assert {:error, [error]} = JSONSchex.validate(schema, 4)
    assert error.rule == :minimum
  end

  test "use JSONSchex imports the ~X sigil" do
    schema = JSONSchex.Test.SchemaStaticCompile.UseModule.schema()

    assert :ok == JSONSchex.validate(schema, "user@example.com")
    assert {:error, [error]} = JSONSchex.validate(schema, "not-an-email")
    assert error.rule == :format
  end

  test "compile!/2 embeds the explicit Draft 7 option" do
    schema = JSONSchex.Test.SchemaStaticCompile.Draft7Module.schema()

    assert schema.draft == "draft7"
    assert :ok == JSONSchex.validate(schema, [1])
    assert {:error, [_]} = JSONSchex.validate(schema, [1, 2])
  end

  test "compile!/2 infers Draft 7 from the root $schema" do
    require JSONSchex.Schema

    schema = JSONSchex.Schema.compile!(
      %{"$schema" => "http://json-schema.org/draft-07/schema#", "items" => [true], "additionalItems" => false}
    )

    assert schema.draft == "draft7"
    assert :ok == JSONSchex.validate(schema, [1])
    assert {:error, [_]} = JSONSchex.validate(schema, [1, 2])
  end

  test "compile!/2 raises a compile error for a conflicting draft" do
    error =
      compile_error!(
        ~S"""
        defmodule JSONSchex.Test.ConflictingDraft do
          require JSONSchex.Schema
          @schema JSONSchex.Schema.compile!(%{"$schema" => "http://json-schema.org/draft-07/schema#"}, draft: "draft2020_12")
        end
        """,
        "test/support/conflicting_draft_compile_error.exs"
      )

    assert error.description =~ ":draft is \"draft2020_12\""
    assert error.file == "test/support/conflicting_draft_compile_error.exs"
  end

  test "compile!/2 preserves remote captures in embeddable options" do
    schema = JSONSchex.Test.SchemaStaticCompile.LoaderModule.schema()

    assert :ok == JSONSchex.validate(schema, 42)
    assert {:error, [error]} = JSONSchex.validate(schema, "42")
    assert error.rule == :type
  end

  test "compile!/2 rejects non-static schema expressions" do
    error =
      compile_error!(
        """
        defmodule JSONSchex.Test.DynamicSchema do
          require JSONSchex.Schema

          def schema(type) do
            JSONSchex.Schema.compile!(%{"type" => type})
          end
        end
        """,
        "test/support/dynamic_schema_compile_error.exs"
      )

    assert error.description =~ "schema to be fully known at compile time"
    assert error.file == "test/support/dynamic_schema_compile_error.exs"
    assert error.line == 5
  end

  test "compile!/2 rejects non-static options expressions" do
    error =
      compile_error!(
        """
        defmodule JSONSchex.Test.DynamicSchemaOpts do
          require JSONSchex.Schema

          def schema(opts) do
            JSONSchex.Schema.compile!(%{"type" => "integer"}, opts)
          end
        end
        """,
        "test/support/dynamic_schema_opts_compile_error.exs"
      )

    assert error.description =~ "options to be fully known at compile time"
    assert error.file == "test/support/dynamic_schema_opts_compile_error.exs"
    assert error.line == 5
  end

  test "compile!/2 rejects non-schema literals" do
    error =
      compile_error!(
        """
        defmodule JSONSchex.Test.InvalidLiteralSchema do
          require JSONSchex.Schema

          @schema JSONSchex.Schema.compile!(123)
          def schema, do: @schema
        end
        """,
        "test/support/invalid_literal_schema_compile_error.exs"
      )

    assert error.description =~ "map or boolean schema literal"
    assert error.file == "test/support/invalid_literal_schema_compile_error.exs"
    assert error.line == 4
  end

  test "compile!/2 rejects non-keyword literal options" do
    error =
      compile_error!(
        """
        defmodule JSONSchex.Test.InvalidLiteralOptions do
          require JSONSchex.Schema

          @schema JSONSchex.Schema.compile!(%{"type" => "integer"}, %{})
          def schema, do: @schema
        end
        """,
        "test/support/invalid_literal_options_compile_error.exs"
      )

    assert error.description =~ "options to be a compile-time keyword list"
    assert error.file == "test/support/invalid_literal_options_compile_error.exs"
    assert error.line == 4
  end

  test "compile!/2 surfaces schema compilation errors during compilation" do
    error =
      compile_error!(
        """
        defmodule JSONSchex.Test.InvalidStaticSchema do
          require JSONSchex.Schema

          @schema JSONSchex.Schema.compile!(%{"type" => "wat"})
          def schema, do: @schema
        end
        """,
        "test/support/invalid_static_schema_compile_error.exs"
      )

    assert error.description =~ "Keyword 'type' must be one of"
    assert error.file == "test/support/invalid_static_schema_compile_error.exs"
    assert error.line == 4
  end
end

defmodule JSONSchex.Test.ValidationLimits do
  use ExUnit.Case

  describe "Numeric Limits" do
    test "maximum and exclusiveMaximum" do
      # maximum: 10, exclusiveMaximum: 10
      # Draft 2020-12 allows both, though logically exclusive overrides inclusive if they are same value
      schema = %{
        "maximum" => 10,
        "exclusiveMaximum" => 10
      }
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, 9)

      # Fails exclusiveMaximum
      assert {:error, [error]} = JSONSchex.validate(compiled, 10)
      assert error.rule == :exclusiveMaximum
    end

    test "exclusiveMinimum" do
      schema = %{"exclusiveMinimum" => 5}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, 6)
      assert {:error, _} = JSONSchex.validate(compiled, 5)
    end

    test "multipleOf handles integers and floats" do
      schema = %{"multipleOf" => 0.5}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, 1.0)
      assert :ok == JSONSchex.validate(compiled, 1.5)
      assert :ok == JSONSchex.validate(compiled, 5) # Integer 5 is multiple of 0.5

      assert {:error, [error]} = JSONSchex.validate(compiled, 1.6)
      assert error.rule == :multipleOf
    end
  end

  describe "String Limits" do
    test "minLength and maxLength" do
      schema = %{"minLength" => 2, "maxLength" => 5}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, "hi")
      assert :ok == JSONSchex.validate(compiled, "hello")

      assert {:error, [err1]} = JSONSchex.validate(compiled, "a")
      assert err1.rule == :minLength

      assert {:error, [err2]} = JSONSchex.validate(compiled, "longer")
      assert err2.rule == :maxLength
    end

    test "handles unicode characters" do
      # "👍" is 1 grapheme
      schema = %{"maxLength" => 1}
      {:ok, compiled} = JSONSchex.compile(schema)

      assert :ok == JSONSchex.validate(compiled, "👍")
      assert {:error, _} = JSONSchex.validate(compiled, "ab")
    end
  end
end

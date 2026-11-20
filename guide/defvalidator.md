# Defining named validators with `defvalidator`

Use `defvalidator` when a schema is known at compile time and callers should validate a value by name, without passing a schema around. `~X` and `JSONSchex.Schema.compile!/2` produce a reusable schema **value**; `defvalidator` uses that value (or a raw schema) to define **functions** in the caller module. For schemas supplied at runtime, use `JSONSchex.compile/2` instead.

## Choose the return value by naming the function

`use JSONSchex` imports both `~X` and `defvalidator`. Define validators in the module body, using a literal atom for the function name:

```elixir
defmodule MyApp.Signup do
  use JSONSchex

  # A name without ? defines both validate_age/1 and validate_age?/1.
  defvalidator :validate_age, ~X|%{"type" => "integer", "minimum" => 18}|

  # A name ending in ? defines only the predicate. This schema is a raw Elixir map.
  @email_schema %{"type" => "string", "format" => "email"}
  defvalidator :valid_email?, @email_schema, format_assertion: true
end

true = MyApp.Signup.validate_age?(18)
:ok = MyApp.Signup.validate_age(18)
{:error, [%JSONSchex.Types.Error{rule: :minimum}]} = MyApp.Signup.validate_age(17)
false = MyApp.Signup.valid_email?("not-an-email")
```

Use the predicate for a yes/no decision. It runs specialized checks for supported rules, such as `type` and `minimum`; rules outside the static subset, such as `$ref` or `unevaluatedProperties`, use the embedded validator. When you need diagnostics, call `validate_age/1` directly: it returns `:ok` if the predicate succeeds and otherwise calls `JSONSchex.validate/2` to collect the errors. There is no need to call the predicate first.

## Set options when the schema is compiled

- **Raw map or boolean:** Pass compile options as the third argument to `defvalidator`, as with `format_assertion: true` above. The schema can be a literal or a module attribute.
- **`~X` sigil:** The sigil already compiles the schema. Use `~X|%{"type" => "string", "format" => "email"}|f` for the equivalent email check. The `f` modifier enables format assertions; `c` enables content assertions. The body is Elixir, not JSON.
- **Already compiled schema:** Pass the result of `JSONSchex.Schema.compile!/2` or `JSONSchex.Schema.compile_fragment!/2` directly or through a module attribute. Set options such as `:draft`, `:loader`, or the fragment's `:entry` on the original compilation call. `defvalidator` reuses the compiled schema; passing nonempty options alongside it (including alongside `~X`) raises `CompileError`.

For the difference between a `format` annotation and an assertion, see [Content and format assertions](content_and_format.md).

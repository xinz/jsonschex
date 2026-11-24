# Defining named validators with `defvalidator`

Use `defvalidator` when a schema is known at compile time and callers should validate a value by name, without passing a schema around. `~X` and `JSONSchex.Schema.compile!/2` produce a reusable schema **value**; `defvalidator` uses that value (or a raw schema) to define **functions** in the caller module. For schemas supplied at runtime, use `JSONSchex.compile/2` instead.

## Comparing `defvalidator` with `~X` and `compile!/2`

All three compile-time APIs avoid compiling raw JSON Schema maps on every request, but they serve different needs:

| API | What it embeds | How validation executes | When to choose it |
| --- | --- | --- | --- |
| `JSONSchex.Schema.compile!/2` | `%JSONSchex.Types.Schema{}` struct value | Runtime interpreter via `JSONSchex.validate/2` or `JSONSchex.valid?/2` | You need a schema value (for registries, router metadata, dynamic dispatch) with explicit compile options such as `:draft`, `:base_uri`, or `:loader` |
| `~X` sigil | Same `%JSONSchex.Types.Schema{}` struct value | Same runtime interpreter as `compile!/2` | Compact literal syntax for schema values (supports `f` / `c` modifiers) |
| `defvalidator/2,3` | Specialized Elixir function clauses & guards (plus embedded schema when needed) | Direct BEAM-JIT execution, with transparent fallback for non-static keywords | Fixed hot-path schemas called by function name where throughput and low memory allocation matter most |

### Performance characteristics and trade-offs

Because `defvalidator` lowers the static subset into native BEAM map pattern matches (`%{"a" => v1, "b" => v2}`), guards (`is_integer/1`, `>=`, `byte_size/1`), direct binary format/pattern calls, and tail-recursive list loops, it avoids walking compiled rule lists and allocating intermediate structures on hot paths:

- **Valid inputs (`name/1` and `name?/1`):** For fully specialized schemas without PCRE regex or interpreted fallbacks, `name/1` runs `name?/1` and returns `:ok` immediately on success. Both `name/1` and `name?/1` achieve nearly identical throughput — in local [Benchee benchmarks](https://github.com/xinz/jsonschex/blob/main/bench/static_schema_comparison_results.txt), roughly **1.7×–3.5× faster** than `~X` + `JSONSchex.validate/2` (and **1.5×–2.8× faster** than `~X` + `JSONSchex.valid?/2`) on user, nested order, and batch workloads, with up to **6× lower memory allocation** on nested objects.
- **Invalid inputs (`name?/1` vs `name/1`):**
  - The boolean predicate `name?/1` short-circuits directly inside compiled guards and clauses with near-zero allocation (often **2.5×–3.5× faster** than `~X` + `JSONSchex.valid?/2`).
  - The diagnostic function `name/1`, on an **invalid** input, first executes the fast predicate (returning `false`) and then calls `JSONSchex.validate/2` to collect full error details. When most inputs are valid (typical API traffic), this is a net win; if a workload expects predominantly invalid inputs and always requires full diagnostics, calling `JSONSchex.validate/2` directly on a `~X` / `compile!/2` schema avoids that extra predicate check.
- **Fallback-heavy and PCRE-heavy schemas:** When a schema relies heavily on `$ref`, `$dynamicRef`, `unevaluatedProperties`, or complex regex `pattern`s, `name/1` delegates directly to `JSONSchex.validate/2` (avoiding double evaluation), so runtime performance approaches `~X` + `validate/2` / `valid?/2`.
- **Module size:** Each `defvalidator` emits specialized bytecode in the caller module. If you have hundreds of large schemas that are validated infrequently, storing compiled values with `~X` / `compile!/2` keeps compiled module size smaller.

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

Use the predicate for a yes/no decision. Like `JSONSchex.valid?/2`, it can stop at the first matching `anyOf` branch when annotations are not needed. A regex engine error in a visited branch makes the predicate return `false`; skipped branches are not checked. Rules outside the static subset, such as `$ref` or `unevaluatedProperties`, use the embedded validator.

When you need diagnostics, call the function without `?` directly. For a schema such as `validate_age/1` above, a successful predicate is enough to return `:ok`; failures go to `JSONSchex.validate/2` for details. If the schema can run the regex engine for a `pattern` or contains an interpreted fallback, the generated diagnostic function uses `JSONSchex.validate/2` directly. This preserves errors such as `:indeterminate_pattern` even in a later `anyOf` branch, without validating the same input twice.

## Set options when the schema is compiled

- **Raw map or boolean:** Pass compile options as the third argument to `defvalidator`, as with `format_assertion: true` above. The schema can be a literal or a module attribute.
- **`~X` sigil:** The sigil already compiles the schema. Use `~X|%{"type" => "string", "format" => "email"}|f` for the equivalent email check. The `f` modifier enables format assertions; `c` enables content assertions. The body is Elixir, not JSON.
- **Already compiled schema:** Pass the result of `JSONSchex.Schema.compile!/2` or `JSONSchex.Schema.compile_fragment!/2` directly or through a module attribute. Set options such as `:draft`, `:loader`, or the fragment's `:entry` on the original compilation call. `defvalidator` reuses the compiled schema; passing nonempty options alongside it (including alongside `~X`) raises `CompileError`.

All schema values and options must be fully known at compile time (literals, module attributes, `~X`, `compile!/2`, `compile_fragment!/2`, or remote function captures). Passing runtime expressions raises `CompileError`.

## Remote `$ref` and the `:loader` option

Because `defvalidator` embeds the compiled schema into the caller module at compile time, `:loader` must be an embeddable **remote function capture** such as `&MyApp.SchemaLoader.fetch/1`. Anonymous functions (`fn uri -> ... end`) cannot be escaped into module bytecode and raise `CompileError` whenever the schema is embedded.

Pass `:loader` (and `:base_uri` for relative references) directly to `defvalidator/3` when compiling from a raw schema:

```elixir
defmodule MyApp.SchemaLoader do
  def fetch("https://example.com/address.json") do
    {:ok,
     %{
       "type" => "object",
       "required" => ["city"],
       "properties" => %{"city" => %{"type" => "string"}}
     }}
  end

  def fetch(_uri), do: {:error, :not_found}
end

defmodule MyApp.OrderValidator do
  use JSONSchex

  @order_schema %{
    "type" => "object",
    "required" => ["shipping"],
    "properties" => %{
      "shipping" => %{"$ref" => "address.json"}
    }
  }

  defvalidator :validate_order, @order_schema,
    base_uri: "https://example.com/order.json",
    loader: &MyApp.SchemaLoader.fetch/1
end

true = MyApp.OrderValidator.validate_order?(%{"shipping" => %{"city" => "Seattle"}})
{:error, [%{rule: :required}]} = MyApp.OrderValidator.validate_order(%{"shipping" => %{}})
```

When validating a fragment inside a larger document (such as an OpenAPI specification), pass `:loader` to `JSONSchex.Schema.compile_fragment!/2` and pass the compiled result to `defvalidator/2`:

```elixir
defmodule MyApp.OpenAPIValidators do
  use JSONSchex
  require JSONSchex.Schema

  @document %{
    "components" => %{
      "schemas" => %{
        "Order" => %{
          "type" => "object",
          "required" => ["shipping"],
          "properties" => %{"shipping" => %{"$ref" => "address.json"}}
        }
      }
    }
  }

  @order JSONSchex.Schema.compile_fragment!(
           @document,
           entry: "https://example.com/openapi.json#/components/schemas/Order",
           loader: &MyApp.SchemaLoader.fetch/1
         )

  defvalidator :validate_order, @order
end
```

Key notes on `:loader` with `defvalidator`:

- **When the loader runs:** `$ref` targets not already present in the schema's local `$defs`/registry are resolved through `:loader` at validation time (or at compile time when resolving a custom `$schema` meta-schema). For schemas containing `$ref`, the diagnostic function (`validate_order/1`) delegates directly to `JSONSchex.validate/2` so the loader is never called twice for the same input.
- **Preserved reference context:** Nested `$ref` and `$dynamicRef` fallbacks keep the root registry, enclosing `$id` resource boundaries, `:base_uri`, dynamic scope stack, and containing fragment document intact.
- **Avoid runtime fetches when possible:** If external schemas are known ahead of time, pre-bundle them (for example with `JSONSchex.bundle_fragment/2`) or inline them under `$defs` so validation has no runtime loader overhead.

See [Loader and remote `$ref` handling](loader.md) for the full loader return contract, `:base_uri` wrapper maps, and caching patterns.

## Documentation and `@spec`

`defvalidator` generates `@spec` annotations automatically for every emitted function. Place `@doc` directly above `defvalidator` to document the generated function:

```elixir
defmodule MyApp.Account do
  use JSONSchex

  @doc "Validates an account payload."
  defvalidator :validate_account, ~X|%{"type" => "object", "required" => ["id"]}|

  @doc "Returns whether the given value is a valid UUID."
  defvalidator :valid_id?, ~X|%{"type" => "string", "format" => "uuid"}|f
end
```

When a name does not end in `?`, `@doc` attaches to the primary diagnostic function (`validate_account/1`), leaving the companion predicate (`validate_account?/1`) undocumented.

## Static subset and fallback behavior

`defvalidator` compiles common keywords directly into BEAM map matches, guard checks, binary format/pattern calls, linear short-circuiting `oneOf`, and tail-recursive `items` helpers:

- **Specialized statically:** `type`, numeric bounds (`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`), `minLength`, `maxLength`, `pattern` (with binary fast paths for predefined ASCII shapes), `format`, `enum`, `const`, `required`, `properties`, `minProperties`, `maxProperties`, `additionalProperties` (`true` or `false` without `patternProperties`), single-schema `items`, `minItems`, `maxItems`, `uniqueItems`, `allOf`, `anyOf`, `oneOf`, `not`, and `if`/`then`/`else`.
- **Handled via embedded fallback:** `$ref`, `$dynamicRef`, `unevaluatedProperties`, `unevaluatedItems`, `patternProperties`, schema-valued `additionalProperties`, `prefixItems`, Draft 7 tuple `items`, `contains`, `dependentRequired`, `dependentSchemas`, `dependencies`, `propertyNames`, and `content*` assertions.

You can freely mix specialized keywords and fallback keywords in the same schema — the compiler specializes the static parts and falls back only where needed.

## Related guides

- [Loader and remote `$ref` handling](loader.md)
- [Content and format assertions](content_and_format.md)
- [Regex validation and execution limits](regex_validation.md)

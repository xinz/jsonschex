# Draft 7 test-suite failure report

The Draft 7 suite runs independently in `test/official_jsts_draft7_test.exs`. The initial run of `mix test test/official_jsts_draft7_test.exs` had **1,663 tests, 70 failures**. Both draft suites exclude only `optional/cross-draft`.

| Fixture | Initial failures | Cause |
| --- | ---: | --- |
| `items.json` | 16 | Tuple-form `items` arrays were passed to a compiler that expected one schema. |
| `additionalItems.json` | 13 | Tuple `items` and the corresponding `additionalItems` schema were not compiled together. |
| `uniqueItems.json` | 26 | Schemas combining `uniqueItems` with tuple `items` failed at compilation. |
| `ref.json` | 7 | Draft 7 `$ref` siblings, tuple items inside references, the HTTP Draft 7 meta-schema, and a same-resource URN pointer needed different handling. |
| `refRemote.json` | 3 | A remote Draft 7 meta-schema was unavailable, and pointer targets lost ancestor `$id` scopes. |
| `definitions.json` | 1 | The loader did not recognize `http://json-schema.org/draft-07/schema#`. |
| `optional/content.json` | 4 | Standalone content assertions were not enabled or enforced. |

## Fixes, in order

1. **Separate the suites.** Keep Draft 2020-12 in `test/official_jsts_test.exs`; run Draft 7 from `test/official_jsts_draft7_test.exs` with `draft: "draft7"`. This prevents duplicate generated ExUnit `describe` names and keeps the legacy behavior scoped to Draft 7.
2. **Enable optional content assertions.** The suite runner now opts in for `optional/content.json`. When `content_assertion: true`, content encoding and media type are checked even without `contentSchema`; the default remains annotation-only. The focused content run passed **10 tests, 0 failures**.
3. **Compile Draft 7 array and reference semantics.** Tuple `items` validates each position and applies `additionalItems` only after the tuple. Draft 7 `$ref` ignores sibling keywords (including `$id`), while Draft 2020-12 keeps sibling evaluation. The focused array run passed **116 tests, 0 failures**; the next full Draft 7 run had **6 failures**.
4. **Load the official Draft 7 meta-schema locally.** The test loader accepts the canonical HTTP URI and discards its fragment when looking up `priv/schemas/draft-07/schema.json`. This copy came from <https://json-schema.org/draft-07/schema>. The focused reference/definition run then had **3 failures**.
5. **Preserve reference scope.** Use a local pointer after normalizing an absolute reference to the current URN resource, and compile Draft 7 local pointer targets with the base URI inherited from ancestor `$id` declarations. The existing Draft 2020-12 initial-base behavior is preserved. The focused reference/definition run passed **103 tests, 0 failures**.
6. **Introduce explicit Draft 7 selection.** The Draft 7 compiler uses a separate keyword set rather than Draft 2020-12 vocabularies, and compiled references retain the selected draft when loading external schemas. At that stage, the canonical Draft 7 meta-schema was packaged at `priv/schemas/draft-07/schema.json`; built-in references resolve without a loader for both `http://json-schema.org/draft-07/schema` and the `#` form. At this stage, `draft: :draft7` was required even when `$schema` declared Draft 7. Focused compatibility, static-compilation, and official Draft 7 tests passed **7 doctests, 1,678 tests, 0 failures**.
7. **Select a recognized draft from root `$schema`.** `JSONSchex.compile/2` and `JSONSchex.Schema.compile!/2` now infer Draft 7 or Draft 2020-12 from a recognized root meta-schema URI. An explicit matching `:draft` works; a conflicting option returns `:draft_conflict` (or raises a compile error in `Schema.compile!/2`). If `$schema` is absent or custom, `:draft` selects the draft or Draft 2020-12 remains the default. For `compile_fragment/2`, detection uses the containing document's root. The official Draft 7 runner still passes `draft: "draft7"` for fixtures without `$schema`.

8. **Use string values for the public `:draft` option.** Pass `"draft7"` or `"draft2020_12"` to runtime and compile-time APIs. Atom values are rejected with `:invalid_draft`; compiled schemas store the same selected string, which is passed through when compiling referenced schemas. Existing callers passing atoms must switch to strings.

9. **Embed the canonical Draft 7 meta-schema.** `JSONSchex.Draft7.Schemas` now stores the fixed schema as an Elixir map, like Draft 2020-12. Runtime lookup and reference compilation do not read or decode the JSON fixture; the file remains in `priv` for official-suite tests and an equality regression test, but is no longer needed in the Hex package.

Validation through step 9: `mix test test/draft7_compatibility_test.exs test/official_jsts_draft7_test.exs` passed **1,674 tests, 0 failures**; `mix test` passed **22 doctests, 4,348 tests, 0 failures**. This measures the included fixture sets, not the excluded cross-draft scenarios or every possible Draft 7 schema.

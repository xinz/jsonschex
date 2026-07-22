# Changelog

## unreleased

### Bug Fixes and Improvements

  * Update `JSONSchex.bundle_fragment/2` to bundle only the schema graph reachable from the selected entrypoint, without loading unrelated refs from other components, examples, or extension data. Local pointers, anchors, nested `$id` resources, recursive graphs, and loader-provided base URIs remain supported; caller-owned `$defs` entries are preserved with collision-safe internal keys, while invalid `$defs` and ambiguous anchors return structured `invalid_defs` or `ambiguous_anchor` errors
  * Change `JSONSchex.Ref.resolve_selected/2` so an unselected `$ref` map is preserved but no longer terminates traversal: its sibling values are walked, `:select` is invoked for descendant `$ref` nodes that earlier releases skipped, and every descendant ref left unselected is rebased through loader-provided `:base_uri` and nested `$id` boundaries without loading its target
  * Some Dialyzer compile warnings fixed
  * Adapt the official `idn-email` format suite's lone UTF-16 surrogate case for Elixir JSON decoders and reject ill-formed UTF-8 input during `idn-email` validation
  * Reject signed years in the RFC 3339 `date` format, which requires exactly four unsigned year digits


## v0.8.1 (2026-06-15)

### Bug Fixes and Improvements

  * Preserve the loaded resource base for unselected nested `$ref`s inside external targets resolved by `JSONSchex.Ref.resolve_selected/2`, so later `JSONSchex.bundle_fragment/2` and `JSONSchex.compile_fragment/2` calls resolve those refs against their original document

## v0.8.0 (2026-06-07)

### Breaking Changes

  * Replace the separate `:entry_pointer` and `:entry_ref` options for `JSONSchex.compile_fragment/2`, `JSONSchex.bundle_fragment/2`, and `JSONSchex.Schema.compile_fragment!/2` with a single `:entry` option that accepts either a JSON Pointer or URI reference

## v0.7.0 (2026-05-23)

### Bug Fixes and Improvements

  * Add `JSONSchex.compile_fragment/2` and `JSONSchex.Schema.compile_fragment!/2` for compiling JSON Schema fragments while preserving the containing document as the local reference context, useful for OpenAPI 3.1 schemas under paths and components. Fragment entrypoints support exactly one of `:entry_pointer` or `:entry_ref`, with `:entry_ref` providing a base URI/path when `:base_uri` is omitted
  * Add `JSONSchex.bundle_fragment/2` for producing standalone raw schemas from document fragments, including reachable external resources mounted under `$defs`
  * Add `JSONSchex.Ref.resolve_selected/2` for selector-driven `$ref` resolution in JSON-like documents, allowing callers such as OpenAPI tooling to choose which `$ref` nodes are replaced while preserving unselected refs

### Breaking Changes

  * Rename the remote/reference loading option from `:external_loader` to `:loader`

## v0.6.0 (2026-05-09)

### Bug Fixes and Improvements

  * Add first-class support for compiling static JSON Schema literals during module compilation via `JSONSchex.Schema.compile!/2` and the `~X` sigil in `JSONSchex.Sigil`
  * Refactor validation and compiled rule execution to support static compile-time embedding by making rules data-driven and dispatching them through `JSONSchex.Validator.Rules`
  * Precompute legacy `dependencies` execution modes during compilation and simplify runtime rule matching
  * Prune several compile-time no-op keyword rules such as empty `required`, `properties`, `patternProperties`, `dependentRequired`, `dependentSchemas`, and `prefixItems`
  * Relax decimal dependency requirement

## v0.5.0 (2026-04-23)

### Bug Fixes and Improvements

  * Embed the Draft 2020-12 built-in meta-schema family directly in code and cache compiled built-in defs for `$ref` and `$dynamicRef` resolution
  * Refactor built-in Draft 2020-12 support into draft-specific modules: `JSONSchex.Draft202012.Schemas`, `JSONSchex.Draft202012.Vocabulary`, and `JSONSchex.Draft202012.Dialect`
  * Simplify and de-duplicate reference resolution logic, including URI fragment handling and loaded-schema validation flow
  * Fix built-in meta-schema validation so schemas can be validated against the canonical Draft 2020-12 meta-schema without an external loader
  * Update official test suite, and adapt to pass the official Draft 2020-12 optional format cases for `duration`, `time`, and `uri`:
    * Tighten `duration` format validation to match the RFC 3339 Appendix A grammar used by the official Draft 2020-12 optional format suite
    * Accept RFC 3339 `time` values with unknown local offset (`-00:00`)
    * Tighten `uri` and `uri-reference` format validation to reject invalid percent-encoding triplets

## v0.4.0 (2026-04-05)

### Bug Fixes and Improvements

  * Fixed an issue where $ref could cause an infinite loop during validation
  * Refactor compile-time and validation-time failures to use the unified `JSONSchex.Types.Error` model with structured `ErrorContext`
  * Improve error formatting so invalid keyword and compile errors produce clearer, more contextual messages
  * Treat the canonical Draft 2020-12 meta-schema as a built-in dialect without requiring a loader, while still honoring explicit `$vocabulary` declarations
  * Split vocabulary handling between supported vocabularies and the built-in Draft 2020-12 default active vocabulary set
  * Optimize local `$ref` compilation by batching JSON Pointer resolution for explicit local fragment references
  * Improve scope scanning so `$id`, anchors, and explicit local fragment refs are registered more consistently
  * Consolidate `time` format validation into the date-time format implementation

##  v0.3.0(2026-02-21)

### Bug Fixes and Improvements

  * Refactor the error context to make it more consistent

## v0.2.1 (2026-02-20)

### Bug Fixes and Improvements

  * Enhance some keywords validation.

## v0.2.0 (2026-02-20)

### Bug Fixes and Improvements

  * Enhance some keywords checking in compile.

## v0.1.0 (2026-02-16)

  * Initial Release

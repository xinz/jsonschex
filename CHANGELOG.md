# Changelog

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

# Changelog

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

# Draft 2020-12 Feature Matrix

This guide summarizes JSONSchex support for Draft 2020-12 keywords and vocabularies.

## Legend

- ✅ Supported
- ⚠️ Supported with notes (option-gated or annotation-only)
- ❌ Not supported

## Core / Applicators

| Keyword | Status | Notes |
|---|---|---|
| `$schema` | ✅ | Dialect resolution; loader required for remote meta-schema |
| `$id` | ✅ | Base URI scoping supported |
| `$ref` | ✅ | Supports remote refs with loader |
| `$anchor` | ✅ | Anchor resolution supported |
| `$dynamicRef` | ✅ | Dynamic scope lookup supported |
| `$dynamicAnchor` | ✅ | Supported via scope scanning |
| `$vocabulary` | ✅ | Vocabulary resolution supported |
| `$defs` | ✅ | Schema definitions supported |
| `$comment` | ✅ | Accepted (no validation impact) |
| `allOf` | ✅ |  |
| `anyOf` | ✅ |  |
| `oneOf` | ✅ |  |
| `not` | ✅ |  |
| `if` / `then` / `else` | ✅ |  |
| `dependentSchemas` | ✅ |  |
| `propertyNames` | ✅ |  |

## Validation keywords

| Keyword | Status | Notes |
|---|---|---|
| `type` | ✅ |  |
| `enum` | ✅ |  |
| `const` | ✅ |  |
| `multipleOf` | ✅ |  |
| `maximum` / `minimum` | ✅ |  |
| `exclusiveMaximum` / `exclusiveMinimum` | ✅ |  |
| `maxLength` / `minLength` | ✅ |  |
| `pattern` | ✅ |  |
| `maxItems` / `minItems` | ✅ |  |
| `uniqueItems` | ✅ | Preserves `==` semantics (`1` equals `1.0`) |
| `maxProperties` / `minProperties` | ✅ |  |
| `required` | ✅ |  |

## Array / Object Applicators

| Keyword | Status | Notes |
|---|---|---|
| `items` | ✅ |  |
| `prefixItems` | ✅ |  |
| `contains` | ✅ |  |
| `minContains` / `maxContains` | ✅ |  |
| `properties` | ✅ |  |
| `patternProperties` | ✅ |  |
| `additionalProperties` | ✅ |  |

## Unevaluated and Dependent

| Keyword | Status | Notes |
|---|---|---|
| `unevaluatedItems` | ✅ |  |
| `unevaluatedProperties` | ✅ |  |
| `dependentRequired` | ✅ |  |
| `dependencies` | ✅ | Pre-2019 compatibility; combines `dependentRequired` and `dependentSchemas` semantics |

## Content vocabulary

| Keyword | Status | Notes |
|---|---|---|
| `contentEncoding` | ⚠️ | Annotation-only by default; enabled via `content_assertion: true` |
| `contentMediaType` | ⚠️ | Annotation-only by default; enabled via `content_assertion: true` |
| `contentSchema` | ⚠️ | Annotation-only by default; enabled via `content_assertion: true` |

## Format vocabulary

| Keyword | Status | Notes |
|---|---|---|
| `format` | ⚠️ | Assertion behavior requires `format_assertion: true` |

## Notes

- When assertion options are not enabled, the corresponding keywords are accepted but do not enforce validation.
- For remote meta-schema resolution, provide an `external_loader` to `JSONSchex.compile/2`.

# Regex Validation Guide

This guide explains regex execution failures and error reporting for schema
patterns in Draft 7 and Draft 2020-12.

## Regex execution failures

Schema regexes used by `pattern`, `propertyNames`, and `patternProperties` are
subject to the Erlang regex engine's execution limits. If a match exhausts a
limit, JSONSchex stops validation and returns `{:error, [error]}` with
`error.rule == :indeterminate_pattern`, rather than treating it as a non-match.
This failure cannot be inverted by `not` or suppressed by other combinators.
The same protection applies when `additionalProperties` classifies keys against
`patternProperties`, including cached matches.

JSONSchex uses the engine's default execution limits. It does not retry matches
with input-dependent or automatically increased limits.

## Error details

The error's `path` identifies the affected instance, `value` and `context.input`
contain the string being matched (the property name for object-key matches), and
`context.error_detail` contains the engine reason, such as `:match_limit` or
`:match_limit_recursion`.

## Avoiding excessive backtracking

Even valid data is rejected if the engine cannot complete the match. Rewrite
patterns with excessive backtracking; for example, `^(?:(a+)+b|a+!)$` can be
replaced with `^a+[b!]$`.

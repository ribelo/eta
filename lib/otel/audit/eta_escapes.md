# Eta-Primitive-Escape Audit

Run: bash lib/otel/audit/run.sh
Last updated: 2026-06-28T09:12:16Z
Current sites: 0

## What Is NOT An Escape

The following Eio IO leaves are substrate, not Eta-primitive escapes:

- Eio.Net.*
- Eio.Flow.*
- Eio.Time.*
- Eio.Stdenv.*

Eta does not own IO leaves. Wrapping them in passthrough Eta types adds
ceremony without semantics.

## Discipline

Every site under the regex is named by the generated match list and classified
as Replaceable, Structural, or Debt. Zero production escapes is a valid state.
Non-zero test escapes are valid when the search scope includes tests and the
sites are classified.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/otel | rg -v 'Atomic\.Portable'

## Replaceable

No replaceable escapes in the audited package.

## Structural

No structural escapes in the audited package.

## Debt

No production debt escapes are present.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
<!-- END ESCAPE_MATCHES -->

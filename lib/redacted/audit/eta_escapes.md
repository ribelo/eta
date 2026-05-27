# Eta-Primitive-Escape Audit

Run: bash lib/redacted/audit/run.sh
Last updated: 2026-05-24T08:13:47Z
Current sites: 0

Sites where eta-redacted reaches into raw Eio fiber/switch/promise/mutex/condition
primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\\.Fiber\\.fork|Eio\\.Switch\\.run|Eio\\.Promise|Eio\\.Mutex|Eio\\.Condition|Atomic\\.[A-Za-z0-9_]+' lib/redacted

## Replaceable

No replaceable escapes yet.

## Structural

No structural escapes yet.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
<!-- END ESCAPE_MATCHES -->

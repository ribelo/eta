# Eta-Primitive-Escape Audit

Run: bash lib/ai/anthropic/audit/run.sh
Current sites: 0

Sites where eta-ai-anthropic reaches into raw Eio fiber/switch/promise/mutex/
condition primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/ai/anthropic

## Replaceable

No replaceable escapes yet.

## Structural

No structural escapes in the audited provider package. Eio-backed tests live
under top-level test directories and are outside this package audit.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
<!-- END ESCAPE_MATCHES -->

# Eta-Primitive-Escape Audit

Run: bash lib/ai/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 3

Sites where eta-ai reaches into raw Eio fiber/switch/promise/mutex/condition
primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/ai

## Replaceable

| Pattern | Sites | Replacement |
| --- | --- | --- |
| Eio.Switch.run in tests | test/test_eta_ai.ml | eta-test could expose a shared runtime fixture for Eta effect tests. |

## Structural

No structural escapes yet.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- test/ai/core/test_eta_ai.ml:319:  Eio.Switch.run @@ fun sw ->
- test/ai/core/test_eta_ai.ml:325:  Eio.Switch.run @@ fun sw ->
- test/ai/core/test_eta_ai.ml:335:  Eio.Switch.run @@ fun sw ->
<!-- END ESCAPE_MATCHES -->

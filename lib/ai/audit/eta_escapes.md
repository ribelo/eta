# Eta-Primitive-Escape Audit

Run: bash lib/ai/audit/run.sh
Last updated: 2026-06-15T22:49:45Z
Current sites: 4

Sites where eta-ai reaches into raw Eio fiber/switch/promise/mutex/condition
primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/ai

## Replaceable

No replaceable escapes yet.

## Structural

| Pattern | Sites | Why structural |
| --- | --- | --- |
| Atomic active flag | sse.ml | Enforces single-consumer access to an eta-ai stream while keeping the public API in Eta effects. |

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- lib/ai/sse.ml:12:  active : bool Atomic.t;
- lib/ai/sse.ml:29:    active = Atomic.make false;
- lib/ai/sse.ml:41:  if not (Atomic.compare_and_set stream.active false true) then
- lib/ai/sse.ml:46:         (Eta.Effect.sync (fun () -> Atomic.set stream.active false)))
<!-- END ESCAPE_MATCHES -->

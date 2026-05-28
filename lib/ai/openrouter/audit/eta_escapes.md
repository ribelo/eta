# Eta-Primitive-Escape Audit

Run: bash lib/ai/openrouter/audit/run.sh
Last updated: 2026-05-28T19:07:34Z
Current sites: 0

Sites where eta-ai-openrouter reaches into raw Eio fiber/switch/promise/
mutex/condition primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/ai/openrouter

## Replaceable

No replaceable escapes yet.

## Structural

- test/test_eta_ai_openrouter.ml uses Eio.Switch.run only to create Eta
  runtimes under Eio_main for effect tests. Production eta-ai-openrouter does
  not own Eio switches, fibers, promises, mutexes, conditions, or atomics.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
<!-- END ESCAPE_MATCHES -->

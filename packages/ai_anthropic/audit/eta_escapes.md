# Eta-Primitive-Escape Audit

Run: bash packages/eta-ai-anthropic/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 2

Sites where eta-ai-anthropic reaches into raw Eio fiber/switch/promise/mutex/
condition primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' packages/eta-ai-anthropic

## Replaceable

No replaceable escapes yet.

## Structural

- test/test_eta_ai_anthropic.ml uses Eio.Switch.run only to create Eta runtimes
  under Eio_main for effect tests. Production eta-ai-anthropic does not own Eio
  switches, fibers, promises, mutexes, conditions, or atomics.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:78:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:84:  Eio.Switch.run @@ fun sw ->
<!-- END ESCAPE_MATCHES -->

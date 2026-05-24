# Eta-Primitive-Escape Audit

Run: bash packages/eta-ai-openai/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 2

Sites where eta-ai-openai reaches into raw Eio fiber/switch/promise/mutex/
condition primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' packages/eta-ai-openai

## Replaceable

No replaceable escapes yet.

## Structural

- test/test_eta_ai_openai.ml uses Eio.Switch.run only to create Eta runtimes
  under Eio_main for effect tests. Production eta-ai-openai does not own Eio
  switches, fibers, promises, mutexes, conditions, or atomics.

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- packages/eta-ai-openai/test/test_eta_ai_openai.ml:77:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai-openai/test/test_eta_ai_openai.ml:83:  Eio.Switch.run @@ fun sw ->
<!-- END ESCAPE_MATCHES -->

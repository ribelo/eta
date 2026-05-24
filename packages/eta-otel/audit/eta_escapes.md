# Eta-Primitive-Escape Audit

Run: bash packages/eta-otel/audit/run.sh
Last updated: 2026-05-24T01:17:10Z
Current sites: 33

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
Non-zero test escapes are valid when classified.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' packages/eta-otel | rg -v 'Atomic\.Portable'

## Replaceable

| Pattern | Sites | Replacement |
| --- | --- | --- |
| Eio.Switch.run in tests | package test files | eta-test could grow a shared switch/net/clock fixture that covers eta-otel's live and loopback harnesses. |
| Eio.Promise in backpressure test | test/run.ml | eta-test could expose a small gate/latch helper. |

## Structural

| Pattern | Sites | Why it stays |
| --- | --- | --- |
| Eio.Fiber.fork_daemon | test/run.ml loopback servers | Local response servers are test infrastructure, not package runtime behavior. They need daemon fibers scoped to the test switch. |

## Debt

No production debt escapes are present.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- packages/eta-otel/test/test_logger.ml:18:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_logger.ml:29:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_logger.ml:90:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_logger.ml:106:    Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_logger.ml:119:    Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_tracer.ml:12:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_tracer.ml:23:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_tracer.ml:243:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_tracer.ml:263:    Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:37:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:88:  Eio.Fiber.fork_daemon ~sw (fun () ->
- packages/eta-otel/test/run.ml:91:             Eio.Switch.run @@ fun conn_sw ->
- packages/eta-otel/test/run.ml:115:      Eio.Fiber.fork_daemon ~sw (fun () ->
- packages/eta-otel/test/run.ml:118:               Eio.Switch.run @@ fun conn_sw ->
- packages/eta-otel/test/run.ml:140:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:187:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:223:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:242:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:263:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:292:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:319:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:340:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:341:  let gate, release = Eio.Promise.create () in
- packages/eta-otel/test/run.ml:351:      ~on_send:(fun ~path:_ ~body:_ -> Eio.Promise.await gate)
- packages/eta-otel/test/run.ml:361:  Eio.Promise.resolve release ();
- packages/eta-otel/test/run.ml:367:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:392:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:422:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:464:    Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/run.ml:472:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_metrics.ml:21:  Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_metrics.ml:143:    Eio.Switch.run @@ fun sw ->
- packages/eta-otel/test/test_metrics.ml:156:    Eio.Switch.run @@ fun sw ->
<!-- END ESCAPE_MATCHES -->

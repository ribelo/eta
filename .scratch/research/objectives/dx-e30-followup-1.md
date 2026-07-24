# Follow-up 1: DX-E30 — rework after review (verdict: not promotable as-is)

Your evidence packaging was strong. The independent review found one real
semantic defect, one vacuous test, and two contract/documentation
violations. All are local and fixable; the design itself stands. Everything
in `objective.md` still applies.

## R1 (blocking) — `on_reject` must not run in host context

Current code evaluates `on_reject reason` **inside the JS rejection
callback** (`eta_js.ml`, `on_rejected`). If the mapper raises, the
exception escapes through `Js.wrap_callback` into the JS engine: `resume`
is never called, the Eta effect stays pending forever, and the `.then`
child promise rejects (unhandledRejection). Your report's "no hang, no
unhandled rejection" claim holds only for non-raising mappers — and
decoding mappers raise all the time (non-exhaustive matches, failed
parsers).

Fix (this construction, or one you can argue is strictly better):

```ocaml
let from_js_promise ?on_cancel ~on_reject promise =
  Effect.async ~register:(fun resume ->
      (* non-thenable check unchanged *)
      (* on_fulfilled: resume (Exit.Ok (`Fulfilled value))
         on_rejected:  resume (Exit.Ok (`Rejected reason))  — RAW settlement,
         no user code inside the callback *))
  |> Effect.bind (function
       | `Fulfilled value -> Effect.pure value
       | `Rejected reason ->
           Effect.sync (fun () -> on_reject reason)
           |> Effect.bind Effect.fail)
```

Properties this buys, each of which must get a named test:
- a raising mapper becomes `Cause.Die` via the ordinary capture path
  (`Effect.sync`) — Eta's culture, matching E25's `error_pp` rule;
- the mapper NEVER runs after interruption (the continuation is dropped) —
  make "detached" honest: no user code executes after detach;
- `resume` is always called with raw settlement — no hang, no unhandled
  child rejection;
- the variant tags are internal-only; the public signature is unchanged.

## R2 (blocking) — the "reject after detach" test never rejects

`deferred_promise` ignores `_on_reject`; the handle bound as `js_reject` is
the *fulfiller*; the test fulfills with `unit`. The scenario never happens,
the `unhandledRejection` sentinel never saw it, and `report.md` /
`VERDICTS.md` overstate the evidence. Fix the helper to expose a real
reject handle, make the test actually reject after detach, and correct the
overstated claims **as new dated sections** in report/journal (append-only;
mark the earlier claim wrong explicitly — that honesty is the protocol).

## R3 (required) — coverage gaps the review found

- Add: pending promise that settles successfully AFTER registration
  (current `resolve` and `already_settled` are both pre-fulfilled —
  duplicates; the common real-world shape is untested).
- Add: raising `on_reject` → `Cause.Die`, no hang, no unhandledRejection
  (the sentinel arms this — that is what sentinels are for).
- Add: after interruption, a late rejection does NOT run the mapper
  (side-effect counter stays 0).

## R4 (required) — contract wording in `eta_js.mli`

- "the host computation keeps running" is false for `?on_cancel` consumers
  (`start_fetch` aborts the fetch). Say precisely: Eta never cancels the
  host computation and handlers stay attached until settlement;
  `?on_cancel` *may* stop it (that is its purpose).
- State that the success type is caller-asserted (the value crosses an
  `Unsafe` boundary unchecked).

## R5 (required) — law registry

AGENTS.md (post-E22): adding law-bearing mli prose requires its named test
**and a registry row in the same change**. Your new mli claims (first
settlement wins; `?on_cancel` at most once; detachment) have no row in
`.scratch/research/dx/e22/review/LAWS.md`. Add them, pointing at the named
tests above.

## R6 (required) — the hand-rolled consumer

`docs/api-dx.md` says don't hand-roll this adapter, but
`lib/http_js/eta_http_js.ml` `start_fetch` still does. Determine whether
package layering forbids `eta_http_js` → `eta_js` (check the dune
dependency graph) and either migrate it onto `from_js_promise` (preferred
if legal — the sole motivating consumer validates the adapter) or document
the layering reason in `docs/api-dx.md` next to the recipe. No scope creep
beyond this one consumer.

## Protocol

Append a new journal section (sealed micro-predictions for R1–R6 fixes),
then implement, re-run all five gates (native trio + both mainline
commands), update `report.md` with a rework section scoring the review
findings, and end with the usual signal: `E30 READY FOR REVIEW` /
`E30 BLOCKED: <reason>`. Same scope fence. This file stays uncommitted.

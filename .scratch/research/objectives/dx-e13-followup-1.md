# Follow-up 1: DX-E13 — three findings from independent correctness review

Your `Effect.async` survived the hunt: no state-machine race, no cancellation
duplication, no lost wakeup, both backends linearize correctly. The
independent review verdict is CORRECT-WITH-RESERVATIONS with three findings.
Fix all three in this worktree, re-run all gates, update journal + report.
The public contract (signature + six guarantees) stands; these are one
runtime fix and two honesty fixes.

## Finding 1 (MEDIUM, must fix): jsoo cancellation-retention leak

`lib/jsoo/eta_jsoo.ml` (~177–223): when interruption wins, the CPS `Await`
callback remains in the promise's `Pending callbacks` list. Cancellation
marks the local `resumed` flag but never unsubscribes. Because
`Effect.async` then moves to `Async_interrupt_claimed`, every late `resume`
is dropped before `resolve_promise` — so the private promise can never
settle and clear its callbacks. Host code that legitimately retains
`resume` after cancellation (the contract documents late calls as
harmless) roots the promise, the canceled CPS continuation closure, the
fiber, and its locals indefinitely.

Fix direction (yours to design, contract unchanged): make jsoo promise
subscriptions removable/clearable on cancellation, or otherwise
settle/clear the private promise when interruption claims it. Prove it:
an executable check that after interruption wins, the promise no longer
retains the canceled subscription (observable state, not prose). Also
verify the non-async awaiters (e.g. `Effect.never`, `Eta.Promise`-adjacent
paths if any) get the same hygiene or document why they're unaffected.

## Finding 2 (LOW, mli): registration is cancellation-protected too

`lib/eta/effect.mli`, `val async` doc: `register resume` runs under
`Runtime_contract.protect` until it returns — a blocking/nonterminating
registration cannot be interrupted and never yields the canceler. The doc
currently warns only that the *canceler* must terminate. Add one sentence:
registration is cancellation-protected until it returns and therefore must
return promptly. (You already say this in `docs/api-dx.md`; the mli must
say it too.)

## Finding 3 (LOW, tests): evidence naming must not overclaim

`test/core_common/effect_async_shared.ml` (+ native suites):
- The "second interrupt" test re-fires the same one-shot cancellation
  context (idempotent second call) — it proves the protected canceler
  survives the already-pending cancellation across yields, not a distinct
  second interruption. Rename/redescribe accurately, OR add a genuinely
  distinct second-interruption source if the runtime offers one.
- The seeded "register/cancel races" are deterministic same-domain
  orderings — keep them, but describe them as that, not as race stress.
- The native 32-trial test races callback-vs-callback; say so. If a
  callback-vs-cancellation cross-domain trial is expressible, add it; if
  not, document why (mechanism constraint), as you did for jsoo seeding.

## Gates (full re-run after fixes)

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/cache_jsoo test/signal_jsoo --force
```

## Records

Journal: new entry (append-only) covering the three findings and your fix
mechanism for Finding 1, with the observable proof. Report: update the
guarantee table and verdicts. Red-team: the retention leak is now attack
(d) — show the before/after.

## Done means

`E13 READY FOR REVIEW` (rework complete) / `E13 BLOCKED: <reason>` /
`E13 STOP: <§4.6>`. Same scope fence. This file stays uncommitted.

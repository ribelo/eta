# Objective: DX-E14 — `Eta.Promise`: a backend-neutral one-shot cell

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e14`
- Branch: `research/dx-e14-eta-promise` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort M · Risk med
- Entry gate: **met** — E13 (`Effect.async`) promoted; the second-substrate pull exists
- Evidence IDs: `V-DX-E14-*` (orchestrator log); your journal is the branch record

## Executor profile

A small public module with exacting cancellation semantics, built over
machinery E13 hardened. The substrate work exists (`Runtime_contract`
promise primitives with specified cross-domain and cancellation contracts;
jsoo removable subscriptions from the E13 retention fix). Your difficulty:
getting the Eta-level semantics exactly right (one-shot, cancellation-safe
`await`, scope-close interruption), stating the edges honestly, and proving
them on both backends with shared tests. Less design invention than E13,
more precision.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Coordinating
two fibers with a one-shot result should need zero knowledge of which
backend is underneath — and should be impossible to misuse silently.

## Read first (in order)

1. `AGENTS.md` — especially H-W4 (the wrap rule: portability fences are a
   reason to wrap; this module IS that rule applied).
2. The E14 one-pager below — the contract.
3. `lib/eta/runtime_contract.mli` — the promise primitives and their
   documented semantics (read the full contract text around
   `create_promise`/`resolve_promise`/`await_promise`; the cancellation
   guarantees are already specified there).
4. `lib/jsoo/eta_jsoo.ml` — the promise implementation with E13's removable
   subscriptions (`subscription_active`, `unsubscribe`,
   `pending_subscriptions`).
5. `.scratch/research/dx/e13/report.md` — the sibling experiment's verdicts
   (mechanism vocabulary, jsoo discipline).
6. `lib/test/eta_test.mli` (`module Async`) and the `README.md`
   Eio-primitives table — the two leakage points you will address.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Working artifacts in `.scratch/research/dx/e14/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E14)

**Problem.** Docs direct users to `Eio.Promise` — pinning application code
to the native substrate, and the choice has already leaked into the public
test API (`Eta_test.Async` re-exports `Eio.Promise.t`). Eta's own wrap rule
(H-W4) lists *portability fences* as a reason to wrap; the trigger is a
second backend needing a one-shot cell — E13 and real jsoo programs.

**Proposal.**

```ocaml
module Eta.Promise : sig
  type ('a, 'err) t
  val create  : unit -> ('a, 'err) t
  val await   : ('a, 'err) t -> ('a, 'err) Effect.t
  val resolve : ('a, 'err) t -> ('a, 'err) Exit.t -> (bool, 'outer) Effect.t
end
```

**Guarantees (mli + executable tests, both backends):**

1. **One-shot.** First resolution wins; `resolve` returns `true` once,
   then `false`.
2. **`await` is cancellation-safe.** A cancelled waiter is removed and
   never consumes the resolution; remaining waiters still wake.
3. **N awaiters wake.** Multiple fibers awaiting the same promise all
   receive the resolution.
4. **Scope/boundary close interrupts remaining awaiters.** State the
   mechanism (the ordinary scope/cancellation path) and test it.
5. **Parity on both backends.** Same semantics native and jsoo — one
   contract, no polyfills, host capabilities checked loudly (ADR 0001).

`Eio.Promise` remains right for Eio-only code — this is a fence, not a
takeover (documented, same posture as the Eio-primitives table).

**Gates from the one-pager.** Promote: E13 or a jsoo example consumes it
(E13 promoted — gate met; the review packet demonstrates the consumption).
Kill if the two backends cannot share cancel-and-close semantics.

## Protocol (predictions commit FIRST and separately)

1. **Seal your predictions** in `.scratch/research/dx/e14/journal.md`:
   mechanism per guarantee per substrate, edges (resolve-after-close,
   resolve racing cancel), expected review ratings, census/footgun deltas.
   Commit before any code change (`docs(dx-e14): seal predictions`).
2. **Docs-first.** The `.mli` for the module before implementation —
   guarantees and edges in ≤ ~15 lines. The doc budget is a design smell
   detector.
3. **Implement** the smallest wrapper over the contract promise
   (Expert-free: this is a public module in `lib/eta`, built on the same
   runtime-contract primitives `async` uses, not on `Expert.make`).
4. **Gates** (from the worktree):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline @install
   nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/cache_jsoo test/signal_jsoo --force
   ```
   `_build-mainline` for all mainline invocations. Fix-forward up to three
   attempts per failure class, then BLOCKED.
5. **Guarantee tests** (shared suite, both backends): one-shot (repeat
   resolve → `false`, first exit preserved); N awaiters wake (≥3);
   cancelled waiter does not consume (cancel one of two waiters; the other
   still receives; later `await` after resolution succeeds immediately);
   boundary close interrupts awaiters; resolve-after-close edge per your
   stated semantics; `Exit.Error` resolutions deliver typed failures and
   defects faithfully.
6. **Mechanical extras.**
   - Census: concurrency cluster before/after (expect +1 module, 3 vals).
     Footguns: expect +0 with documented edges.
   - `README.md` Eio-primitives table: the one-shot row moves to
     `Eta.Promise` with the fence sentence.
   - `docs/api-dx.md`: when to use `Eta.Promise` vs `Effect.async` vs
     `Eio.Promise` — the decision rule.
   - **`Eta_test.Async` decision**: assess migrating it off `Eio.Promise.t`
     (the leak the one-pager names). Migrate if compatible with the jsoo
     test track; if not, document why with evidence (eta_test's native
     flavor may make hold the honest answer). Either way the journal
     records the decision and reasoning.
7. **Red-team pass** (committed under `redteam/` with verdicts):
   (a) cancel a waiter then resolve — prove the cancelled waiter didn't
   consume and a later `await` still succeeds; (b) resolve twice with
   conflicting exits — second is `false`, first preserved; (c) leak a
   waiter by abandoning a fiber — state what the scope boundary does about
   it (and whether jsoo retention hygiene from E13 covers it).
8. **Review packet** in `review/`, labeled: `coord-old.ml` (coordinate two
   fibers in the jsoo track today via `Expert.make` — the current path)
   vs. `coord-new.ml` (same coordination via `Eta.Promise`), 10–30 lines
   each, plus `MANIFEST.md` and `QUESTIONS.md` ("what happens to a
   cancelled waiter?", "who can resolve?", "what does the second resolve
   return?").
9. **Report** in `report.md`: gates summary, guarantees with test names
   per backend, mechanism description, census/footgun actuals vs. sealed
   predictions, red-team outcomes, `Eta_test.Async` decision, deviations,
   promote/hold/kill recommendation.

## Done means

Your final message ends with exactly one of:

- `E14 READY FOR REVIEW`
- `E14 BLOCKED: <reason>`
- `E14 STOP: <§4.6 stop condition>`

The orchestrator verifies (diff, focused tests, evidence audit), runs the
independent correctness review, and decides. Rework via follow-up messages.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E14 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Do NOT migrate native test files off `Eio.Promise` (they are
  native-only; the fence is about *application portability*, not
  eradication). The only migration candidates are the README row and
  `Eta_test.Async` (item 6).
- Stay in E14's surface. Adjacent discoveries → journal follow-ups.
- Everything under `.scratch/research/dx/e14/` must be committed;
  `objective.md` stays uncommitted.

# Objective: DX-E13 — `Effect.async`: the missing algebra leaf

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e13`
- Branch: `research/dx-e13-effect-async` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort M–L · Risk med (two-substrate semantics)
- Evidence IDs: `V-DX-E13-*` (orchestrator log); your journal is the branch record

## Executor profile

The semantics experiment of Phase D: a new core algebra leaf with a
two-substrate contract (native Eio + js_of_ocaml CPS). The difficulty is
cancellation/wakeup reasoning — one-shot resolution, uninterruptible
cancelers, no lost wakeup between registration and parking — and proving
each guarantee with executable tests on BOTH backends. You must read the
runtime internals (`Runtime_contract`, `cancel_sub`, the signal timer's
`run_cancellable` pattern) and the jsoo scheduler (`lib/jsoo/eta_jsoo.ml`).
Not a rename, not a migration: a designed leaf with laws. Strong
concurrency-semantics reasoning and property-test design required.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Wrapping an
event emitter, a host timer, a JS `Promise`, or a C callback should be one
obvious word — not a drop into the runtime-package escape hatch.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, no shims, delete old paths, break loudly.
2. The E13 one-pager below — it is the contract.
3. `lib/eta/effect.mli` — the `Expert` module (what `async` frees
   application code from touching) and the core leaf shapes.
4. `lib/signal/eta_signal_timer.ml` `run_cancellable` — the existing
   runtime-internal pattern for cancellation-aware registration
   (`Runtime_contract.cancel_sub`).
5. `lib/jsoo/eta_jsoo.ml` + `eta_jsoo.mli` — the CPS scheduler you must
   honor; ADR 0001 (`docs/adrs/`) for the jsoo discipline (host
   capabilities checked loudly, never polyfilled).
6. `lib/eta/runtime_contract.mli` — parking/resumption/cancel hooks the
   native side will build on.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
This IS a design experiment (unlike the renames): the one-pager fixes the
signature and the six guarantees; HOW each guarantee is achieved on each
substrate is yours to design and prove. Proof obligations: every guarantee
below has an executable test on both backends, or the guarantee does not
exist.

Working artifacts in `.scratch/research/dx/e13/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E13)

**Problem.** No constructor exists for callback-shaped effects. Wrapping an
event emitter, a host timer, a JS `Promise`, or a C callback means dropping
to `Expert.make` — a runtime-package escape hatch — for application-level
work. ZIO has `effectAsync`; polysemy ships `Async`; the js_of_ocaml track
lives on callbacks.

**Proposal.**

```ocaml
val async :
  register:((('a, 'err) Exit.t -> unit) -> (unit, 'err) t option) ->
  ('a, 'err) t
```

**The six guarantees (all must be specified in the mli and tested on both
backends):**

1. **One-shot resolution.** First `Exit.t` wins; later calls dropped,
   documented.
2. **Canceler.** The optional effect returned by `register` is the
   canceler: run at most once, uninterruptibly, on interruption only,
   never after a resolution.
3. **`register` raising → `Cause.Die`** via the ordinary capture path.
4. **Synchronous resolution during registration must not deadlock.**
5. **No lost wakeup** between registration and parking — specify the
   mechanism (e.g. queued resume) and test it.
6. **jsoo (T10):** maps naturally onto the CPS-based JS runtime; host
   capabilities checked loudly, never polyfilled (ADR 0001 discipline).

**Gates from the one-pager.** Promote only if BOTH substrates implement the
full contract; otherwise hold with the divergence recorded — a core
primitive with two meanings is worse than none (T10). Kill if the
lost-wakeup guarantee cannot be stated and tested cleanly on either
backend.

## Protocol (predictions commit FIRST and separately)

1. **Seal your predictions** in `.scratch/research/dx/e13/journal.md`:
   your chosen mechanism per guarantee per substrate, expected review
   ratings, census/footgun deltas. Commit before any code change
   (`docs(dx-e13): seal predictions`). Never edit afterward.
2. **Docs-first.** The `.mli` contract for `async` before implementation —
   all six guarantees stated in ≤ ~15 lines; if the canceler contract
   needs more, that is a design smell, note it.
3. **Implement** native first, then jsoo, smallest change satisfying the
   contract. `async` must NOT touch or weaken `Expert.make` (it serves
   runtime packages; different job).
4. **Gates** (from the worktree):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   JS track (this experiment lives on both substrates):
   ```sh
   nix develop .#mainline -c dune build --build-dir=_build-mainline @install
   nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo test/cache_jsoo --force
   ```
   Use `_build-mainline` for ALL mainline invocations (mixed-track `_build`
   poisoning is a known hazard; the dir is gitignored). `test/signal_jsoo`
   was fixed in F1 and must stay green. Fix-forward up to three attempts
   per failure class, then BLOCKED.
5. **Guarantee tests (the heart).** In the shared core suites (compiled
   per-backend): one-shot resolve; canceler-runs-on-interrupt;
   canceler-uninterruptible (a second interrupt during the canceler does
   not preempt it); canceler-never-after-resolution; register-raises →
   `Die`; sync-resolve-during-registration no-deadlock; no-lost-wakeup
   under cancel racing registration (seeded interleavings where the
   runtime allows; document the mechanism if full seeding is impossible).
6. **Mechanical extras.**
   - Census: construct cluster before/after (expect +1); Expert surface
     unchanged. Footgun delta: expect +0, state the documented edges
     (one-shot resume; canceler must not block indefinitely).
   - `docs/api-dx.md`: the async-leaf section (when to use `async` vs.
     `Expert.make` — the decision rule is the DX payload).
7. **Red-team pass** (committed under `redteam/` with verdicts):
   (a) double-resolve — second `Exit.t` must be dropped, visibly;
   (b) lose a wakeup on purpose (resume-then-park race) — the mechanism
   must refuse; (c) a canceler that itself blocks indefinitely — document
   the trap and the contract's answer.
8. **Review packet** in `review/`, labeled: `js-old.ml` (wrap a JS
   `addEventListener` via `Expert.make` — the current path) vs. `js-new.ml`
   (same wrap via `async`), 10–30 lines each, plus `MANIFEST.md` and
   `QUESTIONS.md` (teach-back: "when does the canceler run? how many times?
   can it run after a resolution?").
9. **Report** in `report.md`: gates summary, the six guarantees with their
   test names per backend, mechanism description (queued resume or
   whatever you chose), census/footgun actuals vs. sealed predictions,
   red-team outcomes, deviations, promote/hold/kill recommendation against
   the one-pager's both-substrates gate.

## Done means

Your final message ends with exactly one of:

- `E13 READY FOR REVIEW`
- `E13 BLOCKED: <reason>`
- `E13 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E13 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Do NOT migrate `Expert.make` call sites (runtime-package shapes, not
  application callbacks) — if you find one that IS an application-level
  callback wrap, note it in the journal as a candidate for a follow-up
  migration experiment; do not touch it here.
- Stay in E13's surface. Adjacent discoveries → journal follow-ups.
- Everything under `.scratch/research/dx/e13/` must be committed;
  `objective.md` stays uncommitted.

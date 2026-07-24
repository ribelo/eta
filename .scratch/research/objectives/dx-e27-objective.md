# Objective: DX-E27 — `Effect.logf`: deferred-format logging

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e27`
- Branch: `research/dx-e27-logf` (already checked out here; do not create others)
- Phase: E (queued candidates) · Effort S · Risk low · **feature human pre-approved** — the experiment is about doing it sensibly, not whether
- Evidence IDs: `V-DX-E27-*` (orchestrator log); your journal is the branch record

## Executor profile

A small, precise addition with one semantic heart: the format must not
run when the level is disabled. Your work: the exact format4 encoding
(settled with the compiler), the gate placement (inside the existing
level check in `effect_observability.ml`), a MEASURED allocation claim,
and the honest mli (including the eager-args rule). Care with format4
typing; discipline with the measurement; no scope creep.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Logging
should cost nothing when it's off — and read like OCaml when it's on.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates. **E22 policy: the deferred semantics
   is law-bearing prose → named tests.**
2. `lib/eta/effect_observability.ml` — `log`'s implementation: the level
   gate already guards all record construction. Your branch point is
   inside it.
3. `lib/eta/effect.mli` — `log`'s current contract; the pipeline order
   (min-level filter → attrs → intercepts → sink) documented with E20.
4. Logs' `msgf`/`m` (in the opam switch or Nix store) — the format4
   idiom being mirrored (T11).
5. `.scratch/research/dx/e20/report.md` — the intercept transform model
   your records flow through.

## The contract

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  <format4 encoding settled with the compiler> ->
  (unit, 'err) t
```

**Use-site (this is what review judges):**

```ocaml
Effect.logf "db.find %d" id
Effect.logf ~level:Debug ~attrs:[ "table", "users" ] "retrying in %d ms" ms
```

Reads exactly like Logs' `m`. The exact format4 type encoding is yours
to settle with the compiler (Logs' `msgf` and `Format`'s `kf*` family
are the references); the use-site shape is the contract.

## Semantics (the heart)

1. **Deferred formatting.** The format is evaluated ONLY when the
   effect runs AND the level passes `logging_enabled` and the current
   minimum. Disabled: the formatter is not invoked. This is a law —
   instrument it (a formatter that records invocation) and measure it.
2. **The allocation claim is a number.** `logf` at a disabled level
   allocates ~nothing beyond the blueprint; at an enabled level it
   allocates the string + record once. Prove with a minor-words
   comparison on the watchlist (E20's discipline: cost claims are
   measured).
3. **Eager-args honesty (one mli sentence).** Arguments are ordinary
   OCaml arguments: `logf "len %d" (Queue.length q)` evaluates
   `Queue.length q` EAGERLY at construction. Only the FORMATTING is
   deferred. (Logs has the same rule.)
4. **Composition.** The formed record flows through the normal pipeline:
   scoped attrs prepended → intercept transforms → sink. An intercept
   `Drop` may still drop the record AFTER the format ran — document
   this (matches Logs' report-processor order).
5. **A raising `%a` printer** becomes a defect via the ordinary capture
   path (same rule as `error_pp`).

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e27/journal.md`
   (commit `docs(dx-e27): seal predictions` FIRST): the encoding you'll
   use, the gate placement, the measured allocation expectation, census/
   footgun deltas.
2. **Docs-first**: the `.mli` contract (≤ ~10 lines incl. the eager-args
   sentence) before implementation.
3. Implement the smallest change: `logf` in effect_observability + the
   mli. `log` stays (pre-built strings).
4. **Gates**:
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline @install
   nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
   ```
5. **Tests** (named, E22-registered): disabled level does not invoke the
   formatter; enabled formats exactly once; record composition through
   attrs + intercepts; Drop-after-format documented behavior; raising
   printer → defect; eager-args documented example.
6. **Measurement**: minor-words disabled vs. enabled on the watchlist
   (`bench/runtime_watchlist/` or the established measurement pattern).
7. **Red-team**: try to make the disabled path allocate (a formatter
   that would blow up if invoked — it must never run); try to double-
   format; try to make an intercept bypass the level gate.
8. **Review packet** in `.scratch/research/dx/e27/review/`: `log-old.ml`
   (log + sprintf) vs `log-new.ml` (logf) on 2–3 real-shaped call sites;
   `QUESTIONS.md` ("when does the format run? what about the args?").
9. **Report**: gates, the measured numbers, encoding choice, census/
   footgun actuals vs. predictions, red-team, promote recommendation.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/`, `.scratch/research/dx-prd-0001.md` beyond §E27's
  parking-lot note, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- NO `eventf`, no logger-capability changes, no intercept changes.
  `logf` is one val + its docs/tests/measurement. If you find the
  format4 encoding fights the effect-returning shape, stop and report
  the options rather than inventing a new shape class.
- Everything under `.scratch/research/dx/e27/` must be committed;
  `objective.md` stays uncommitted.

## Done means

- `E27 READY FOR REVIEW` / `E27 BLOCKED: <reason>` / `E27 STOP: <§4.6>`

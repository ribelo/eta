# Objective: DX-E24d — Retry cause-alignment (semantic decision + implementation)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24d`
- Branch: `research/dx-e24d-retry-cause-alignment` (already checked out here; do not create others)
- Phase: E · Effort S · Risk low-med (a real semantic behavior change in one combinator)
- Registered: V-DX-E24-003 (E24 oracle consultation); E22 debt row CD-E22-006
- Evidence IDs: `V-DX-E24D-*` (orchestrator log); your journal is the branch record

## Executor profile

A small, precise semantic decision with an implementation tail. The
question is decided by evidence, not assumed: is the `retry`/
`retry_or_else` cause-handling divergence accidental, and does alignment
break anything? Then one careful change to `retry`'s cause matching, mli
prose, properties, and the debt ledger. Requires comfort with `Cause.t`
machinery and honesty about behavioral blast radius. S effort; the care
is in the edges (terminal-cause preservation, uncatchable composites).

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Two
combinators named `retry*` must not have two silent ideas of what a
retryable failure is.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, break loudly. **E22 policy: prose
   changes come with named tests.**
2. `lib/eta/effect_schedule.ml` — `retry` (matches bare `Cause.Fail`
   only) vs. `retry_or_else` (`stripped_uncatchable` →
   `first_typed_failure`).
3. `lib/eta/effect.mli` — the "Current limitation" paragraph on `retry`
   (E24's documentation of the divergence) and the `retry_or_else`
   contract.
4. `lib/eta/cause.mli` (+ the `stripped_uncatchable` /
   `first_typed_failure` helpers) — the shared catchability boundary
   used by `bind_error`/`catch_some`.
5. `.scratch/research/dx/e24/journal.md` — the consultation that
   registered this decision.
6. `.scratch/research/dx/e22/review/LAWS.md` — row CD-E22-006 (the debt
   this resolves or splits) and R82 (`retry_or_else`'s composite
   registration).

## The question (decide with evidence, then implement)

1. **Is the divergence accidental?** Check history (`git log -p
   --follow lib/eta/effect_schedule.ml` and the shared catchability
   helpers' origin). Record what you find — intentional or accidental,
   with the commit evidence.
2. **Should `retry` adopt the shared boundary?** The expected verdict is
   yes: retry composites whose primary tree has typed failures and no
   uncatchable diagnostics, predicate + schedule input = first typed
   failure in cause order. If you find a reason the divergence is load-
   bearing, that is a HOLD outcome with the reason recorded — do not
   force alignment.
3. **Terminal-cause semantics (the real decision point).** When the
   predicate rejects or the schedule exhausts on a composite, aligned
   `retry` returns: (a) the original composite cause, or (b) the first
   `Fail` collapsed. Predicted (orchestrator): (a) — preserving all
   failures, matching `catch_some`'s preserve-exactly ethos. Verify (a)
   is coherent with `retry_or_else`'s behavior on the same paths and
   decide with the evidence.

## Implementation (if alignment lands)

1. `retry`'s cause matching adopts `stripped_uncatchable` +
   `first_typed_failure` (share the helpers; do not duplicate the
   boundary logic).
2. mli: the "Current limitation" paragraph is replaced by the shared
   boundary statement (same catchability as `bind_error`/
   `retry_or_else`; terminal preservation per item 3).
3. Tests in `test/core_common/effect_retry_repeat_common_suites.ml`:
   composite retried (predicate sees first typed failure; schedule gets
   it too); composite carrying a defect / interruption / finalizer
   diagnostic NOT retried (uncatchable preserved); terminal rejection
   preserves the original composite cause; exhaustion on composite
   preserves it; existing bare-Fail cases unchanged.
4. E22: register the new named tests; close or split CD-E22-006 (its
   second half — "`retry_or_else` current-runtime failure paths" — is
   separate; assess and either cover or leave with a narrower row).
5. `CHANGELOG.md`: the semantic behavior change, one entry (idiom-pass
   style: what changes, who notices, why).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
```

## Red-team (committed under `.scratch/research/dx/e24d/redteam/`)

- (a) A composite with a buried defect: prove it is NOT retried (the
  shared boundary refuses) and the defect surfaces.
- (b) A composite of two typed failures with a rejecting predicate:
  prove the ORIGINAL cause (both failures) is preserved at terminal,
  not collapsed.
- (c) History check (item 1) falsified? — if you claimed "accidental",
  show you searched for an intentional reason and report what you found
  either way.

## Review packet (`.scratch/research/dx/e24d/review/`)

- `before-after.md`: the behavior matrix (cause shape × old × new) —
  the whole change on one page.
- `QUESTIONS.md`: "does `retry` now refuse a composite with a defect?"
  "what cause does terminal exhaustion return?"

## Report

`report.md`: the intentionality finding, verdict, terminal-cause
decision, blast-radius census (which existing tests/suites could see
behavior change and why they still pass), E22 registration, prediction
scoring, promote/hold recommendation.

## Protocol

Predictions sealed FIRST in `.scratch/research/dx/e24d/journal.md`
(commit `docs(dx-e24d): seal predictions` before any code). Journal +
report committed on the branch. `objective.md` stays uncommitted.

## Done means

- `E24D READY FOR REVIEW` / `E24D BLOCKED: <reason>` / `E24D STOP: <§4.6>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/`, `.scratch/research/dx-prd-0001.md` beyond the E24
  context, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches.
- One combinator's cause matching + its docs/tests/ledger. No other
  refactors. If alignment exposes a deeper cause-model issue, note it
  as a follow-up, do not expand scope.

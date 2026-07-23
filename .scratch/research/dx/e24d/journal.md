# DX-E24d Journal — Retry cause alignment

Branch: `research/dx-e24d-retry-cause-alignment`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24d`

## Predictions (sealed)

Sealed before production code, public prose, tests, or ledger edits. Wrong
predictions remain as evidence and will be scored in the final report.

1. **Intentionality.** History will show that bare-`Cause.Fail` matching in
   `retry` predates the shared `stripped_uncatchable` / `first_typed_failure`
   boundary, while `retry_or_else` adopted that boundary later without an
   explicit rationale for keeping `retry` narrower. Predicted verdict:
   accidental divergence.
2. **Alignment.** `retry` should use the shared boundary: a composite primary
   tree containing typed failures and no defect, interruption, or finalizer
   diagnostic is retryable, and the predicate and schedule see the first typed
   failure in cause order.
3. **Uncatchable composites.** A composite containing any uncatchable
   diagnostic will not invoke the predicate or schedule and will preserve the
   original cause unchanged.
4. **Terminal causes.** Predicate rejection and schedule exhaustion will
   preserve the original composite cause, not collapse it to the selected
   `Cause.Fail`. This matches `catch_some`'s non-recovery path. I predict
   `retry_or_else` is coherent because its terminal paths deliberately replace
   the source through `or_else`, whereas `retry` has no replacement effect.
5. **Blast radius.** Existing bare-failure retry tests and all
   `retry_or_else` behavior will remain unchanged. Only tests or callers that
   relied on catchable typed composites being terminal without consulting the
   predicate/schedule can observe the new behavior.
6. **Debt.** New named tests will close the `retry` half of CD-E22-006. The
   independent `retry_or_else` current-runtime failure-path debt will remain as
   a narrower dated row unless the existing R82 matrix already closes it.
7. **Gates.** The focused suite and all five required Nix gates will pass after
   the minimal implementation, prose, test, ledger, and changelog changes.

## Execution log

No production edits preceded the sealed predictions commit.

### History and verdict — V-DX-E24D-002

`git log -p --follow lib/eta/effect_schedule.ml`, helper-origin searches, retry
commit-message searches, and composite-retry diff searches found no intentional
reason for the divergence. Narrow `retry` predates `69adecfa`'s shared boundary;
`bbe54cd9` then introduced `retry_or_else` on that boundary. `365f7b01` called
the difference a current limitation. Verdict: align.

Terminal decision: selected typed failures drive policy, but rejection and
exhaustion return the original cause. Uncatchable composites also remain exact.

### Red/green implementation — V-DX-E24D-003

Four named tests were added first. The focused Eio suite produced three expected
failures under the old implementation: typed composites did not retry and
neither terminal test observed policy. The buried-uncatchable test was already
green, guarding against over-broadening.

After `retry` adopted `stripped_uncatchable` plus `first_typed_failure`, the same
focused suite passed all 570 tests. The mli, changelog, and E22 registry were
updated in the same change. R79–R81 register the new tests; CD-E22-006 is now
limited to the independent `retry_or_else` current-runtime failure matrix.

### Red-team and review — V-DX-E24D-004

The buried-defect, original-terminal-cause, and history-falsification checks all
pass. Review artifacts contain the full before/after matrix and direct answers
to the two assignment questions.

Independent semantic review found no blocker. Its two low findings were applied:
the exhaustion test now distinguishes an earlier composite from a differently
ordered terminal composite, and the E22 cancellation row no longer claims more
than the registered cancellation test proves.

### Final gates — V-DX-E24D-005

All required commands passed on the final tree:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build --build-dir=_build-mainline @install PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force PASS
```

Prediction score: 7/7 HIT. Recommendation: promote.

### Follow-up 1 — V-DX-E24D-006

The CORRECT-WITH-RESERVATIONS findings were accepted.

- `retry` now returns an empty raw composite unchanged when
  `first_typed_failure` returns `None`; predicate and schedule policy are not
  invoked. Named test: `retry empty composite passes through`.
- R94, R100, and R101 now point to the verified registration spans
  `1158-1159`, `1134-1147`, and `1148-1155`. R79-R82 were rechecked; R81 now
  registers the no-typed-failure passthrough test at `1194-1222`.
- The report and before/after matrix no longer call raw empty composites
  malformed; they record passthrough as the shared no-typed-failure rule.

Focused `test/core_eio` passed all 571 tests. Follow-up gates:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS on rerun
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force PASS
```

The first full-suite attempt had two unrelated SQL pool timing/finalizer
failures (`Eta_sql` cases 15 and 22); no SQL files changed, and the exact forced
full-suite rerun passed.

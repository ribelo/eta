# DX-E38 follow-up 2 sealed micro-predictions

Evidence ID: `V-DX-E38-F2-001`

This note was sealed before registry-completion implementation. The original
`journal.md` and `followup-1-journal.md` remain immutable; actual results belong
in `report.md`.

## Scope and proof audit

Runtime design is closed. This round changes only exact public-prose layout,
focused registry evidence, registry rows/totals, and the durable report.

The existing Cause suite proves top-level `Cause.diagnostic_equal` behavior for
`Die`, but it does not directly invoke `Cause.Finalizer.diagnostic_equal`.
Likewise, existing finalizer equality tests cover only `Fail`. Three small direct
tests are therefore expected:

1. structural `Finalizer.equal` behavior across composite/interrupt nodes and
   physical exception identity for `Finalizer.Die`;
2. materialized-diagnostic comparison for `Finalizer.diagnostic_equal` on
   distinct `Die` exception objects;
3. direct propagation of a raising printer supplied to
   `Cause.finalizer_of_cause`.

## Predictions

- No runtime implementation or payload change will be needed.
- The three direct tests will pass against the current implementation without a
  fix-forward cycle.
- R154 will cite both normative locations, including `cause.mli:12-14` after a
  span-preserving prose reflow; R155 will cite only the Portable sentence.
- Three new external rows will bring `cause.mli` to 12 registered rows and the
  registry total to 275 covered rows.
- Focused Cause/law checks and the native build, full-test, and shipped-package
  gates will pass. No jsoo test will move, so no mainline rerun will be required
  by this surgical follow-up.
- Expected outcome: `E38 READY FOR REVIEW` with all three clauses registered and
  both source spans exact.

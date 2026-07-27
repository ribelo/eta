# Follow-up 2: DX-E38 — registry completion (surgical)

Runtime design is cleared. One blocking class remains: the registry
must cover every law-bearing claim the new `cause.mli` makes, with exact
spans. Four items plus two span fixes; nothing else.
`objective.md`/`followup-1.md` still apply.

## Z1 — rows for the three uncovered clauses

1. `cause.mli:50-51` — "other `Finalizer` nodes retain structural
   equality; `Finalizer.Die` preserves physical exception identity."
   R156 covers only `Fail`. Add the row(s): if existing Cause equality
   tests already discriminate these (check the cause suites), re-point
   at the named tests; otherwise add the small tests (structural
   equality on Sequential/Concurrent/Interrupt nodes; physical identity
   on Die).
2. `cause.mli:55` — "`Finalizer.diagnostic_equal` compares materialized
   `Die` diagnostics." R157 covers only `Fail`. Same treatment.
3. `cause.mli:167` — "a directly supplied raising `pp_err` propagates"
   (public API path, distinct from runtime conversion capture at
   168-169). Either add the test that discriminates it (directly
   supplied pp, raise, observe propagation shape) or narrow the mli
   sentence to what R162 actually pins.

## Z2 — span accuracy

4. R154: add the duplicate normative source `cause.mli:12-14` (the
   claim appears in two places; the registry's rule is one row per
   claim with every source span).
5. R155: narrow the `14-15` span so it excludes the unrelated
   typed-channel clause.

## Protocol

Journal note, implement, re-run native trio + `test/laws` (+ mainline
jsoo if any test moved there), registry updated, report append, usual
signal. Same scope fence. This file stays uncommitted.

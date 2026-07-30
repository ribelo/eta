# Follow-up 1: DX-E42b — review findings: five fixes

Independent PR review verdict: should-not-merge. All five findings were
verified by the orchestrator against the code before this follow-up. The
ppx split itself was upheld as sound (sql-free ppx_eta, ppxlib-only
ppx_eta_sql, byte-stable snapshots). Fix all five.

## F1 — "zero-to-many" is false (originated by the orchestrator's objective text)

`mutable_ref.ml:11-17,20-26` unconditionally evaluates `f old` before the
first CAS — `f` runs **at least once** per invocation, never zero. The
contract must say "at least once, possibly many times" (or equivalent) in
`lib/eta/mutable_ref.mli` (both vals) and `docs/api-dx.md`. R177's row must
quote the corrected claim. Journal: note the phrase came from the
orchestrator's objective — executor copied it in good faith.

## F2 — Tier rules must re-derive the map

Under the written precedence rule ("implements or names an external
runtime/platform"), `eta_test` (exposes `Eta_eio.Runtime`, `Eio.Switch.t`
in `lib/test/eta_test.mli:17,41-65`) and `eta_stream` (`from_eio_stream :
'a Eio.Stream.t` at `lib/stream/eta_stream.mli:219`) resolve to
Integrations — but the map says Batteries. Two honest resolutions:

(a) Write the missing precedence rule: a package whose **primary contract
is backend-neutral** stays Batteries even when it exposes bridge types
(naming the bridge explicitly — `eta_test`'s native harness plumbing,
`eta_stream`'s H-W4 `from_eio_stream` bridge); an Integration is a package
whose primary contract IS an external boundary. Each affected row gains a
one-line bridge note.
(b) Reclassify both to Integrations.

Evaluate honestly: is the Eio exposure incidental plumbing or the
package's primary contract? Preference is (a) if the exposure is bridge
plumbing (it looks like it is), but the deciding test is honesty, not
saving the map. Also: the rules must explicitly settle `ppx_eta_sql`
(SQL as an external protocol family). Whichever you choose, re-derive all
48 rows in the journal and show the two red-team misclassification
attempts still resolve correctly.

## F3 — `lib/sql/README.md` still says `(pps ppx_eta)`

Line 227-232 instructs table-extension users to configure the removed
owner — now an unknown-extension error. Fix to the correct rewriter list;
check the whole README for other stale preprocess instructions.

## F4 — Law registry stale pointers

Adding the MutableRef test shifted `test/core_common/core_common_suites.ml`
line numbers; earlier rows were not refreshed. R43 points to
`core_common_suites.ml:1835-1836` — now the new MutableRef case; the Queue
test is at 1868-1869. R44–R51 and R98 are similarly stale (review's list;
sweep for more). Refresh every shifted pointer, and add one line to the
registry's header noting the pointer-refresh obligation when tests are
inserted mid-file.

## F5 — `race` doc is incomplete (implementation-verified)

`effect_concurrent.ml:208-225`: a cancelled loser's finalizer/cleanup
diagnostic REPLACES the selected value with an error — so "first child to
produce a value wins" is only true when no cleanup diagnostic surfaced.
The mli must state the qualification. Also state that any `Exit.Error`
cause (not only typed failures) loses to a later success. R179's claim
("every all-failure cause returned concurrently") is wider than its test
(two typed `Effect.fail` branches): either narrow the claim to what the
test discriminates or extend the test to mixed causes — pick the honest
one and adjust the row.

## Required

1. Fixes F1–F5 with named tests/spans updated where claims moved.
2. Journal: per-finding verdicts (justified/not), including F1's
   orchestrator origin.
3. Report: append `Follow-up 1 outcome`.
4. Full four-gate quartet.

## Done means

`E42B READY FOR REVIEW` (or `E42B BLOCKED: <reason>`). Same scope fence.
This file stays uncommitted.

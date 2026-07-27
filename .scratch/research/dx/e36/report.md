# DX-E36 report — background failure semantics

## Recommendation

**READY FOR REVIEW.** Ship the explicit split:

- `Effect.with_background`: fail-fast lexical background work;
- `Effect.with_supervised_background`: the former behavior, unchanged;
- no best-effort value: `with_supervised_background (ignore_errors background)`
  already expresses it.

Follow-up 2 corrects the false cleanup-parity conclusion from follow-up 1 and
closes the resulting blocking defect with exact structural evidence.

## Follow-up 1 closures

1. **F1 closed by amendment:** the contract now explicitly says terminal-exit
   publication order and names `par`'s first-observed model. The registry treats
   that correspondence as contract wording; tests pin publication order and
   promise no safety-first priority.
2. **F2 was not closed:** those tests accepted two shapes independently and
   therefore could not detect that the candidate discarded an interrupt wrapper.
   Follow-up 2 replaces this false conclusion and its registry evidence.
3. **F3 closed by evidence:** native and jsoo regressions delay the losing body
   finalizer until after cancellation, then require the exact background failure
   and completed loser finalizer before the arbiter returns. No publication was
   lost, so no protected-commit code was added.

## Follow-up 2 repair

- The filter now removes only a clean internal cancellation. Every loser with a
  cleanup failure, defect, or composite is converted and attached in full.
- Exact old/new structural comparisons pin the complete expected trees after
  body success, typed failure, and defect. Typed cleanup errors render as
  `Cleanup_failed`, rather than the former non-discriminating placeholder.
- A background-winner regression pins the background failure as primary and the
  complete body interruption/cleanup failure as its finalizer diagnostic.
- The jsoo publication test now holds the losing finalizer, proves the parent
  result remains unresolved, then releases cleanup and checks the exact winner
  plus completed cleanup.

## Contracts and mechanism

`lib/eta/effect.mli:692-705` states the split in six fail-fast contract lines:

- a first background failure cancels and awaits use, runs its finalizers, and
  propagates the background cause;
- a first body completion cancels and awaits the background;
- a racing failure/completion is linearized by terminal-exit publication;
- supervised failure does not affect use before use ends.

`with_supervised_background` is the old supervisor implementation renamed
verbatim. Fail-fast `with_background` uses one generative stop exception, one
fresh internal interrupt ID, one two-exit stream, and one parent arbiter under a
lexical switch. Observable tests require each branch's finalizers to run exactly
once. The switch waits for both children before result assembly. Internal
cancellation-only exits are removed; every loser carrying real diagnostics is
attached in full, preserving its interrupt wrapper and cleanup provenance.

`race` and `par` composition were rejected by executable-mechanism analysis:
`race` does not fail fast after one failed branch, while `par` cannot let an
early successful background continue yet cancel it on body success without an
extra control failure and cause rewriting.

## Pinned semantics evidence

Native registrations are in
`test/core_common/supervisor_common_suites.ml:668-702`; jsoo counterparts are in
`test/js_jsoo/test_eta_jsoo.ml:859-872`.

| Edge | Named evidence | Result |
|---|---|---|
| Typed background failure | `with_background typed failure cancels use and awaits finalizers`; jsoo `with_background typed failure cancels use` | Exact `Cause.Fail`; body cancelled; finalizer exactly once |
| Background defect | `with_background defect cancels use and awaits finalizers`; jsoo counterpart | Same exception identity in `Cause.Die`; finalizer exactly once |
| Body success/failure first | `with_background body success or failure cancels and awaits child`; jsoo `with_background body exits cancel child` | Body exit preserved; background finalized exactly once in both branches |
| Body interruption | `with_background body interruption matches par cause shape`; jsoo counterpart | Outer `par` exposes only its winning `Stop` failure; no leaked anonymous interrupt |
| Supervised preservation | Three mechanically migrated current tests plus `with_supervised_background failure does not cancel use`; jsoo counterpart | Body remains blocked after child failure and completes only after independent release |
| Same-release race | `with_background same-release exits choose one winner once`; jsoo counterpart | First post-release publication agrees with the primary outcome; both finalizers run exactly once |

The final implementation filters only clean internal cancellation. Exact native
trees preserve real cleanup failures; the strengthened jsoo F3 test proves its
held successful finalizer completes before result assembly.

## Migration

- The five tests/callers that specifically encoded the former lifecycle behavior
  moved mechanically to `with_supervised_background` (three Supervisor cases,
  the runtime lifecycle case, and the Promise boundary case).
- Audit assertions now cover both structured variants.
- Existing ordinary examples and API-DX snippets retain `with_background` and
  therefore adopt the safer fail-fast default.
- `examples/background_lifecycle.ml` is the fail-fast teaching site: its
  background fails, the cause propagates, and the example checks that cleanup ran.
- README and background/API boundary docs explain both choices.
- No HTTP daemon/protocol reader was migrated or changed. That remains E42a.

## Census and footgun score

| Prediction | Actual | Score |
|---|---|---|
| Public census `+1 val` | `with_supervised_background` added; two public values now exist | Match |
| Footgun `-1` | Generic `with_background` can no longer leave a body running after a published required-child failure | Match |
| 37-line upstream census receives semantic split | Former-behavior tests moved; other call sites adopt fail-fast or were documented | Match |
| No best-effort helper | Composition documented; no value added | Match |

## Predictions versus actuals

Nine of ten top-level sealed predictions matched. The original safety-first tie
prediction was superseded by the adjudicated publication-order amendment; the
READY review prediction is restored only after follow-up 2 replaced the false F2
evidence and F3 was strengthened.

The journal predicted unconditional safety-first background precedence for work
made runnable by one release. The runtime contract has no release epoch,
runnable-set inspection, or backend-independent waiter priority. The shipped
rule is the strongest precise rule the existing substrates expose: terminal
exits are serialized through one runtime
stream and the first publication wins. The same-release tests record that
publication and prove one winner and exactly-once finalization. The sealed
journal was not edited.

The prediction of an atomic CAS was also unnecessary: only the parent consumes
the exit stream and selects the winner, so a single-consumer arbiter is smaller
and gives the observable winner and exactly-once-finalizer invariants.

## Red-team outcome

Artifacts: `.scratch/research/dx/e36/redteam/`.

1. The old dead-reader trap now terminates with the reader's typed failure or
   defect and exactly one body finalizer. Under old semantics the body remained
   in `never` and the run needed an external timeout.
2. The supervised non-leak attack fails: child failure cannot complete or cancel
   the body. It surfaces only after the independently released body ends.

## Hypothesis status

| Candidate | Final status | Evidence |
|---|---|---|
| Dedicated asymmetric lexical arbiter + verbatim supervised helper | Accepted | Publication-order wording, cleanup parity, and post-cancel publication are executable on required substrates |
| Pure `par`/`race` composition | Rejected | Cannot satisfy asymmetric early-success and cleanup shapes |
| `with_best_effort_background` | Out of scope / unnecessary | Existing composition expresses it |
| Supervisor redesign or HTTP migration | Out of scope | E36 fence; E42a follow-up |

Remaining risk is limited to backend implementations outside the two required
substrates; native Eio and jsoo now execute the post-cancellation publication
regression.

## Verification

All passed:

```sh
nix develop -c dune runtest test/core_eio --force
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

Fix-forward limits were respected: one compile-pattern correction; two
interruption-shape mechanism corrections before the dedicated arbiter passed;
one jsoo cancellation-only-finalizer correction.

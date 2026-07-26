# DX-E36 report — background failure semantics

## Recommendation

**BLOCKED.** Do not ship the candidate split yet. The intended API remains:

- `Effect.with_background`: fail-fast lexical background work;
- `Effect.with_supervised_background`: the former behavior, unchanged;
- no best-effort value: `with_supervised_background (ignore_errors background)`
  already expresses it.

All assignment gates pass, but adversarial review found three semantic proof
gaps that the current runtime contract/tests do not close.

## Blocking findings

1. The assignment requires background failure to beat body success when both
   become ready from one release. The candidate instead specifies first terminal
   publication because `Runtime_contract` exposes no release epoch, runnable-set
   inspection, or portable waiter priority. Restoring the literal rule requires
   a cross-backend arbitration primitive outside E36's scope fence; accepting
   publication order requires an upstream objective decision.
2. Use-first cleanup parity is incomplete. The candidate extracts cancellation
   finalizers from the losing exit and gives use its own child finalizer scope;
   this has not proven the former `finally (cancel_child_effect child)` cause
   shape and ordering when background cleanup fails after use success/failure.
3. Loser exit publication happens with `stream_add` after cancellation. The
   runtime contract does not state that this handoff is cancellation-safe. The
   candidate needs a protected commit plus a regression proving both terminal
   events are always published before arbitration assembly.

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
lexical switch. The arbiter issues at most one group cancellation. The switch
waits for both children before result assembly. Internal cancellation-only exits
are removed; real loser cleanup diagnostics remain finalizer/suppressed-finalizer
evidence.

`race` and `par` composition were rejected by executable-mechanism analysis:
`race` does not fail fast after one failed branch, while `par` cannot let an
early successful background continue yet cancel it on body success without an
extra control failure and cause rewriting.

## Pinned semantics evidence

Native registrations are in
`test/core_common/supervisor_common_suites.ml:523-541`; jsoo counterparts are in
`test/js_jsoo/test_eta_jsoo.ml:87-241`.

| Edge | Named evidence | Result |
|---|---|---|
| Typed background failure | `with_background typed failure cancels use and awaits finalizers`; jsoo `with_background typed failure cancels use` | Exact `Cause.Fail`; body cancelled; finalizer exactly once |
| Background defect | `with_background defect cancels use and awaits finalizers`; jsoo counterpart | Same exception identity in `Cause.Die`; finalizer exactly once |
| Body success/failure first | `with_background body success or failure cancels and awaits child`; jsoo `with_background body exits cancel child` | Body exit preserved; background finalized exactly once in both branches |
| Body interruption | `with_background body interruption matches par cause shape`; jsoo counterpart | Outer `par` exposes only its winning `Stop` failure; no leaked anonymous interrupt |
| Supervised preservation | Three mechanically migrated current tests plus `with_supervised_background failure does not cancel use`; jsoo counterpart | Body remains blocked after child failure and completes only after independent release |
| Same-release race | `with_background same-release exits choose one winner once`; jsoo counterpart | First post-release publication agrees with the primary outcome; both finalizers run exactly once |

The jsoo pass exposed and closed one substrate-specific diagnostic: protected
successful cleanup could render a cancellation-only finalizer interrupt. The
final implementation filters that internal diagnostic while preserving any real
cleanup failure.

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

Eight of ten top-level sealed predictions matched: five semantic edges,
migration, census, and footgun. The tie prediction and READY review prediction
did not survive adversarial review.

The journal predicted unconditional safety-first background precedence for work
made runnable by one release. The runtime contract has no release epoch,
runnable-set inspection, or backend-independent waiter priority. The shipped
rule is the strongest precise rule the existing substrates expose: terminal
exits are serialized through one runtime
stream and the first publication wins. The same-release tests record that
publication and prove one winner and exactly-once cleanup. The sealed journal was
not edited.

The prediction of an atomic CAS was also unnecessary: only the parent consumes
the exit stream and selects the winner, so a single-consumer arbiter is smaller
and gives the same one-cancellation invariant.

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
| Dedicated asymmetric lexical arbiter + verbatim supervised helper | Partial / blocked | Main branches pass, but tie, cleanup parity, and cancellation-safe publication remain open |
| Pure `par`/`race` composition | Rejected | Cannot satisfy asymmetric early-success and cleanup shapes |
| `with_best_effort_background` | Out of scope / unnecessary | Existing composition expresses it |
| Supervisor redesign or HTTP migration | Out of scope | E36 fence; E42a follow-up |

Blocking risks are the missing portable same-release priority, unproven use-first
cleanup shape/order, and an uncontracted cancellation-sensitive loser handoff.

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

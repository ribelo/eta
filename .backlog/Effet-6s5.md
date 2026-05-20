---
id: Effet-6s5
title: "Research: structured Cause algebra (Sequential / Concurrent / Suppressed)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:37:15.392Z
created_by: backlog
updated_at: 2026-05-19T22:57:40.543Z
closed_at: 2026-05-19T22:57:40.543Z
close_reason: "Completed. Cause research lab in scratch/cause_research/ compared
  Both vs Structured (Sequential/Concurrent/Suppressed) algebra. Decision diary
  V-RCv1–V-RCv9 recorded in journal.md lines 4528–4750. Recommendation: adopt
  structured Cause algebra. Follow-up implementation slice listed in V-RCv9
  (Cause.t, race, par, all, finalizers, OTel flattening)."
dependencies:
  - issue_id: Effet-6s5
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:45:30.777Z
    created_by: backlog
---

# Research: structured Cause algebra (Sequential / Concurrent / Suppressed)

## description

Review 1 finding #6 plus Review 2's classification of slim Cause/Exit as 'shape on probation'. Current Cause.t is Fail | Die | Interrupt | Both. Both is binary and order-free, which is enough for the first race hole but loses information that diagnostic consumers want:
- whether failures came from parallel children (par/all) vs sequential bind/finalizer
- finalizer suppression chains (main fails, release fails — release is suppressed but should be visible)
- interruption identity (which scope/race triggered the interrupt)
- order semantics for sequential causes

The journal's own observability work flattens Cause.Both into multiple OTel exception events, implicitly admitting that 'binary both' is too thin for downstream consumers.

Hypothesis to lab: replace Both with a richer algebra:
type 'e Cause.t =
  | Fail of 'e
  | Die of exn * Printexc.raw_backtrace option
  | Interrupt of interrupt_id option
  | Sequential of 'e Cause.t list
  | Concurrent of 'e Cause.t list
  | Suppressed of { primary : 'e Cause.t; finalizer : 'e Cause.t }

Run a fixture: par with two simultaneous failures, all with one failure plus a sibling finalizer that also fails, nested scoped with finalizer-during-failure, sequential bind with two failures via tap_error rethrow.

## design

Lab in scratch/cause_research/. Implement two competing Cause shapes side by side: current Both vs proposed structured algebra. Run identical fixtures through both. Compare:
- can Cause.pp render the result usefully?
- does Effect.catch still receive 'err on a single typed Fail at the top? (it must — the typed-failure boundary contract cannot change)
- does flattening to OTel events preserve the right structure?
- do par/all/for_each_par produce Concurrent rather than nested Both?
- does scoped + acquire_release with finalizer-failure produce Suppressed?

Also test backwards compatibility: existing Cause-using tests (race all-failures, etc.) must still pass on the new shape with at-most cosmetic adjustments to assertions.

## acceptance criteria

scratch/cause_research/ contains current and proposed Cause shapes with the same fixture suite. The lab demonstrates whether Sequential/Concurrent/Suppressed preserve information that Both loses, with concrete diff output. journal.md gains a V-RCv1..V-RCvN decision diary. Recommendation is one of: (a) keep Both, with documented loss; (b) adopt structured algebra, with a follow-up implementation task that updates Cause.t, race/par/all/for_each_par/scoped interpreters, Cause.pp, and effet-otel cause flattening; (c) more research needed. 2h time budget.

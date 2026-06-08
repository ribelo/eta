# P0-T1 Full Effect.t Recursive GADT Probe

Status: final for Effet-OxCaml-uwr.

Question: can Phase 4 annotate the full current Effect.t as one portable recursive GADT with env portable/contended, err immutable_data, success immutable_data, and portable callbacks, or does the AST need to split?

## Artifacts

- candidate_a_one_gadt.ml: one full portable GADT over the current constructor set.
- candidate_b_split.ml: portable pure core plus same-domain runtime/I/O GADT.
- candidate_b_split_negative.ml: capture-safety negative for the portable core.
- candidate_b_polyvariant_error_negative.ml: typed-error negative for current open polymorphic-variant style.
- candidate_c_mode_template.ml: mode-template sketch over portable/nonportable.
- results/compile.out and per-candidate logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/effect_full_gadt_probe/run.sh

Last result:

    summary: pass=5 fail=0

## Evidence

Candidate A fails before recursive kind inference is the main problem. The current Timeout constructor widens the error channel to an open polymorphic variant, and OxCaml reports that [> Timeout] has kind value mod non_float, not immutable_data. That contradicts the requested err immutable_data annotation for one universal Effect.t.

Candidate B passes. The portable pure core can carry the requested env, err, and success kind constraints and portable callbacks. The same-domain runtime GADT can still hold Duration, Schedule, Cause.t, Eio.Switch.t, Eio.Promise.t, supervisor refs, observability nodes, and existing fiber/runtime nodes without forcing those values into a portable boundary.

Candidate B's callback negative fails as desired. A Thunk callback capturing int ref is rejected as contended where a portable callback is required.

Candidate B's polymorphic-variant error negative fails as desired. Even the portable pure core rejects an open polymorphic variant error under the requested err immutable_data bound. Portable-domain APIs will need an immutable-data error representation rather than Effet's current open polymorphic variant style.

Candidate C fails. A mode-polymorphic template does not remove the hard payload kind problem: All_settled exposes result values containing Cause.t, whose kind mentions raw backtraces and is not immutable_data.

## Comparison

- A, one portable GADT: reject. It attempts all constructors, but fails on Timeout before portable callback enforcement is reached.
- B, split pure/runtime: adopt. The runtime side keeps all constructors, the portable side is the pure core, and capture safety is mechanically enforced.
- C, mode template: reject for now. It adds PPX/template complexity and still fails on Cause.t payload kind.

## Decision diary

- V-P0T1-1 - Reject one universal portable Effect.t.
  Decision: Phase 4 should not annotate the current full Effect.t as one portable GADT.
  Rationale: candidate_a_one_gadt fails on the current Timeout error-channel shape before reaching deeper recursive-GADT issues. The requested immutable_data error kind is incompatible with Effet's open polymorphic variant errors.

- V-P0T1-2 - Adopt a split AST shape for Phase 4.
  Decision: Phase 4 should split a portable pure/domain AST from a same-domain runtime/fiber AST, with the runtime interpreting both.
  Rationale: candidate_b_split compiles, while candidate_b_split_negative proves portable callbacks are mechanically enforced. This preserves the current runtime nodes while giving domain execution a statically checked core.

- V-P0T1-3 - Treat portable typed errors as a separate boundary design.
  Decision: do not promise current polymorphic-variant typed failures inside the portable core.
  Rationale: candidate_b_polyvariant_error_negative shows open polymorphic variants are not immutable_data. A later Cause.Portable / error-boundary task must pick an immutable representation for cross-domain typed failures.

- V-P0T1-4 - Reject mode-template unification for now.
  Decision: do not use a mode-polymorphic template to preserve one source AST.
  Rationale: candidate_c_mode_template still fails on Cause.t payload kind and adds PPX/template complexity without removing the real boundary problem.

## Deferred

- Full Phase 4 implementation still needs constructor-by-constructor fixtures for the chosen split.
- Cause.Portable remains required for all_settled and cross-domain failure aggregation.
- The Eio wrapper tasks still decide Switch_local, Fiber_portable, Cancel_local, and Stream_portable.
- Bind/Map continuation once-mode behavior remains a separate Phase 0 question.


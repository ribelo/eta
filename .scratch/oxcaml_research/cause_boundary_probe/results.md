# P0-T3 Cause Boundary Probe

Status: final for Effet-OxCaml-vyr.

Question: what representation should Effet use when a Cause.Die crosses Parallel domains?

## Artifacts

- raw_exn_positive.ml: raw exn + raw_backtrace declared portable and returned across Parallel.
- raw_exn_fcm_negative.ml: first-class-module custom exception hazard; it also compiles.
- materialized_positive.ml: string/tag/stack diagnostic mirror returned across Parallel.
- materialized_closure_negative.ml: materialized diagnostics reject closure payloads.
- typed_defect_positive.ml: typed immutable defect variant returned across Parallel.
- typed_defect_negative.ml: typed errors reject closure payloads.
- explicit_conversion_positive.ml: same-domain raw cause converted to portable mirror before crossing.
- explicit_conversion_negative.ml: unconverted same-domain raw cause captured into Parallel is rejected.
- results/compile.out and per-fixture logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/cause_boundary_probe/run.sh

Last result:

    summary: pass=8 fail=0

## Evidence

Candidate A, raw exn + raw_backtrace, compiles and crosses Parallel when the boundary type is declared portable. That proves OxCaml can represent the raw fields as portable in this setup. It is not sufficient for Effet because the FCM custom exception hazard also compiles; there is no negative fixture that mechanically rejects the documented unsound shape.

Candidate B, materialized diagnostics, compiles and crosses Parallel. Its negative fixture rejects a closure-valued field, so the boundary is pure data. It preserves the information Effet can reasonably move across domains: exception string/classification, optional stringified stack, span name, and annotations.

Candidate C, a typed immutable defect variant, also compiles and rejects closure payloads. It is viable mechanically, but it makes unchecked Die diagnostics look like a typed error algebra and would blur Cause.Fail vs Cause.Die.

Candidate D, explicit conversion, compiles and gives the cleanest boundary. Same-domain Cause.Die can keep raw exn/backtrace for local debugging. Cross-domain aggregation must call Cause.Portable.of_cause / of_die to materialize the diagnostic. The negative fixture shows an unconverted same-domain raw cause captured into Parallel is rejected.

## Decision diary

- V-P0T3-1 - Do not make raw Cause.Die the portable boundary.
  Decision: raw exn/raw_backtrace stay in the same-domain Cause.t only.
  Rationale: raw_exn_positive proves the raw shape can compile and cross domains if declared portable, but raw_exn_fcm_negative also compiles. That means the type system is not giving Effet the safety bar we need for arbitrary exception constructors.

- V-P0T3-2 - Use a materialized Cause.Portable diagnostic.
  Decision: Phase 1 should add a Cause.Portable mirror whose Die payload is pure data: kind/string classification, message, optional stringified stack, span_name, and annotations.
  Rationale: materialized_positive crosses domains and materialized_closure_negative rejects nonportable payloads. This preserves useful diagnostics without exposing raw exception identity as a cross-domain contract.

- V-P0T3-3 - Keep conversion explicit and lossy at the boundary.
  Decision: same-domain Cause.t converts to Cause.Portable.t through explicit of_cause / of_die functions before Parallel aggregation.
  Rationale: explicit_conversion_positive proves the conversion shape; explicit_conversion_negative proves the current raw same-domain cause is not accidentally shareable when left unannotated. Information loss is accepted: exception identity and raw backtrace identity become strings at the portable boundary.

- V-P0T3-4 - Reject typed-defect replacement as the primary boundary.
  Decision: do not replace Die with a typed Effet error variant in the portable cause.
  Rationale: typed_defect_positive is mechanically viable, but it confuses the unchecked defect channel with typed failures. Cause.Fail remains the typed error channel; Cause.Die remains diagnostics for defects.

## Deferred

- Phase 1 must implement Cause.Portable and wire conversion through cross-domain runtime paths.
- The portable error payload for Cause.Fail still depends on the Phase 4 portable Effect.t error-kind decision.
- Same-domain Cause.pp/equal can keep raw exn behavior; portable equality/printing should be string based.


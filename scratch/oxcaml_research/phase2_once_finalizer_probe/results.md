# Phase 2 Once Finalizer Results

Command: nix develop .#oxcaml -c bash scratch/oxcaml_research/phase2_once_finalizer_probe/run.sh

Result: summary: pass=9 fail=0

| Fixture | Expected | Evidence |
| --- | --- | --- |
| public_signature_once_call_negative.ml | fail | A public @ once release parameter rejects an implementation that calls the release callback twice. |
| minimal_once_acquire_reuse_negative.ml | fail | Storing a once release callback inside the reusable effect AST makes the whole program value once and rejects repeated interpretation. |
| consuming_run_once_acquire_negative.ml | fail | Consuming the whole AST at run time still cannot extract ordinary success values from a once constructor. |
| field_many_once_release_candidate.ml | fail | Tuple/type field syntax cannot isolate many effect fields from a once release field. |
| once_ast_global_fields_positive.ml | fail | Record-field `global_` fixes locality only; it does not make extracted success values many under a once AST. |
| once_ast_once_result_candidate.ml | fail | Returning once success values still cannot pass the acquired value to an ordinary release argument. |
| church_once_resource_candidate.ml | pass | A one-shot interpreter-function representation can own a once release callback and run it exactly once. |
| wrapped_once_release_negative.ml | fail | Hiding a once release behind a regular many wrapper is rejected. |
| portable_atomic_counter_positive.ml | pass | Portable.Atomic supports the counter operations needed by daemon accounting. |

Decision: move daemon accounting to Portable.Atomic and drain the runtime finalizer stack before execution. The current data AST cannot isolate `release` at once mode without making the surrounding effect unusably once. The viable migration direction is a one-shot interpreter-function representation, which needs a broader Effect.t rewrite rather than a local resource-node patch.

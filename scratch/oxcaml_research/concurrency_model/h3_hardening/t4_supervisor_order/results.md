# T4 Supervisor Failure Order Results

## Verdict

H3 portable supervisors use task-index order for cross-domain failures. This keeps Supervisor.failures deterministic and aligns failure ordering with the indexed result store.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t4_supervisor_order/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| task_index_order_positive.ml | PASS | Reverse completion returned 0,1,2,3,4,5,6,7. |
| max_failures_positive.ml | PASS | Threshold 3 deterministically returned 0,1,2. |
| unordered_failure_bag_negative.ml | PASS | Detected unordered output 7,6,5,4,3,2,1,0. |

Summary: pass=3 fail=0.

## Pinned Invariant

Cross-domain Supervisor.failures is task-index ordered. Same-domain observation order remains an implementation detail of the current same-domain supervisor path.


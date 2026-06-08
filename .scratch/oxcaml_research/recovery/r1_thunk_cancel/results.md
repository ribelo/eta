# R1 Portable Thunk Cancellation Results

Question: what cancellation contract should the portable core give to Thunk,
given that arbitrary CPU code cannot be preempted by the interpreter?

## Candidates

| Candidate | Steelman | Evidence | Status |
| --- | --- | --- | --- |
| A. Cooperative-only thunks | The smallest honest contract: arbitrary thunks run to completion and users express cancellable work as effect graph nodes. | candidate_a_cooperative_only proved a non-polling CPU thunk ignored cancellation until completion, max_deadline_to_exit_us=99056. | Rejected as the whole contract; retained as the non-polling-thunk warning. |
| B. Polling-aware thunks | Adds one portable polling primitive so long-running library/user CPU loops can be cancellable without turning everything into tiny AST nodes. | candidate_b_polling_aware exited within max_deadline_to_exit_us_4096=5 and max_deadline_to_exit_us_1024=1. Local uncancelled loop cost was 15504us at 4096 and 15430us at 1024 on the latest run. | Accepted. |
| C. Interpreter-scoped SLO only | Keeps the runtime simple and states that only Bind/Map/evaluator loops are covered. | candidate_c_interpreter_scoped exited within max_deadline_to_exit_us=5 at poll_every=4096. | Dominated by B because it leaves library CPU loops without a testable cancellation hook. |

## Verdict

Portable Thunk is cooperative, but the portable API must include an explicit
portable poll primitive available to polling-aware thunks. The timeout-exit SLO
applies to interpreter-controlled boundaries and to thunks that call poll at the
documented interval. Arbitrary non-polling thunks are explicitly outside the
SLO and may run until completion.

Phase 6 should tighten interpreter-loop polling from 4096 to 1024 unless the
package-level evaluator benchmark shows unacceptable throughput cost. The local
R1 loop measured 1024 in the same runtime band as 4096, while the old 4096 T7
bound was close to the 50ms cap; the extra margin is worth the measured cost.

## Command

nix develop -c bash scratch/oxcaml_research/recovery/r1_thunk_cancel/run.sh

Result: summary pass=3 fail=0.

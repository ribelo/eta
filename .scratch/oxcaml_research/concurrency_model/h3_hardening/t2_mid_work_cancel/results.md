# T2 Mid-Work Cancellation Results

## Verdict

Workers poll the portable cancel token at interpreter polling points. The hardened baseline is: check cancellation at every Bind/Map boundary and at least every 4096 pure-core loop iterations while interpreting CPU-heavy nodes.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t2_mid_work_cancel/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| polling_positive.ml | PASS | samples=7 poll_every_ast_nodes=4096 max_polls=63 p95_cancel_latency_us=5. |
| no_poll_negative.ml | PASS | Worker ignored cancel and completed iterations=900000. |

Summary: pass=2 fail=0.

## Pinned Invariant

Cancellation is mechanical, not incidental. A worker that does not poll the token does not cancel; all portable workers must poll by the discipline above.


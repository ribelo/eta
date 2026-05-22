# H2 Work-Stealing Probe

Status: final for Effet-OxCaml-rp2 T3.

Question: does per-domain work stealing beat per-domain explicit push enough to
justify the extra queue protocol and owner-push audit?

Command:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/concurrency_model/h2_ws_probe/run.sh

Output:

    h2_work_stealing wall_ms=23.282 count=80 work=36000000 checksum=229220960 p50_us=558 p95_us=575 steals_attempted=4 steals_hit=1
    h3_explicit_push wall_ms=22.939 count=80 work=36000000 checksum=229220960 p50_us=557 p95_us=585 steals_attempted=0 steals_hit=0
    h2_over_h3_time_ratio=1.015
    h2_primitives=ws_deque+atomic_seed_queue+peer_steal
    h3_primitives=portable_atomic_inbox+coordinator_assignment

Complexity notes:

| Criterion | H2 per-domain work stealing | H3 explicit push |
| --- | --- | --- |
| Runtime primitives in probe | ws_deque, seed queue, peer stealing | portable atomic inbox, coordinator assignment |
| H7 workload wall time | 23.282ms | 22.939ms |
| Per-task latency | p50 558us, p95 575us | p50 557us, p95 585us |
| Result correctness | Same count/work/checksum | Same count/work/checksum |
| Steal protocol activity | 4 attempts, 1 hit | None |
| V-P0T6 inherited issue | Still needs non-ws producer handoff because push is owner-local | Directly uses producer handoff |

Verdict: H2 is rejected for now. It does not win meaningfully on the H7
disproof workload and requires a larger primitive set. H3 remains the lead
candidate unless later skew evidence requires H4's steal-on-overload refinement.

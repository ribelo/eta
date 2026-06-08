# results.md — caqti-eio fit-for-Eta cross-tab

Filled at epic close. Placeholder; structure below.

## Per-probe evidence

| Probe | Status | Falsified | Evidence path |
| --- | --- | --- | --- |
| CQ-0 install gate | | | cq0_install/ |
| CQ-1 API audit | | | api_audit.md |
| CQ-2 H1 smoke | | | cq2_h1_smoke/ |
| CQ-3 H2 smoke | | | cq3_h2_smoke/ |
| CQ-4 cancellation | | | cq4_cancellation/ |
| CQ-5 health | | | cq5_health/ |
| CQ-6 errors | | | cq6_errors/ |
| CQ-7 transactions | | | cq7_transactions/ |
| CQ-8 streaming | | | cq8_streaming/ |
| CQ-9 observability | | | cq9_observability/ |

## Cross-tab: H1 vs H2 vs Hybrid

| Criterion | H1 (caqti's pool) | H2 (Eta.Pool wrap) | Hybrid | Citation |
| --- | --- | --- | --- | --- |
| Cancellation correctness |  |  |  | CQ-4, CQ-7 |
| Lifecycle ownership |  |  |  | CQ-3 |
| Error mapping fidelity |  |  |  | CQ-6 |
| Observability seam |  |  |  | CQ-9 |
| Transaction scoping |  |  |  | CQ-7 |
| Streaming / cursors |  |  |  | CQ-8 |
| Health predicate |  |  |  | CQ-5 |
| Dep posture |  |  |  | CQ-0, CQ-1 |
| Call-site complexity |  |  |  | CQ-2, CQ-3 |
| Capability completeness |  |  |  | CQ-1 |

## Verdict

(Filled at epic close. One of: H1, H2, Hybrid, Pivot.)

## Risk register

(Anything deferred or partial; explicit "would change verdict if X.")

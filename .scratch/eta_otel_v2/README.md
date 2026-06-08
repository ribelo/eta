# eta-otel v2 Research

Research for the clean-room eta-otel rebuild described in
`.objectives/eta-otel-and-eta-ai.md`.

Track O now uses `packages/eta-otel` as the rebuilt implementation. This
directory records the evidence that justified the replacement with an
Eta-primitive-first exporter that uses eta-http v1.

## Probes

| Probe | Artifact | Status |
| --- | --- | --- |
| R-T0 transparent cost | [r_t0_transparent_cost/verdict.md](r_t0_transparent_cost/verdict.md) | OS4 follow-up recorded; zero alloc/no-linkage proven, strict zero-branch requires Eta runtime extension |
| R-T1 peer analysis | [r_t1_peer_analysis/verdict.md](r_t1_peer_analysis/verdict.md) | verdict recorded; adapter + per-signal pipelines accepted |
| R-T2 OTLP capability inventory | [r_t2_otlp_capability_inventory/verdict.md](r_t2_otlp_capability_inventory/verdict.md) | initial verdict; eta-http retry gap closed |
| R-T3 exporter-on-eta-http | [r_t3_exporter_on_eta_http/verdict.md](r_t3_exporter_on_eta_http/verdict.md) | initial verdict; collector proof passed, suppression gap fixed |

## Slice Evidence

| Slice | Artifact | Status |
| --- | --- | --- |
| OS6 tutorial + bench + cutover | [os6_cutover/verdict.md](os6_cutover/verdict.md) | accepted; tutorial updated, active legacy imports absent, encoder benchmark at or better than baseline |

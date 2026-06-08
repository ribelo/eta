# T6 Observability Reassembly Results

## Verdict

Workers receive a portable trace-context snapshot and emit portable events tagged by task_id and event_index. The coordinator sorts by that key, rebuilds the exporter stream, and owns all same-domain tracer/logger/meter sinks.

The measured reassembly cost stayed below the H5 reopen trigger.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t6_observability/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| observability_positive.ml | PASS | child_spans=4 attrs_per_child=2 metric_total=4 reassembly_pct=9.94. |
| tracer_collector_capture_negative.ml | PASS expected-fail | Same-domain tracer collector rejected. |
| closure_attribute_negative.ml | PASS expected-fail | Closure-valued event payload rejected. |

Summary: pass=3 fail=0.

## Pinned Invariant

Workers emit portable observability data only. Exporters and in-memory collectors stay coordinator-owned.


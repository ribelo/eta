# Legacy Use Cases Results

Verdict: covered by shared executable probes.

- DB-vs-FS starvation: `resource_classes/shared_pool_starvation.ml` and
  `resource_classes/db_fs_separate_pools.ml`.
- Blocking file/FS shape: `fs.scan` workloads in resource-class probes.
- SDK-like labels: `api_ergonomics/observability/trace_labels.ml`.

Consequence: the implementation epic should start with explicit named pools and
operation labels. That covers the concrete legacy use cases without adding a
resource-class framework in this research ticket.

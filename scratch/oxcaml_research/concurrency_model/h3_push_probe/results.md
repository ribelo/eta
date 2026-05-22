# H3 Explicit-Push Probe

Status: final for Effet-OxCaml-rp2 T4.

Question: can the per-domain explicit-push/share-nothing model cover Effet's
runtime concerns without a peer-stealing protocol?

Command:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/concurrency_model/h3_push_probe/run.sh

Output:

    h3_runtime_success ok=32 failed=0 cancelled=0 timeout=0 work=7040000 checksum=670905600 max_cancel_poll=0 events=64 portable_failures=0
    h3_failure_cancel ok=0 failed=1 cancelled=1 timeout=0 work=0 checksum=0 max_cancel_poll=0 events=3 portable_failures=1
    h3_timeout ok=1 failed=0 cancelled=0 timeout=1 work=200000 checksum=972270230 max_cancel_poll=0 events=4 portable_failures=1
    h3_backpressure blocked_pushes=4 capacity=3 workers=2

Coverage:

| Concern | Evidence |
| --- | --- |
| Runtime.run dispatch | coordinator fills per-domain inboxes, two workers drain and execute 32 tasks |
| par/all/for_each_par policy | round-robin explicit push over the H7 workload; H2 comparison shows comparable throughput |
| Supervisor failure aggregation | worker failure is returned as one portable failure payload |
| Cause aggregation | timeout and failure paths return portable cause codes to the coordinator |
| Cancellation propagation | failure sets a portable atomic cancel token and sibling work observes cancellation |
| Observability | workers emit portable event records; 32 successes produce 64 start/done events |
| Backpressure | bounded inbox rejects 4 pushes at capacity 3 across 2 workers |
| Timeout/clock shape | timeout is worker-local and returns as a portable cause without corrupting sibling success |

Verdict: H3 is affirmed as the base model. The probe does not surface a
pathology that justifies H4 or H5 as the default model. H4 remains a future
refinement for measured load skew; H5 remains a future simplification if
observability or failure ordering costs become visible in shipped code.


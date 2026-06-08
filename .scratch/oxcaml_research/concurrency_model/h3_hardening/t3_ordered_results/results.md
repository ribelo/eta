# T3 Ordered Result Reassembly Results

## Verdict

Every H3 child task carries a stable input index. Workers emit indexed messages; the coordinator fills a preallocated result store and scans it in input-index order for all, for_each_par, and all_settled.

Unordered atomic bags are allowed only as internal transport, never as the public result order.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t3_ordered_results/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| indexed_all_positive.ml | PASS | Reverse completion reassembled to input order; reassembly_us=0. |
| indexed_all_settled_positive.ml | PASS | Mixed Ok/Error outcomes reassembled to input order; errors=4. |
| unordered_bag_negative.ml | PASS | Detected broken order: first=task_15 expected_first=task_00. |

Summary: pass=3 fail=0.

## Pinned Invariant

User-visible result order is input order. Completion order is not observable.


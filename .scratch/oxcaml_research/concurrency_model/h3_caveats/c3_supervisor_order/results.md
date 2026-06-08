# C3 Supervisor Ordering Verdict

## Decision

Same-domain supervisors keep the existing observation-order contract.
Portable H3 supervisors use task-index order.

## Evidence

- packages/effet/supervisor.mli now distinguishes the same-domain contract
  from the portable H3 task-index contract.
- portable_task_index_order_positive.ml verifies that reverse completion
  order is reassembled into task-index order for portable supervisors.

## Latest Run

summary: pass=1 fail=0

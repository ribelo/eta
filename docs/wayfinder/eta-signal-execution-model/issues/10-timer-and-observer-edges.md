# Timer and observer edge protocols

Type: prototype
Status: resolved
Blocked by: 01, 09

## Question

How must timer lifecycle and observer delivery cross the selected pure-kernel
seam?

Preserve commit ordering, callback order, retries, cancellation, disposal,
runtime provenance, and failure aggregation. Charge these protocols only to
passes that use them.

## Answer

Use one private post-commit driver with opaque edge batches.

The kernel publishes the snapshot, observer cursors, and edge work under the
selected `Execution.run` seam. The driver then owns each claim, callback,
timer action, cleanup hook, acknowledgement, and terminal transition.

User callbacks, timer starts, timer stops, finish hooks, and stream publication
run outside the graph lane. Claims and final state changes run under the lane.

Timer demand uses a queued mismatch list. Each timer retains its creating
runtime and one generation. Demand loss fences that generation before
cancellation, so a late wake cannot publish.

Observer delivery uses the frozen topological plan. Failure or interruption
returns only the exact unacknowledged token to pending. Disposal and direct
acknowledgement use the same lane-linearized cursor.

Cleanup attempts all timer actions and finish hooks. It aggregates failures in
invocation order and keeps observer delivery pending after cleanup failure.

The stream bridge keeps the sealed delivery capability. Queue publication and
acknowledgement form one cancellation-protected region.

The integrated probe executes this protocol through the selected
`Execution.run` driver and an Eta/Eio runtime.
It preserves typed failures, defects, interruption, and runtime provenance.
It uses the pre-publication cancellation boundary that issue 09 proves.

The complete candidate allocates 2,752 words for observer failure and retry,
903 words for disposal, and 7,005 words for a timer cycle.
These values are 14.6% to 33.1% of the pinned reference values.

The largest wall-time ratios are 0.311 for failure and retry, 0.161 for
disposal, and 0.366 for the timer cycle.
Every row passes in all three process pairs.

The interfaces, alternatives, semantic checks, performance evidence, and limits
are in
[Timer and observer edge protocols](../../../../.scratch/research/eta-signal-execution-model/timer-observer-edge-protocols.md).

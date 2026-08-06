# Timer and observer edge protocols

Type: prototype
Status: in progress
Blocked by: 01, 09

## Question

How must timer lifecycle and observer delivery cross the selected pure-kernel
seam?

Preserve commit ordering, callback order, retries, cancellation, disposal,
runtime provenance, and failure aggregation. Charge these protocols only to
passes that use them.

## Progress

The current state model supports one private post-commit driver with opaque edge
batches.

The following protocol is a candidate.
The current probe does not execute its Eta runtime or cancellation boundaries.

The kernel publishes the snapshot, observer cursors, and edge work under the
selected `Execution.run` seam. The driver then owns each claim, callback,
timer action, cleanup hook, acknowledgement, and terminal transition.

User callbacks, timer operations, finish hooks, and stream publication run
outside the graph lane. Claims and final state changes run under the lane.

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

The state model allocates 105 words for observer failure and retry, 58 words for
disposal, and 83 words for a timer start-wake-stop cycle. These component rows
are diagnostics, not complete-operation acceptance rows.

The ticket remains open. The next prototype must run the same operation tapes
through the actual `Execution.run` and Eta/Eio seam. It must also measure the
complete candidate against the pinned reference.

The interfaces, alternatives, semantic checks, performance evidence, and limits
are in
[Timer and observer edge protocols](../../../../.scratch/research/eta-signal-execution-model/timer-observer-edge-protocols.md).

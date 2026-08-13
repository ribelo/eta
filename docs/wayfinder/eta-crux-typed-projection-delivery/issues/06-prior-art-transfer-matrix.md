# Prior-art transfer matrix

Type: research
Status: resolved
Blocked by: 01, 02, 03, 04, 05

## Question

What does the combined prior art establish for Eta Crux?

Create one cited comparison matrix for all required systems. Compare publication
trigger, first replay, removal, transaction batching, order, backpressure,
reconnection, and latest-value ownership.

Identify the closest reference implementations. Record which semantics transfer
to Eta Crux and which do not. Do not select a public interface.

## Answer

The
[research report](../../../../.scratch/research/eta-crux-typed-projection-delivery/prior-art-transfer-matrix.md)
compares the current Eta Crux baseline with nine prior-art systems. The matrix
covers all eight required dimensions.

No prior-art system owns the complete Eta Crux contract. The closest references
divide by concern:

- Incremental is closest for stabilize-then-publish and latest-value pull.
- Bonsai is closest for result publication before lifecycle work.
- React `useSyncExternalStore` is closest for the attachment race fence.
- Rust Crux is closest for a payload-free notice before a pull.
- StateFlow is closest for one current-value slot and current-value replay.
- Materialize is closest for snapshot-plus-updates, prefix completeness, and
  pull bounds.
- Feldera is closest for one output change across many views.

These semantics can transfer:

- publication after stabilize or commit
- one publication unit for each commit
- a distinct first snapshot and later change
- a notice beside driver-owned latest-value pull
- current-snapshot replay without history replay
- pull, subscribe, then re-read for missed-wake prevention
- explicit removal
- graph-local cutoff
- result publication before lifecycle work
- prefix-completeness signals and bounded pull
- manager-local subscription reconciliation
- non-reused request identities

These semantics cannot transfer:

- missing transport acknowledgment
- progress tokens treated as delivery answers
- suppression of a committed root output
- independent streams without one atomic commit
- unspecified collector or effect order
- unbounded queues or dropped chunks
- pull-time projection recompute
- client-rebuilt diffs as the root frame
- application-owned resume as session replacement
- application effects as transport writes

Later design must not depend on undocumented observer order, effect order, or
listener order. It must also exclude the conflicting Bonsai reactivation text,
the conflicting Solid equality default, and unpinned live-page behavior.

The matrix does not select a public interface. No new ticket is necessary.

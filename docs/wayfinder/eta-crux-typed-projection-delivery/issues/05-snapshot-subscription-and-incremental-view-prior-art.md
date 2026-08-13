# Snapshot-subscription and incremental-view prior art

Type: research
Status: resolved
Blocked by: none

## Question

Which other primary-source systems provide relevant publication contracts?

Cover React `useSyncExternalStore`, at least one fine-grained signal library,
at least one dataflow or incremental-view system, and a snapshot-plus-subscribe
protocol.

Focus on coherent snapshots, transaction batching, dynamic removal, missed-wake
prevention, attachment replay, reconnection, order, backpressure, and latest
value ownership. Separate semantics that fit Eta Crux from semantics that do
not fit its commit and driver model.

## Answer

The [research report](../../../../.scratch/research/eta-crux-typed-projection-delivery/05-snapshot-subscription-and-incremental-view-prior-art.md)
records the full evidence and source revisions.

React attaches with a current-snapshot pull, subscribes, then re-reads the
snapshot. This sequence closes the attachment race. Later notices cause another
pull and do not carry values.

SolidJS batches observer work, but each signal owns an independent current
value. It does not define one shared commit, effect order, backpressure, or
delivery acknowledgment.

Feldera publishes one output change across all views for each input change. Its
HTTP stream can start with a materialized snapshot. The default backpressure
policy drops chunks, and its completion token does not acknowledge subscriber
delivery.

Materialize emits one relation snapshot and later diffs on the same
`SUBSCRIBE`. Its timestamps order changes, `PROGRESS` marks prefix completeness,
and `FETCH` provides pull backpressure. Reconnection and reconstructed state
belong to the application.

Eta Crux can transfer current-snapshot attachment, post-subscribe re-read,
notice-then-pull, one batch for each commit, explicit disposal, prefix
completeness, and bounded pull.

Eta Crux cannot transfer dropped chunks, independent transport streams,
application-owned root reconstruction, unspecified observer order, or missing
acknowledgment. The driver must remain the latest committed-value owner and the
only transport writer.

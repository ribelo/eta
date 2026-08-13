# Snapshot-subscription and incremental-view prior art

Type: research
Status: open
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

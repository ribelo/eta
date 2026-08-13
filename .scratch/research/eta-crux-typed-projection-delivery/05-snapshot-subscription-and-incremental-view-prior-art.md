# Snapshot-subscription and incremental-view prior art

Ticket: [`docs/wayfinder/eta-crux-typed-projection-delivery/issues/05-snapshot-subscription-and-incremental-view-prior-art.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/issues/05-snapshot-subscription-and-incremental-view-prior-art.md)

## Question

Which other primary-source systems provide relevant publication contracts?

This report covers four required classes:

- React `useSyncExternalStore`
- one fine-grained signal library (SolidJS 1.9)
- one incremental-view dataflow system (Feldera DBSP)
- one snapshot-plus-subscribe protocol (Materialize `SUBSCRIBE`)

Jane Street Incremental and Bonsai already have a sibling report. This report does not repeat that census.

This report records publication contracts. It does not select a public interface.

## Answer

React `useSyncExternalStore` attaches with a current-snapshot pull. It then subscribes and re-reads to close the attachment race. Later store notices cause another pull. The store owns the latest value. A store mutation during a Transition forces a blocking render. The hook has no delivery acknowledgment and no transport.

SolidJS signals own one current value each. A read registers an observer. `batch` defers downstream work until the batch ends. Independent signals have no shared commit. Effect order is not guaranteed. There is no backpressure and no reconnection protocol.

Feldera DBSP treats one input change as one output change across all views. A materialized view retains a complete snapshot. HTTP subscribe can send that snapshot, then deltas. Default HTTP backpressure drops chunks. Completion tokens wait for input processing, not for one subscriber acknowledgment.

Materialize `SUBSCRIBE` emits one snapshot at `AS OF`, then ordered diffs. `PROGRESS` marks a complete timestamp. `DECLARE` plus `FETCH` bounds pull. Reconnect uses retained history and `AS OF`. The client rebuilds state from diffs. There is no delivery acknowledgment.

Eta Crux can take notice-then-pull for later changes, an initial current-snapshot pull, a post-subscribe re-read, one batch per commit, explicit dispose, and timestamp completeness.

Eta Crux cannot take dropped chunks, independent signal streams, client-rebuilt diffs as the root frame, or missing acknowledgment.

## Method

Primary sources only.

| Class | Meaning |
|---|---|
| Documented | Official reference, RFC, or first-party API page |
| Source | Current implementation behavior |
| Inference | Reading that this report adds |

This report did not run React, SolidJS, Feldera, or Materialize tests.

## Source revisions

Facts captured after React `19.2.8` (2026-07-21) and Solid `1.9.14` (2026-07-01).

| Source | Revision |
|---|---|
| React current release | Tag `v19.2.8`, published 2026-07-21 |
| React RFC 0214 | `reactjs/rfcs` file `text/0214-use-sync-external-store.md` on `main` |
| react.dev hook page | Live reference. No published commit pin |
| SolidJS current release line | `1.9.14`, version commit `d2f81d546d5dff37aa25e4fa224e2192efec8c1a` (2026-07-01) |
| SolidJS docs | Live pages stamped 2026-04-28 |
| Solid 2.0 | Beta only. Not used as authority |
| Feldera docs | Live first-party pages. No published commit pin |
| Materialize docs | Live first-party pages. No published commit pin |

Stable file URLs use the React release tag and the Solid version commit.

| ID | File and role | URL |
|---|---|---|
| R-DOC | `useSyncExternalStore` reference | https://react.dev/reference/react/useSyncExternalStore |
| R-RFC | RFC 0214 | https://github.com/reactjs/rfcs/blob/main/text/0214-use-sync-external-store.md |
| R-HOOKS | Fiber hook implementation | https://github.com/facebook/react/blob/v19.2.8/packages/react-reconciler/src/ReactFiberHooks.js |
| R-SHIM | Userspace shim | https://github.com/facebook/react/blob/v19.2.8/packages/use-sync-external-store/src/useSyncExternalStoreShimClient.js |
| S-SIG | `createSignal` reference | https://docs.solidjs.com/reference/basic-reactivity/create-signal |
| S-MEMO | `createMemo` reference | https://docs.solidjs.com/reference/basic-reactivity/create-memo |
| S-EFF | `createEffect` reference | https://docs.solidjs.com/reference/basic-reactivity/create-effect |
| S-BATCH | `batch` reference | https://docs.solidjs.com/reference/reactive-utilities/batch |
| S-CLEAN | `onCleanup` reference | https://docs.solidjs.com/reference/lifecycle/on-cleanup |
| S-SRC | Solid reactive core | https://github.com/solidjs/solid/blob/d2f81d546d5dff37aa25e4fa224e2192efec8c1a/packages/solid/src/reactive/signal.ts |
| F-INTRO | DBSP incremental views | https://docs.feldera.com/sql/intro/ |
| F-MAT | Materialized tables and views | https://docs.feldera.com/sql/materialized/ |
| F-SUB | HTTP subscribe-to-view | https://docs.feldera.com/api/subscribe-to-view/ |
| F-CONN | Connector snapshot and queues | https://docs.feldera.com/connectors/ |
| F-FT | Checkpoints and fault tolerance | https://docs.feldera.com/pipelines/fault-tolerance/ |
| F-ING | Ingress completion token | https://docs.feldera.com/api/insert-data/ |
| F-COMP | Completion-token status | https://docs.feldera.com/api/check-completion-status/ |
| F-REST | HTTP snapshot and stream tutorial | https://docs.feldera.com/tutorials/rest_api/ |
| M-SUB | `SUBSCRIBE` reference | https://materialize.com/docs/sql/subscribe/ |
| M-DUR | Durable subscriptions | https://materialize.com/docs/transform-data/patterns/durable-subscriptions/ |
| M-DEC | `DECLARE` cursor | https://materialize.com/docs/sql/declare/ |
| M-FET | `FETCH` | https://materialize.com/docs/sql/fetch/ |

Eta Crux context is the delivery baseline, the Incremental sibling report, and the typed-projection map. Those files are local project sources.

## React `useSyncExternalStore`

### Coherent snapshot

Documented in R-DOC and R-RFC.

The hook returns one snapshot from `getSnapshot`. Repeated calls must return the same value while the store is unchanged. Comparison uses `Object.is`. The snapshot must be immutable. A mutable store must return a new cached snapshot after a change.

Documented in R-DOC, caveats.

If the store mutates during a non-blocking Transition, React falls back to a blocking update. React calls `getSnapshot` again before it applies DOM changes. A different value restarts the update as blocking. The restart makes every on-screen component reflect the same store version.

Source in R-HOOKS.

A concurrent render that is not on a blocking lane records a store consistency check. The check stores the rendered snapshot and `getSnapshot`. React walks those checks before commit. A mutation discards the tree and re-renders.

Inference. One store snapshot is coherent across components that use this hook. Two independent stores can still disagree.

### Transaction batching

Documented in R-RFC.

A store change always renders synchronously. A React state Transition that reads this hook never replaces visible UI with a fallback.

Source in R-SHIM.

The shim has no cross-renderer batch API. The comment says the consumer must wrap the subscription event with `unstable_batchedUpdates`. The native Fiber path uses `SyncLane` for store re-renders.

Inference. React batches its own re-render. The store has no transaction API. Several listener callbacks can run in one `emitChange` loop.

### Dynamic removal

Documented in R-DOC.

`subscribe` must return a cleanup function. React calls that function to dispose the subscription. A new `subscribe` function on re-render disposes the old subscription and subscribes again.

Source in R-HOOKS, `subscribeToStore`.

The effect return value is the cleanup from `subscribe`.

### Missed-wake prevention

Source in R-HOOKS and R-SHIM.

React reads `getSnapshot` during render. After subscribe, `updateStoreInstance` and the shim `useEffect` call `checkIfSnapshotChanged`. The check compares the cached snapshot with a fresh `getSnapshot`. A change forces a re-render. The store callback also runs that check.

Inference. The first pull, the subscribe, and the re-read close the attachment race. Later notices do not carry a value. Each notice causes another pull.

### Attachment replay

Documented in R-DOC.

The first render returns the current snapshot. `getServerSnapshot` supplies the server and hydration snapshot. The server snapshot must match the client hydration snapshot.

Source in R-HOOKS.

Hydration calls `getServerSnapshot`. A missing function throws. Later client updates use `getSnapshot`.

Inference. Attachment starts with a current-snapshot pull. Subscribe then re-read closes the race. The subscribe callback does not replay a log.

### Reconnection

Documented in R-DOC and R-RFC.

`getServerSnapshot` covers server render and hydration. The pages do not describe a network resume cursor.

Inference. A later mount is a new subscription. It pulls the current snapshot again.

### Order

Documented in R-DOC.

React re-renders the component that subscribed. The store example notifies listeners in array order.

Inference. Cross-component order is React tree order after a sync store update. The hook does not document a law for listener order.

### Backpressure

Source in R-HOOKS, `subscribeToStore`.

A store change schedules `forceStoreRerender` on `SyncLane`. There is no queue bound and no drop policy.

Inference. The producer does not wait. A slow render delays the next frame. It does not apply transport backpressure.

### Latest-value ownership

Documented in R-DOC.

`getSnapshot` reads the store. The hook returns that snapshot for render.

Source in R-HOOKS.

`StoreInstance.value` caches the last snapshot that React used. The store remains the owner of the live value.

Inference. React caches a render snapshot. The driver analog is `Driver.latest_committed_output`. The hook cache is not a second writer.

### Matrix: React `useSyncExternalStore`

| Field | Fact | Class |
|---|---|---|
| Coherent snapshot | One immutable snapshot per store. Concurrent mutation forces a blocking re-render | Documented R-DOC. Source R-HOOKS |
| Transaction batching | Store updates are synchronous. The store has no commit API | Documented R-RFC |
| Dynamic removal | `subscribe` returns cleanup. A new `subscribe` replaces the old one | Documented R-DOC |
| Missed-wake prevention | First pull, then subscribe, then re-read. Later notices cause pulls | Source R-HOOKS, R-SHIM |
| Attachment replay | First render pulls the current snapshot. Hydration uses `getServerSnapshot` | Documented R-DOC |
| Reconnection | New mount pulls again. No resume cursor | Inference from R-DOC |
| Order | Sync re-render of the subscriber. No documented cross-listener law | Inference |
| Backpressure | None. Sync re-render on `SyncLane` | Source R-HOOKS |
| Latest-value owner | The external store. React caches the last rendered snapshot | Documented R-DOC. Source R-HOOKS |
| Transferable | Notice-then-pull for later changes. Initial current-snapshot pull. Post-subscribe re-read | Inference |
| Non-transferable | Missing acknowledgment. Sync UI re-render as delivery. Hydration as session replace | Inference |

## SolidJS signals

### Coherent snapshot

Documented in S-SIG and S-MEMO.

A signal getter returns the current value. A memo caches its last result. Default equality is strict `===`. A custom `equals` function can suppress a downstream update. `equals: false` always notifies.

Source in S-SRC.

`createSignal` stores `value` on the signal node. `writeSignal` writes the new value, then marks observers `STALE`. The live docs mark `equals` default as `false`. The source default is `equalFn`, which is `===`. This report uses the source.

Inference. One signal is a coherent latest value. Two signals have no shared snapshot. A read of two signals without `batch` can observe an intermediate pair.

### Transaction batching

Documented in S-BATCH.

`batch` defers downstream computations until the function returns. Nested batches form one larger batch. A read of a stale memo inside the batch updates that memo on demand. An async `batch` function covers only updates before the first `await`. Solid also batches inside `createEffect`, `onMount`, and store setters.

Source in S-SRC, `batch` and `writeSignal`.

`batch` runs `runUpdates`. `writeSignal` pushes pure observers onto `Updates` and user effects onto `Effects`.

Documented in S-EFF.

Several dependency changes in one batch run an effect once.

### Dynamic removal

Documented in S-CLEAN.

When the owner is disposed, `onCleanup` runs. When the scope re-executes, the previous cleanup runs first. A component unmount disposes its owner.

Source in S-SRC, `createRoot`.

`createRoot` returns a dispose function. Dispose cleans the root owner.

Inference. Disposal is owner-scoped. There is no per-projection wire close.

### Missed-wake prevention

Documented in S-EFF and S-SIG.

The first effect run reads current values and registers observers. Later writes mark those observers stale.

Source in S-SRC, `writeSignal`.

A write with no observers stores the value and notifies nobody. The next getter still returns the new value.

Inference. A late subscriber does not miss the current value. It misses only historical intermediate values. There is no subscribe-then-re-read fence like React.

### Attachment replay

Documented in S-MEMO and S-EFF.

A memo runs immediately to compute the first value. An effect first run is scheduled after render. That first run sees the current value.

Inference. Attachment replay is a pull of the current signal. There is no snapshot message.

### Reconnection

Documented in S-EFF.

Effects do not run during SSR. They also do not run during initial client hydration.

Inference. There is no resume cursor. A new owner is a new subscription.

### Order

Documented in S-EFF.

Effect order among several effects is not guaranteed. Effects run after pure computations in the same update cycle.

Source in S-SRC.

When `writeSignal` marks observers stale, it walks `node.observers` in array index order.

Inference. Mark order is source-array order. Run order of user effects is not a documented law.

### Backpressure

Source in S-SRC.

Observer notification is synchronous graph work. There is no queue bound.

Inference. A slow effect delays later work in the same flush. It does not apply transport backpressure.

### Latest-value ownership

Documented in S-SIG.

The setter writes the signal. The getter reads it.

Source in S-SRC.

The signal node owns `value`. Observers do not copy a second latest slot.

Inference. Each signal is an independent latest-value owner. That shape matches independent streams, not one driver output.

### Matrix: SolidJS signals

| Field | Fact | Class |
|---|---|---|
| Coherent snapshot | Per signal. No atomic multi-signal snapshot | Documented S-SIG. Inference |
| Transaction batching | `batch` coalesces downstream runs. Mid-batch reads refresh on demand | Documented S-BATCH |
| Dynamic removal | Owner dispose and `onCleanup` | Documented S-CLEAN |
| Missed-wake prevention | Late read sees the current value. No post-subscribe fence | Source S-SRC |
| Attachment replay | Memo runs now. Effect first run reads the current value | Documented S-MEMO, S-EFF |
| Reconnection | New owner. No resume cursor | Inference |
| Order | Effect order not guaranteed | Documented S-EFF |
| Backpressure | None | Source S-SRC |
| Latest-value owner | The signal node | Source S-SRC |
| Transferable | Equality cutoff inside a projection. Explicit owner dispose. Batch as one flush | Inference |
| Non-transferable | Independent signals as transport. Unguaranteed effect order. Missing acknowledgment | Inference |

## Feldera DBSP incremental views

### Coherent snapshot

Documented in F-INTRO.

One input change can touch several tables. That change produces one corresponding output change for every output view. DBSP has no concurrency control and no SQL transaction. It is a stream engine. Each input change produces one output change.

Documented in F-MAT.

A materialized view retains a complete snapshot. Ad-hoc `SELECT` reads that snapshot and is not incremental.

Documented in F-SUB and F-REST.

HTTP subscribe can set `send_snapshot=true`. The first chunks have `snapshot: true`. Later chunks are incremental deltas with `snapshot: false`. The tutorial shows one change as a delete plus an insert in one `json_data` batch.

Inference. The coherent unit is one input change, or one materialized snapshot. It is not a multi-subscriber commit token.

### Transaction batching

Documented in F-CONN.

The pipeline sends one output batch for each processed input batch by default. An output buffer can hold updates for a time bound or a record bound, then flush one batch. `max_batch_size` caps records per input batch.

Documented in F-INTRO.

DBSP does not provide transactions.

Inference. Batching is engine scheduling. It is not an application transaction.

### Dynamic removal

Documented in F-SUB.

The stream continues until the client closes the connection or the pipeline stops.

Inference. Close is connection close. There is no per-projection dispose inside one session.

### Missed-wake prevention

Documented in F-SUB and F-REST.

`send_snapshot=true` sends the cached view first. Default `send_snapshot` is `false`. When nothing changed, the tutorial stream still sends empty messages.

Inference. A subscriber that omits the snapshot can miss the current view. Empty messages are liveness, not completeness.

### Attachment replay

Documented in F-SUB.

`send_snapshot=true` works on a paused pipeline. The snapshot comes from the latest cached view. The pipeline does not need to be running.

Documented in F-CONN.

An output connector `send_snapshot` emits the full materialized view the first time it runs. Resume from a checkpoint does not send that snapshot again. A connector config change causes a fresh snapshot on the next start.

Inference. HTTP subscribe replay is opt-in. Connector replay is once per config, not once per attach.

### Reconnection

Documented in F-FT.

A checkpoint is a consistent snapshot of computation and connectors. Resume restarts each connector at its saved point. At-least-once fault tolerance can emit output again. Exactly-once fault tolerance journals input and suppresses duplicate output. These modes are enterprise-only.

Documented in F-COMP.

A completion token from a previous pipeline incarnation returns `410`. The token is not valid after checkpoint resume.

Documented in F-SUB.

HTTP subscribe has no `AS OF` cursor.

Inference. Pipeline resume is not the same as a client reconnect. A new HTTP subscribe is a new stream.

### Order

Documented in F-SUB.

Each chunk has a `sequence_number`.

Documented in F-INTRO.

Each input change has one matching output change for all views.

Inference. Sequence numbers order chunks on one subscribe stream. They are not a serialized-session law.

### Backpressure

Documented in F-SUB.

`backpressure=true` waits for the client and can block the pipeline. Default `backpressure` is `false`. When the client is slow, that default drops chunks.

Documented in F-CONN.

`max_queued_records` and `max_queued_bytes` pause input or circuit execution after the bound. The values are approximate.

Inference. Default HTTP subscribe prefers pipeline progress over lossless delivery. That conflicts with Eta Crux capacity laws.

### Latest-value ownership

Documented in F-MAT.

The pipeline retains a complete snapshot only for materialized relations. Other views keep only incremental state.

Documented in F-ING and F-COMP.

Ingress returns a completion token. `/completion_status` reports that associated inputs are processed. The token is not a per-subscriber delivery acknowledgment.

Inference. The pipeline owns the materialized snapshot. A subscribe client owns its reconstructed copy. The driver analog is the pipeline, not the HTTP client.

### Matrix: Feldera DBSP

| Field | Fact | Class |
|---|---|---|
| Coherent snapshot | One input change to one output change across views. Materialized `SELECT` is a complete snapshot | Documented F-INTRO, F-MAT |
| Transaction batching | Per input batch, plus optional output buffer. No SQL transaction | Documented F-CONN, F-INTRO |
| Dynamic removal | Client close or pipeline stop | Documented F-SUB |
| Missed-wake prevention | Only if `send_snapshot=true`. Default is no snapshot | Documented F-SUB |
| Attachment replay | Opt-in HTTP snapshot. Connector snapshot once per config | Documented F-SUB, F-CONN |
| Reconnection | Checkpoint resume for connectors. HTTP subscribe has no cursor | Documented F-FT, F-SUB |
| Order | Per-stream `sequence_number`. One output change per input change | Documented F-SUB, F-INTRO |
| Backpressure | Default HTTP drops. Optional block. Queue bounds pause the circuit | Documented F-SUB, F-CONN |
| Latest-value owner | Materialized view inside the pipeline | Documented F-MAT |
| Transferable | One change across many views. Opt-in first snapshot. Completeness of input processing | Inference |
| Non-transferable | Default drop. Missing subscriber ack. Diff stream as the root frame | Inference |

## Materialize `SUBSCRIBE`

### Coherent snapshot

Documented in M-SUB.

`SUBSCRIBE` is a `SELECT` over time. It emits inserts and deletes with `mz_timestamp` and `mz_diff`. Default `SNAPSHOT` is `true`. The snapshot is a series of updates at the `AS OF` timestamp. Those updates describe the full current contents. Later rows are later changes.

Timestamps never decrease on one subscribe.

Documented in M-SUB, `PROGRESS`.

A progress row with `mz_progressed=true` means no more rows exist at a strictly smaller timestamp. The first row is a progress row at the `AS OF` timestamp. A later data row at timestamp `T` implies that timestamp `T-1` is complete.

Inference. The coherent unit is one timestamp. The snapshot is a complete relation at `AS OF`. Later timestamps are incremental.

### Transaction batching

Documented in M-SUB.

Several updates can share one timestamp. `WITHIN TIMESTAMP ORDER BY` sorts rows inside one timestamp. `UP TO` stops the subscribe at an exclusive upper timestamp.

Inference. A timestamp is the batch. It is not an application transaction.

### Dynamic removal

Documented in M-SUB.

`SUBSCRIBE` runs until cancel, session end, `UP TO`, or a constant view ends.

Documented in M-DEC.

`DECLARE` creates a cursor for `SELECT` or `SUBSCRIBE`. The cursor lives in a transaction.

Inference. Dispose is cancel, `COMMIT`, or session end.

### Missed-wake prevention

Documented in M-SUB, `SNAPSHOT`.

Default `SUBSCRIBE` is one operation. It emits the current relation at `AS OF`, then live updates on the same stream. The client does not run a separate `SELECT` and a later subscribe.

Inference. That single stream is the gap-free attachment contract. `PROGRESS` does not supply this contract.

### Prefix completeness

Documented in M-SUB, `PROGRESS`.

Without progress rows, a stall and a quiet interval are indistinguishable. A progress row marks a complete timestamp prefix. The first row is a progress row at the `AS OF` timestamp.

Documented in M-DUR.

The client buffers rows until a progress message. Then the prefix is complete.

Inference. `PROGRESS` communicates prefix completeness. It distinguishes a quiet interval from a stalled stream. It does not prevent a missed wake.

### Attachment replay

Documented in M-SUB, `SNAPSHOT`.

Default snapshot emits the current relation at `AS OF`. Live updates then continue on the same `SUBSCRIBE`. `SNAPSHOT = false` omits that snapshot. Materialize can still read snapshot data to compute a derived `SELECT`. A direct subscribe to a materialized collection can skip that fetch.

### Reconnection

Documented in M-DUR.

`RETAIN HISTORY` keeps past versions. The client stores the last progress `mz_timestamp`. Resume uses `SNAPSHOT false` and `AS OF last_progress - 1`. An `AS OF` earlier than retained history is an error. History cleanup can lag, so older history can remain for a time.

Documented in M-DUR, idempotency note.

The client must persist the progress timestamp and the buffered rows in one transaction. Persist-before-process can drop rows. Process-before-persist can duplicate rows.

Inference. Reconnect is application-owned. Materialize supplies history and `AS OF`. It does not send a subscriber acknowledgment.

### Order

Documented in M-SUB.

`mz_timestamp` is never less than a previous timestamp on the same subscribe. Receipt of timestamp `2` implies timestamp `1` is complete.

### Backpressure

Documented in M-SUB, M-DEC, and M-FET.

Many drivers buffer until query end. `SUBSCRIBE` can run forever, so those drivers never return. The documented path is `BEGIN`, `DECLARE`, then `FETCH`. `FETCH` limits row count. `TIMEOUT` limits wait. `TIMEOUT '0s'` returns only rows that are ready now.

Inference. Backpressure is pull. The client decides how many rows to take. The protocol does not drop.

### Latest-value ownership

Documented in M-SUB.

`SELECT` computes a relation at one time. `SUBSCRIBE` streams how that relation changes. The object under subscribe holds the current contents.

Documented in M-DUR.

The application keeps the last progress timestamp and its own buffered rows.

Inference. Materialize owns the relation. The client owns the reconstructed copy. Eta Crux must keep latest committed output on the driver, not on the shell.

### Matrix: Materialize `SUBSCRIBE`

| Field | Fact | Class |
|---|---|---|
| Coherent snapshot | Full relation at `AS OF`, then per-timestamp diffs | Documented M-SUB |
| Transaction batching | One timestamp is one complete prefix | Documented M-SUB |
| Dynamic removal | Cancel, session end, or `UP TO` | Documented M-SUB |
| Missed-wake prevention | One `SUBSCRIBE` with default snapshot, then live updates | Documented M-SUB |
| Attachment replay | Default snapshot at `AS OF` on the same subscribe | Documented M-SUB |
| Reconnection | `RETAIN HISTORY` plus `AS OF`. Client stores progress | Documented M-DUR |
| Order | Nondecreasing `mz_timestamp` on one subscribe | Documented M-SUB |
| Backpressure | Cursor `FETCH` pull. No documented drop | Documented M-FET |
| Latest-value owner | The subscribed object. Client rebuilds a copy | Documented M-SUB, M-DUR |
| Transferable | One subscribe for snapshot and live updates. Progress as prefix completeness. Pull backpressure | Inference |
| Non-transferable | Client-rebuilt diffs as the root frame. No delivery token. Application-owned resume | Inference |

## Cross-system comparison

| Axis | React hook | SolidJS | Feldera DBSP | Materialize `SUBSCRIBE` |
|---|---|---|---|---|
| Coherent snapshot | One store snapshot. Concurrent mutation forces blocking render | Per signal only | One input change across all views. Materialized `SELECT` | One timestamp. Snapshot at `AS OF` |
| Transaction batching | Sync store render. No store commit | `batch` defers observers | Input batch plus output buffer | Timestamp batch |
| Dynamic removal | Unsubscribe cleanup | Owner dispose | Connection close | Cancel, `UP TO`, or session end |
| Missed-wake prevention | First pull, subscribe, then re-read | Late read sees current value | Only with `send_snapshot` | One `SUBSCRIBE` with default snapshot then live updates |
| Attachment replay | Pull current snapshot, then subscribe | Pull current signal | Opt-in snapshot | Default snapshot on the same subscribe |
| Reconnection | New mount. Hydration only | New owner | Checkpoint for connectors. No HTTP cursor | `AS OF` plus retained history |
| Order | Subscriber re-render. No listener law | Effect order not guaranteed | Stream `sequence_number` | Nondecreasing timestamps |
| Backpressure | None | None | Default drop. Optional block | `FETCH` pull |
| Latest-value owner | External store | Signal node | Materialized view in the pipeline | Subscribed object. Client copy |

## What Eta Crux can transfer

Eta Crux owns stabilization, atomic commit, delivery order, serialized sessions, and delivery acknowledgment. The driver is the only transport writer. Current Eta Crux already delivers one complete committed output.

These facts can inform later design.

1. React later changes are notice-then-pull. A store notice does not carry the value. The next `getSnapshot` pull does.
2. React attachment pulls the current snapshot, subscribes, then re-reads. That re-read closes the attachment race.
3. One batch or one timestamp coalesces many internal writes into one publication.
4. First attach can replay the current snapshot on the same stream as later updates. A later attach can pull the current snapshot again.
5. Materialize `PROGRESS` marks prefix completeness. It is not a missed-wake fence.
6. Pull backpressure (`FETCH`) bounds the consumer without a drop.
7. Dispose is explicit unsubscribe, owner dispose, cancel, or session end.
8. Equality cutoff belongs inside a projection, as in Solid `equals` and Incremental cutoff.
9. One input change can publish one coherent output across many projections, as in Feldera.
10. Resume can start from a retained time. The resume protocol stays outside Eta Crux.

## What Eta Crux cannot transfer

1. Missing acknowledgment. None of the four systems has `Output_result`. Eta Crux requires a delivery token (`T-05`, `D-02`).
2. Default drop. Feldera HTTP `backpressure=false` drops chunks. Eta Crux forbids loss at the accepted capacity surface.
3. Independent streams without one commit. Solid signals and two React stores have no shared snapshot. Eta Crux commits one root frame (`T-04`).
4. Client-rebuilt diffs as the committed root output. Materialize and Feldera streams send inserts and deletes. Current Eta Crux publishes one complete output per advancement (`T-03`).
5. Unguaranteed observer order. Solid documents no effect order. Eta Crux owns delivery order (`W-02`).
6. Store or signal writes from many holders. Eta Crux keeps the driver as the only transport writer.
7. Hydration or checkpoint resume as serialized session replace. Eta Crux `Serialized_session.replace` closes the old session and redelivers the current output (`W-08`, `W-09`).
8. Connector snapshot-once across resume. Feldera does not re-send `send_snapshot` after checkpoint. Eta Crux replacement forces current-output delivery.
9. Application-owned reconstruction. Adapters reconcile. They do not own latest committed output (`O-01`, `D-07`).
10. Sync UI effects as delivery. React re-render and Solid effects are not transport writes.

## Comparison with the map and the baseline

The map requires Eta Crux to own stabilization, atomic commit, delivery order, serialized sessions, and delivery acknowledgment. The driver stays the only transport writer ([`map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) lines 16-17).

| Map or baseline requirement | Prior-art fact | Comparison |
|---|---|---|
| One complete root output per commit (`T-03`) | Materialize and Feldera send diffs after a snapshot. React and Solid send one current value | Diff streams conflict with complete-output delivery. Snapshot pull matches `O-01` |
| Atomic commit (`T-04`) | Feldera pairs one input change with one output change. Solid does not | Multi-projection publication needs one commit, not independent signals |
| Latest committed output pull (`O-01`, `D-07`) | React `getSnapshot`, Solid getter, Feldera materialized `SELECT` | Same shape. The driver must remain the owner |
| Delivery after commit (`O-02`) | React notice after store write. Materialize rows after `AS OF` | Close. None of the four has a commit-then-deliver token |
| Delivery acknowledgment | Feldera completion token is input processing. Others have none | Gap. Keep `Output_result` |
| Delivery order | Materialize timestamps. Feldera sequence numbers. Solid none | Transfer timestamp or sequence only inside one driver write |
| Session replacement with no request replay (`W-09`) | React remount pulls current snapshot. Feldera connector snapshot is once | Replay the current output. Do not replay a log |
| Cutoff never suppresses committed delivery (`C-05`) | Solid `equals` and memo cutoff suppress observers | Cutoff stays inside the graph |
| Capacity without loss (`A-09`) | Feldera default HTTP drop. Materialize `FETCH` pull | Pull bounds fit. Drop does not |

The map lists four designs for later comparison ([`map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) lines 20-24).

### Complete-output delivery

React `getSnapshot`, Solid getters, and Feldera materialized `SELECT` are complete current values. This is the closest match to current Eta Crux. Materialize snapshot rows at `AS OF` are also a complete relation. Later diffs are a different design.

### Notification followed by pull

React is the cleanest notice-then-pull contract for later changes. `subscribe` is the notice. `getSnapshot` is the pull. Attachment adds an initial current-snapshot pull and a post-subscribe re-read.

Incremental `Observer.on_update_exn` plus `value_exn` has the same later-change shape in the sibling report. Materialize `PROGRESS` is a prefix-completeness notice. The data rows still carry diffs. One `SUBSCRIBE` with its default snapshot already carries the later updates.

If Eta Crux uses notice-then-pull, the pull owner must be `Driver.latest_committed_output`.

### Independent streams

Solid signals and Feldera per-view HTTP subscribe are independent streams. They break one atomic observation unless a higher commit exists. Feldera has that commit at the input-change boundary. Solid does not. Independent transport streams also break serialized session order.

### Application effects

Solid `createEffect` and React re-render are application effects. They are not delivery. Application effects as transport make the driver not the only writer. The map forbids that.

The Incremental sibling report already maps stabilize-then-publish onto these four designs. This report does not change that mapping.

The baseline report states that no inspected source selects a next public interface. This report makes no selection either.

## Remaining uncertainty

1. react.dev and Materialize and Feldera live pages have no published commit pin. This report cites the live URLs and the React `v19.2.8` tag.
2. Solid live docs mark `createSignal` `equals` default as `false`. Source default is `===`. Later design must use the source.
3. Solid 2.0 beta changes batching to a microtask flush. This report does not treat 2.0 as released authority.
4. Feldera completion-token pages describe input processing. Python SDK text also mentions sink writes. The API page is the cited contract.
5. Feldera checkpoint and exactly-once modes are enterprise-only. Community HTTP subscribe still has the drop default.
6. This report did not read every React, Solid, Feldera, or Materialize test.
7. Materialize `RETAIN HISTORY` is private preview. Resume via `AS OF` depends on that feature.
8. Cross-listener React order is example order, not a documented law.

## Self-check

Mode: pragmatic Simplified Technical English. Text class: descriptive.

Chosen nouns: snapshot, subscription, commit, delivery, observer, value, driver. Chosen verbs: publish, subscribe, replay, dispose, retain.

No procedure steps. No `should`, `would`, `may`, `might`, or `could` in report prose. No semicolon in report prose.

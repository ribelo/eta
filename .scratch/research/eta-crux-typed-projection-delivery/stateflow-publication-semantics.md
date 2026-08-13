# StateFlow publication semantics

Ticket: [`docs/wayfinder/eta-crux-typed-projection-delivery/issues/03-stateflow-publication-semantics.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/issues/03-stateflow-publication-semantics.md)

## Question

Which Kotlin `StateFlow` semantics can inform Eta Crux typed projection delivery?

This report records publication contracts. It does not select a public interface.

## Answer

`StateFlow` is a hot flow with one current value. It replays that value to each new collector. It conflates updates with `Any.equals`.

The producer never suspends because of a slow collector. A slow collector skips intermediate values. A collector checks cancellation before each emission.

Independent state flows do not give one atomic observation of several changed values. `combine` derives a flow from the latest values of its inputs. It does not create a shared commit point.

Eta Crux can take latest-value retention, replay of the current value, equality suppression of equal updates, and collector cancellation checks.

Eta Crux cannot take missing acknowledgment, missing failure, unowned writers, conflation of a committed root output, or multi-flow delivery without one atomic commit.

## Method

Primary sources only.

| Source | Role |
|---|---|
| kotlinlang.org API pages, kotlinx.coroutines 1.11.0 | Official contracts for `StateFlow`, `MutableStateFlow`, `SharedFlow`, and `combine` |
| kotlinx.coroutines master source, commit `3eadf938` | `StateFlowImpl`, collector slots, `combineInternal` |
| kotlinlang.org guide pages | Official `Flows` and `Flow operators` guides |
| Local Eta Crux files | Map constraints, baseline report, semantic laws, and `CONTEXT.md` terms |

Classification:

| Class | Meaning |
|---|---|
| Documented | Official KDoc or guide text |
| Source | Current implementation behavior |
| Inference | Reading that this report adds |

This report did not run Kotlin tests.

## Source revisions

Facts captured on 2026-08-13.

| Source | Revision |
|---|---|
| kotlinx.coroutines latest release | 1.11.0, tag `8564f65764d3d05893cec026c6e94250e2b23874`, published 2026-05-08 |
| kotlinx.coroutines master | `3eadf938b1506351bffd7c015445d08faf1c4315`, committed 2026-08-10 |
| kotlinlang.org API pages | Library version marker 1.11.0 |
| kotlinlang.org guide pages | Generated from master `docs/topics/` |

The cited `StateFlow.kt`, `SharedFlow.kt`, `AbstractSharedFlow.kt`, `Zip.kt`, and `Combine.kt` files are identical between master `3eadf938` and the 1.11.0 tag. The guide files differ between the tag and master. This report cites master for the guide text because the live guide pages match master.

Stable file URLs use master commit `3eadf938b1506351bffd7c015445d08faf1c4315`.

| ID | File and role | URL |
|---|---|---|
| SF-KDOC | `kotlinx-coroutines-core/common/src/flow/StateFlow.kt` — `StateFlow` public KDoc (lines 10-140) | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/StateFlow.kt |
| MSF-KDOC | `kotlinx-coroutines-core/common/src/flow/StateFlow.kt` — `MutableStateFlow` public KDoc and update functions (lines 142-237) | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/StateFlow.kt |
| SF-IMPL | `kotlinx-coroutines-core/common/src/flow/StateFlow.kt` — `StateFlowSlot` and `StateFlowImpl` implementation (lines 239-432) | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/StateFlow.kt |
| SH-KDOC | `kotlinx-coroutines-core/common/src/flow/SharedFlow.kt` — `SharedFlow` and `MutableSharedFlow` public KDoc (lines 10-259) | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/SharedFlow.kt |
| ASF | `kotlinx-coroutines-core/common/src/flow/internal/AbstractSharedFlow.kt` — slot allocation and free implementation (lines 1-96) | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/internal/AbstractSharedFlow.kt |
| COMBINE-KDOC | `kotlinx-coroutines-core/common/src/flow/operators/Zip.kt` — `combine` public KDoc | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/operators/Zip.kt |
| COMBINE-IMPL | `kotlinx-coroutines-core/common/src/flow/internal/Combine.kt` — `combineInternal` implementation (lines 12-80) | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/kotlinx-coroutines-core/common/src/flow/internal/Combine.kt |
| GUIDE-FLOW | `docs/topics/coroutines-flow.md` | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/docs/topics/coroutines-flow.md |
| GUIDE-OPS | `docs/topics/coroutines-flow-operators.md` | https://github.com/Kotlin/kotlinx.coroutines/blob/3eadf938b1506351bffd7c015445d08faf1c4315/docs/topics/coroutines-flow-operators.md |
| API-SF | StateFlow API page | https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.flow/-state-flow/ |
| API-COMBINE | combine API page | https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.flow/combine.html |
| GUIDE-FLOW-HTML | Flows guide page | https://kotlinlang.org/docs/coroutines-flow.html |
| GUIDE-OPS-HTML | Flow operators guide page | https://kotlinlang.org/docs/coroutines-flow-operators.html |

Eta Crux context is the delivery baseline report, the typed-projection map, and the semantic laws. Those files are local project sources.

## Current-value retention

Documented in SF-KDOC and API-SF.

`StateFlow` represents a read-only state with one updatable data `value`. The flow is hot because its active instance exists independently of the presence of collectors. `StateFlow.value` returns the current value at any time. A call to `Flow.collect` on a state flow never completes normally. An active collector is called a subscriber.

Documented in SF-KDOC, section `State flow is a shared flow`.

A state flow always has an initial value. It replays one most recent value to new subscribers. It does not buffer any more values, but keeps the last emitted one. It does not support `resetReplayCache`.

Source in SF-IMPL.

`StateFlowImpl._state` is an atomic field that holds the value. The `value` getter reads that field. `replayCache` returns `listOf(value)`.

### Matrix: current-value retention

| Field | Fact | Class |
|---|---|---|
| Current-value retention | One current value at all times, readable through `value` | Documented, SF-KDOC `value` |
| Replay cache | `listOf(value)`. Exactly one value | Source, SF-IMPL |
| Removal or disposal | None. The flow never completes | Documented, SF-KDOC |
| Latest-value owner | The flow instance stores the value in `_state`. The `MutableStateFlow` holder writes it | Source, SF-IMPL |
| Transferable | Latest committed output as a pull boundary | Inference. Matches `Driver.latest_committed_output` |
| Non-transferable | A value that exists before the first commit | Inference. Conflicts with `D-07` |

## Equality-based conflation

Documented in SF-KDOC, section `Strong equality-based conflation`.

Values are conflated with `Any.equals`, in a similar way to `distinctUntilChanged`. Conflation suppresses emission when the new value equals the previously emitted one. State flow behavior with classes that violate the `Any.equals` contract is unspecified.

Documented in MSF-KDOC.

Setting a value that is equal to the previous one does nothing. `compareAndSet` returns `true` when both `expect` and `update` equal the current value. It does not change the stored reference in that case.

Documented in GUIDE-FLOW and GUIDE-FLOW-HTML.

A `StateFlow` emits an update only when the new value differs from the current value.

Source in SF-IMPL, `updateState` and `collect`.

`updateState` returns `true` without a write when `oldState == newState`. The `collect` loop compares the new state with the last state that the collector emitted. It skips equal values.

### Matrix: equality conflation

| Field | Fact | Class |
|---|---|---|
| Conflation key | `Any.equals`, like `distinctUntilChanged` | Documented, SF-KDOC |
| Equal-value write | Setting an equal value does nothing | Documented, MSF-KDOC |
| Equal-value emission | Collectors do not receive equal values | Documented, SF-KDOC and GUIDE-FLOW |
| Classes that violate `equals` | Behavior is unspecified | Documented, SF-KDOC |
| Transferable | Application-owned equality on derived projections | Inference |
| Non-transferable | Suppression of a committed root output | Inference. Conflicts with `T-03` and `C-05` |

## Replay to new collectors

Documented in SF-KDOC.

A state flow replays one most recent value to new subscribers.

Documented in GUIDE-FLOW and GUIDE-FLOW-HTML.

New subscribers receive the current value as soon as they start collecting. They then receive new values each time the state updates.

Documented in SH-KDOC, section `Replay cache and buffer`.

Every new subscriber first gets the values from the replay cache. It then gets new emitted values.

Source in SF-IMPL, `collect`.

The loop emits the current `_state.value` on its first iteration. `allocateSlot` registers the collector before that first read. The source comment states that the loop starts by delivering the current value without waiting.

Inference. Replay size is exactly one. There is no history replay.

### Matrix: replay to new collectors

| Field | Fact | Class |
|---|---|---|
| Initial replay | The current value, immediately on subscription | Documented, GUIDE-FLOW |
| Replay size | One value | Documented, SF-KDOC |
| Removal or disposal | A canceled collector frees its slot | Source, SF-IMPL `finally` |
| Batching or coalescing | One value per replay. Equal values are skipped | Documented, SF-KDOC |
| Order | Replay precedes later updates for that collector | Source, SF-IMPL loop order |
| Backpressure | The initial emission can suspend that collector. It does not suspend the writer | Source, SF-IMPL |
| Reconnection or reactivation | A new subscription replays the current value again | Inference |
| Latest-value owner | The flow `_state` field | Source, SF-IMPL |
| Transferable | First snapshot, then later updates. A slow collector can skip distinct intermediate values | Inference |
| Non-transferable | Replay of a history log | Inference |

## Collector order

Documented in SH-KDOC and SF-KDOC.

A shared flow shares emitted values among all its collectors in a broadcast fashion. Updates to a state flow value are always conflated. A slow collector skips fast updates. It always collects the most recently emitted value. No official text documents an order among collectors.

Source in SF-IMPL, `updateState` and `collect`, plus ASF.

`updateState` makes every active slot pending in array order. The loop is `curSlots?.forEach { it?.makePending() }`. `allocateSlot` assigns slots in array order from a free-slot scan. `makePending` resumes a suspended continuation or sets a pending flag. Each collector then runs `collector.emit` in its own coroutine and dispatcher. A slow collector can skip distinct intermediate values. It always collects the latest value. Actual delivery order across collectors depends on scheduling.

Inference. Slot iteration order is source behavior. It is not a public collector-order law. A pending mark is not a delivery guarantee for a slow collector.

### Matrix: collector order

| Field | Fact | Class |
|---|---|---|
| Broadcast | `updateState` makes every active collector slot pending | Source, SF-IMPL |
| Slow collector | Can skip distinct intermediate values. It always collects the latest value | Documented, SF-KDOC |
| Order among collectors | None documented | Documented absence |
| Source iteration | Slot array order, then per-collector resumption | Source, SF-IMPL and ASF |
| Transferable | A wake for every active collector | Inference |
| Non-transferable | Slot array order as a delivery law | Inference |

## Producer backpressure

Documented in SF-KDOC.

Updates to the value are always conflated. A slow collector skips fast updates. It always collects the most recently emitted value.

Documented in SH-KDOC.

When an overflow strategy other than `SUSPEND` is configured, emissions to the shared flow never suspend. SF-KDOC states that a state flow behaves identically to `MutableSharedFlow(replay = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)` with `distinctUntilChanged` applied.

Source in SF-IMPL.

`emit` assigns `this.value` and never suspends. `tryEmit` assigns `this.value` and always returns `true`.

Inference. The producer never waits for a collector. There is no acknowledgment.

### Matrix: producer backpressure

| Field | Fact | Class |
|---|---|---|
| Producer suspension | None for a state flow writer | Source, SF-IMPL `emit` and `tryEmit` |
| Slow collector effect | The collector skips fast updates | Documented, SF-KDOC |
| Buffer | No buffer beyond the last value | Documented, SF-KDOC |
| Overflow strategy | Equivalent to `DROP_OLDEST` with replay 1 | Documented, SF-KDOC |
| Transferable | A writer that never blocks on a consumer | Inference |
| Non-transferable | Missing delivery acknowledgment | Inference. Conflicts with the map token |

## Collector backpressure

Documented in SF-KDOC.

A state flow does not buffer any more values. It keeps the last emitted one. A slow collector skips fast updates.

Source in SF-IMPL, `collect`.

The loop reads the current `_state.value` after each wait. The source comment states that this read gives the best conflation of stale values. `slot.takePending()` handles the fast path. `slot.awaitPending()` suspends until the slot becomes pending.

Inference. Each collector keeps one pending bit. A slow collector can skip distinct intermediate values. It always collects the latest value.

### Matrix: collector backpressure

| Field | Fact | Class |
|---|---|---|
| Collector buffer | None. One pending bit per slot | Source, SF-IMPL slot states |
| Slow collector | Can skip distinct intermediate values. It always collects the latest value | Documented, SF-KDOC |
| Emitter wait | The producer never waits for this collector | Source, SF-IMPL |
| Transferable | Equality suppresses equal values. A slow collector can skip distinct intermediate values. It always collects the latest value | Inference |
| Non-transferable | A per-collector delivery queue | Inference |

## Collector cancellation

Documented in SH-KDOC.

A subscriber of a shared flow can be canceled. This usually happens when the scope of the coroutine is canceled. A subscriber to a shared flow is always cancellable. It checks for cancellation before each emission.

Source in SF-IMPL, `collect`.

The loop calls `collectorJob?.ensureActive()` before each emission. `awaitPending` uses `suspendCancellableCoroutine`. The `finally` block calls `freeSlot`.

Inference. Cancellation frees the collector slot. The flow keeps its value and its other collectors.

### Matrix: collector cancellation

| Field | Fact | Class |
|---|---|---|
| Cancellation check | Before each emission | Documented, SH-KDOC. Source, SF-IMPL |
| Cancellation path | Suspension is cancellable. Slot is freed | Source, SF-IMPL |
| Effect on the flow | None. The value and other collectors stay | Source |
| Transferable | Cancellation before each delivery | Inference |
| Non-transferable | Cancellation as a delivery acknowledgment | Inference |

## Later collection or reconnection

Documented in SF-KDOC.

A state flow never completes. A call to `Flow.collect` on a state flow never completes normally.

Documented in SH-KDOC, `collect`.

By the time the first suspension happens, `collect` is already subscribed to the shared flow. It is then eligible for receiving emissions.

Source in SF-IMPL.

Each `collect` call allocates a new slot. The loop emits the current value first. `freeSlot` releases the slot on cancellation. There is no per-collector position to resume.

Inference. A later collection is a new subscription. The flow replays the current value only. It does not replay missed updates.

### Matrix: later collection or reconnection

| Field | Fact | Class |
|---|---|---|
| Completion | Never completes normally | Documented, SF-KDOC |
| Later collection | New subscription. Current value first | Source, SF-IMPL |
| Missed updates | Not replayed. Only the current value remains | Documented, SF-KDOC |
| Session state | None. No per-collector position | Source, SF-IMPL |
| Transferable | No replay of missed history on reconnect | Inference. Aligns with `W-09` |
| Non-transferable | A resume point per collector session | Inference |

## Latest-value owner

Documented in SF-KDOC.

`StateFlow.value` returns the current value of this state flow. All methods of state flow are thread-safe. They can be invoked from concurrent coroutines without external synchronization.

Source in SF-IMPL.

`_state` holds the value. The `value` getter reads it. `replayCache` returns `listOf(value)`. Only the holder of the `MutableStateFlow` can write through the setter. `subscriptionCount` is a separate state flow that is not conflated (SH-KDOC).

Inference. The flow instance owns the latest value. Collectors do not own it. In Eta Crux terms, the driver owns the latest committed output.

### Matrix: latest-value owner

| Field | Fact | Class |
|---|---|---|
| Owner | The flow instance, through `_state` | Source, SF-IMPL |
| Writer | The holder of the `MutableStateFlow` | Source, SF-IMPL |
| Reader | Any caller of `value` or a new collector | Documented, SF-KDOC |
| Eta Crux match | `Driver.latest_committed_output` and `O-01` | Inference |

## Limits of independent flows for one atomic observation

Documented in SF-KDOC.

Each state flow is an independent hot flow with one value. Each distinct update to a value is published separately. Equality suppresses equal updates. A slow collector can skip distinct intermediate values.

Documented in API-COMBINE and COMBINE-KDOC.

`combine` generates values with the transform function. It combines the most recently emitted values by each flow. The documented example prints `1a 2a 2b 2c`. That output shows an intermediate combination between two input changes.

Documented in GUIDE-OPS and GUIDE-OPS-HTML.

`combine()` creates `uiStateFlow` from the latest values of `messagesFlow` and `themeFlow`. Updating either upstream flow emits a new `UiState` with the latest messages and theme.

Source in COMBINE-IMPL.

`combineInternal` launches one coroutine per input flow. Each update goes through a bounded channel. A child `send` suspends when the channel is full. The loop batches queued updates only when several are already present. A second value from the same flow in one epoch breaks the batch. The transform runs in the collecting coroutine, so its `emit` can suspend on the downstream collector.

Inference. A change to two flows can produce one or more combined emissions. An intermediate combination is observable. Independent flows have no shared commit point. The suspension points do not create a shared atomic commit. `combine` does not create one atomic observation. One atomic observation needs a single publication that carries all changed values together.

### Matrix: multi-flow observation

| Field | Fact | Class |
|---|---|---|
| Publication trigger | Each input value change can produce a combined emission | Documented, GUIDE-OPS |
| Initial replay | The transform runs once every input has a value | Source, COMBINE-IMPL |
| Batching | Opportunistic. Not guaranteed | Source, COMBINE-IMPL |
| Order | Emission order follows channel receipt and epochs | Source, COMBINE-IMPL |
| Backpressure | Child `send` can suspend on the full channel. Downstream transform `emit` can suspend on the collector | Source, COMBINE-IMPL |
| Atomicity | No atomic multi-flow snapshot | Inference from documented examples |
| Latest-value owner | The `latestValues` array inside `combineInternal` | Source, COMBINE-IMPL |
| Transferable | One derived value from several latest values | Inference |
| Non-transferable | `combine` as a commit boundary across flows | Inference |

## What Eta Crux can transfer

Eta Crux owns stabilization, atomic commit, delivery order, serialized sessions, and delivery acknowledgment. The driver is the only transport writer. Current Eta Crux already delivers one complete committed output.

These `StateFlow` facts can inform later design.

1. A hot latest-value slot that any reader can pull.
2. Replay of the current value to each new subscriber.
3. Equality suppresses equal values. A slow collector can skip distinct intermediate values. It always collects the latest value.
4. Equality conflation as application-owned projection or cutoff policy.
5. A writer that never suspends because of a slow consumer.
6. A collector that checks cancellation before each delivery.
7. No history replay on later collection.
8. A pending mark for every active collector with no per-collector queue. A slow collector can still skip distinct intermediate values.

## What Eta Crux cannot transfer

1. Missing acknowledgment. `StateFlow` has no delivery token. Eta Crux requires one (`T-05`).
2. Missing failure and completion. `StateFlow` never completes and cannot represent failure. Eta Crux has `Stopped` and `Failed` outcomes.
3. Unowned writes. Any holder of a `MutableStateFlow` can write. Eta Crux keeps the driver as the only transport writer.
4. Conflation of a committed output. `StateFlow` suppresses equal updates. A slow collector can skip distinct intermediate values. Eta Crux commits one complete output per advancement, including an equal output (`T-03`). `C-05` forbids cutoff suppression of committed delivery.
5. Multi-flow delivery without one atomic commit. Independent flows give no atomic observation. Eta Crux commits atomically in one root frame (`T-04`).
6. Unspecified collector order as a law. Eta Crux owns delivery order.
7. Thread-safe CAS loops as the writer protocol. Eta Crux serializes writers through one advancement queue.

## Comparison with the map and the baseline

The map requires Eta Crux to own stabilization, atomic commit, delivery order, serialized sessions, and delivery acknowledgment. The driver stays the only transport writer ([`map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) lines 16-17).

| Map or baseline requirement | `StateFlow` fact | Comparison |
|---|---|---|
| One complete root output per commit (`T-03`) | One value per state flow | `StateFlow` conflates equal and fast updates. Eta Crux must deliver each committed output |
| Atomic commit (`T-04`) | No shared commit across flows | `StateFlow` gives no multi-flow atomicity. Eta Crux publishes one complete frame |
| Latest committed output pull (`O-01`, `D-07`) | `value` pull of the current state | Same shape. `StateFlow` `value` never fails and has no terminal state |
| Delivery after commit (`O-02`) | Emission after a value write | Close. `StateFlow` has no commit-then-deliver fence |
| Delivery acknowledgment (map) | None | Gap. Eta Crux keeps the delivery token |
| Delivery order (map) | None documented | Gap. Eta Crux owns delivery order and sequence numbers (`W-02`) |
| Session replacement with no request replay (`W-09`) | Replay of exactly one current value | Compatible in spirit. Replay is one value, never a log |
| Cutoff never suppresses committed delivery (`C-05`) | Equality conflation suppresses equal values | Conflict. Conflation belongs to application cutoffs, not root delivery |

The map lists four designs for later comparison. They are complete-output delivery, notification followed by pull, independent streams, and application effects ([`map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) lines 20-24).

Complete-output delivery. `value` is a complete current state. This matches `Driver.latest_committed_output`. Replay of one value is delivery of the complete current output.

Notification followed by pull. `StateFlow` merges notice and value in one emission. There is no separate notice channel. The `value` pull sits beside the emission. A notice-then-pull design can use the latest committed output of the driver as the pull owner.

Independent streams. Each state flow is an independent stream. Independent streams give no shared atomic observation of several values. They also give no documented total delivery order across flows. The map serialized session order requires one delivery order.

Application effects. `StateFlow` is a data model, not an effect bus. The guide warns that mutating a stored object does not replace the value. Application effects as delivery make the driver not the only writer. The map forbids that.

The baseline report states that no inspected source selects a next public interface ([`current-eta-crux-delivery-baseline.md`](./current-eta-crux-delivery-baseline.md) lines 452-453). This report makes no selection either.

## Remaining uncertainty

1. The kotlinlang.org guide pages are generated from master. The exact commit that produced the live pages is not published. This report cites master commit `3eadf938` and the live page URLs.
2. `combine` batching is opportunistic. This report did not run Kotlin tests to measure batching in practice.
3. This report did not read every kotlinx.coroutines test for `StateFlow`. The slot and emission facts come from the cited implementation files.
4. This report did not verify behavior with `equals`-violating classes. The KDoc declares that behavior unspecified.
5. Release 1.11.0 is the current stable release at capture time. Master can drift after this report.
6. The sibling reports live on `master`. The links in this report resolve after this branch merges.

## Self-check

Mode: pragmatic Simplified Technical English. Text class: descriptive.

Chosen nouns: value, collector, subscriber, emission, delivery, commit, replay, slot. Chosen verbs: emit, collect, publish, conflate, replay, cancel.

No procedure steps. No `should`, `would`, `may`, `might`, or `could` in report prose. No semicolon in report prose.

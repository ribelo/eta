# Prior-art transfer matrix

Ticket: [`docs/wayfinder/eta-crux-typed-projection-delivery/issues/06-prior-art-transfer-matrix.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/issues/06-prior-art-transfer-matrix.md)

## Question

What does the combined prior art establish for Eta Crux?

This report records one cited comparison matrix. The matrix covers the current Eta Crux baseline and the systems from tickets 01 through 05.

The eight dimensions are publication trigger, first replay, removal, transaction batching, order, backpressure, reconnection, and latest-value ownership.

This report names the closest reference implementations. It records which semantics transfer to Eta Crux and which do not. It does not select a public interface.

## Answer

Current Eta Crux publishes one complete committed output after one accepted advancement. The driver stores that output before delivery. Delivery waits for one transport acknowledgment. Failed delivery does not roll back the commit.

No inspected prior-art system owns that full set. Incremental and Bonsai own stabilize-then-publish. React owns a missed-wake notice-then-pull fence. Rust Crux owns a payload-free render notice. StateFlow owns one current value and current-value replay. Materialize owns snapshot-plus-live-updates, prefix completeness, and pull bounds. Feldera owns one output change across views for each input change.

These patterns can inform later design. They do not replace Eta Crux acknowledgment, serialized sessions, or no-loss capacity.

## Method

Primary sources only. Tickets 01 through 05 are leads. This report traces matrix facts to current Eta Crux files or to first-party pages and source.

| Class | Meaning |
|---|---|
| Documented | Public law, interface comment, or first-party page |
| Source | Current implementation behavior |
| Inference | Reading that this report adds |
| Unspecified | Public text and inspected source do not state a contract |
| Not applicable | The system has no object for that dimension |

This report did not run Eta Crux tests or any foreign test suite.

## Source revisions

This report re-read live pages after tickets 01 through 05. Reports for tickets 01 through 05 used 2026-08-13 as their capture date.

| Source | Revision |
|---|---|
| Current Eta Crux | Local `lib/crux`, `docs/design/eta-crux-v1`, and the typed-projection map |
| Jane Street Incremental | Current `master` `src/incremental_intf.ml`, plus pin [`98b5750`](https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/incremental_intf.ml) from ticket 02. The Observer contract is the same |
| Jane Street Bonsai | Current `master` `src/cont.mli`, plus driver pin [`f3166145`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli) from ticket 02 |
| Kotlin `StateFlow` | kotlinx.coroutines 1.11.0 and live kotlinlang.org pages |
| Rust Crux | Tag `crux_core-v0.20.0` and current `master` `crux_core/src/core/mod.rs` plus `capabilities/render.rs` |
| Elm | Released kernels from ticket 04 and the live Elm Architecture guide |
| React `useSyncExternalStore` | Tag `v19.2.8` and the live react.dev hook page |
| SolidJS | Docs stamped 2026-04-28. Source revision 1.9.14 from ticket 05 |
| Feldera | Live first-party pages. No published commit pin |
| Materialize | Live first-party pages. No published commit pin |

### Source identifiers

| ID | File or page |
|---|---|
| ETA-MLI | [`lib/crux/eta_crux.mli`](../../../lib/crux/eta_crux.mli) |
| ETA-DRV | [`lib/crux/crux_driver.ml`](../../../lib/crux/crux_driver.ml) |
| ETA-HOST | [`lib/crux/crux_host.ml`](../../../lib/crux/crux_host.ml) |
| ETA-LAW | [`docs/design/eta-crux-v1/semantic-laws.md`](../../../docs/design/eta-crux-v1/semantic-laws.md) |
| ETA-API | [`docs/design/eta-crux-v1/public-api.md`](../../../docs/design/eta-crux-v1/public-api.md) |
| ETA-MAP | [`docs/wayfinder/eta-crux-typed-projection-delivery/map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) |
| INC-INTF | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/incremental_intf.ml |
| INC-MASTER | https://github.com/janestreet/incremental/blob/master/src/incremental_intf.ml |
| BON-CONT | https://github.com/janestreet/bonsai/blob/master/src/cont.mli |
| BON-DRV-I | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli |
| SF-API | https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.flow/-state-flow/ |
| SH-API | https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.flow/-shared-flow/ |
| RX-CORE | https://github.com/redbadger/crux/blob/master/crux_core/src/core/mod.rs |
| RX-RENDER | https://github.com/redbadger/crux/blob/master/crux_core/src/capabilities/render.rs |
| EL-GUIDE | https://guide.elm-lang.org/architecture/ |
| EL-PLATFORM | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Platform.js |
| EL-BROWSER-JS | https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Elm/Kernel/Browser.js |
| EL-EVENTS | https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Events.elm |
| EL-TIME | https://github.com/elm/time/blob/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce/src/Time.elm |
| R-DOC | https://react.dev/reference/react/useSyncExternalStore |
| R-SHIM | https://github.com/facebook/react/blob/v19.2.8/packages/use-sync-external-store/src/useSyncExternalStoreShimClient.js |
| S-SIG | https://docs.solidjs.com/reference/basic-reactivity/create-signal |
| S-BATCH | https://docs.solidjs.com/reference/reactive-utilities/batch |
| S-EFF | https://docs.solidjs.com/reference/basic-reactivity/create-effect |
| S-CLEAN | https://docs.solidjs.com/reference/lifecycle/on-cleanup |
| F-INTRO | https://docs.feldera.com/sql/intro/ |
| F-SUB | https://docs.feldera.com/api/subscribe-to-view/ |
| F-ING | https://docs.feldera.com/api/insert-data/ |
| F-COMP | https://docs.feldera.com/api/check-completion-status/ |
| M-SUB | https://materialize.com/docs/sql/subscribe/ |
| M-FET | https://materialize.com/docs/sql/fetch/ |
| M-DUR | https://materialize.com/docs/transform-data/patterns/durable-subscriptions/ |
| BON-DRV | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml |
| RX-CMD | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/command/mod.rs |
| RX-RFC-CMD | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/rfcs/command.md |
| RX-TS | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/examples/counter/web-nextjs/src/app/core.ts |
| EL-SCHED | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Scheduler.js |
| EL-CMD | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Cmd.elm |
| S-SRC | https://github.com/solidjs/solid/blob/d2f81d546d5dff37aa25e4fa224e2192efec8c1a/packages/solid/src/reactive/signal.ts |
| F-MAT | https://docs.feldera.com/sql/materialized/ |

## Terms

This report uses one name for each acknowledgment class.

| Name | Meaning |
|---|---|
| Transport acknowledgment | The receiver answers one delivery. Eta Crux uses `Delivery.delivered`, `Delivery.failed`, or `Output_result` |
| Producer acceptance | The producer accepts an input. Eta Crux endpoint send is this class. It is not delivery |
| Progress token | The producer reports its own progress. Feldera completion tokens and Materialize `PROGRESS` are this class |

A progress token is not a transport acknowledgment. Producer acceptance is not a transport acknowledgment.

Hosted identity delivery answers the adapter callback and then answers the driver token (ETA-HOST lines 81-103). Serialized delivery answers with `Output_result` (ETA-MLI lines 483-487).

## Ownership seam

Eta Crux owns stabilization, atomic commit, delivery order, serialized sessions, and delivery acknowledgment (ETA-MAP lines 16-17). The driver is the only transport writer (same span).

The driver retains the latest committed output (ETA-LAW `O-01`, ETA-MLI line 739). Adapters own delivered-output retention (ETA-LAW `O-01`). Applications own models, cutoffs, and domain policy.

## Comparison matrix

Each system has one row in every dimension table. Incremental uses `Observer.on_update_exn` plus `Observer.value_exn`. Bonsai uses `Driver.flush`, `Driver.result`, and `Edge.on_change`.

### Publication trigger

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | One accepted advancement commits one complete root output. The driver then exposes delivery | Documented | ETA-LAW `T-03`, `T-04`, `O-02`. ETA-DRV lines 528-545 |
| Incremental | After `stabilize`, if the observer is first set or its value changed | Documented | INC-INTF `on_update_exn`. INC-MASTER nutshell |
| Bonsai | After `flush` stabilize, the caller pulls `result`. `Edge.on_change` also runs on first activation or a later unequal value | Documented | BON-DRV-I main loop. BON-CONT `Edge.on_change` |
| StateFlow | A write of an unequal current value | Documented | SF-API strong equality conflation |
| Rust Crux | `update` returns a command that includes `render()` | Documented | RX-RENDER |
| Elm | After `init` and after each `update` | Source | EL-PLATFORM `sendToApp`. EL-GUIDE Model View Update |
| React `useSyncExternalStore` | The store invokes the subscribe callback. React then calls `getSnapshot` | Documented | R-DOC `subscribe` and `getSnapshot` |
| SolidJS | A signal write that fails equality | Documented | S-SIG setter. S-EFF later runs |
| Feldera | One input change produces one output change across all views | Documented | F-INTRO |
| Materialize | Default `SUBSCRIBE` emits the `AS OF` snapshot, then later diffs | Documented | M-SUB `SNAPSHOT` |

### First replay

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | Ordinary startup has no output before the first commit. Serialized session replacement redelivers the current committed output | Documented | ETA-LAW `D-07`, `W-08`. ETA-DRV lines 217, 528-536, and 292-338 |
| Incremental | First handler call is `Initialized` with the current value. There is no history replay | Documented | INC-INTF `Update` and `on_update_exn` |
| Bonsai | Driver creation runs one stabilize and computes the first `result`. `Edge.on_change` always runs on first activation with previous `None` | Documented | BON-DRV-I `result`. BON-CONT `on_change'` |
| StateFlow | A new collector receives the current value at once | Documented | SF-API replay of one most recent value |
| Rust Crux | The core does not render at start. The example shell pulls `view` once at boot | Source | RX-CORE `view`. RX-TS `initialize` |
| Elm | The animator draws the initial model at once | Source | EL-BROWSER-JS `_Browser_makeAnimator` |
| React `useSyncExternalStore` | The first render pulls the current snapshot. Hydration uses `getServerSnapshot` | Documented | R-DOC parameters and server snapshot |
| SolidJS | A memo runs at once. An effect first run reads the current value after render | Documented | S-EFF initial run |
| Feldera | HTTP snapshot is opt-in. Default `send_snapshot` is `false` | Documented | F-SUB `send_snapshot` |
| Materialize | Default `SNAPSHOT` is `true`. The snapshot is the full relation at `AS OF` | Documented | M-SUB `SNAPSHOT` |

### Removal

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | There is no per-projection observer. Session replace closes the old session. `Hosted.Control` exposes only `request_stop` | Documented | ETA-MLI lines 616-619 and 770-774. ETA-LAW `W-08` |
| Incremental | `disallow_future_use` stops later handlers and later pulls | Documented | INC-INTF `disallow_future_use` |
| Bonsai | `invalidate_observers` disallows the driver observers. An inactive branch pauses `Edge` | Documented | BON-DRV-I `Expert.invalidate_observers`. BON-CONT lifecycle text |
| StateFlow | Collector cancel frees that slot. The flow and other collectors stay | Documented | SH-API subscriber cancel |
| Rust Crux | Not applicable. There is no observer or subscription | Documented absence | RX-CORE and RX-RENDER |
| Elm | The whole view is replaced by diff. Browser.Events and Time kill processes for removed keys | Source | EL-EVENTS `onEffects`. EL-TIME `onEffects` |
| React `useSyncExternalStore` | `subscribe` returns a cleanup function. A new `subscribe` replaces the old one | Documented | R-DOC `subscribe` and caveats |
| SolidJS | Owner dispose runs `onCleanup` | Documented | S-CLEAN |
| Feldera | The client closes the HTTP connection, or the pipeline stops | Documented | F-SUB duration |
| Materialize | Cancel, session end, or `UP TO` | Documented | M-SUB duration |

### Transaction batching

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | One advancement publishes one complete root frame. Cutoff never drops that delivery | Documented | ETA-LAW `T-03`, `T-04`, `C-05` |
| Incremental | At most one handler call per observer per `stabilize`. Many `Var.set` calls become one publication | Documented | INC-INTF `on_update_exn` and Stabilization |
| Bonsai | One `result` per `flush`. `Edge.on_change` runs at most once per frame with the latest value | Documented | BON-DRV-I. BON-CONT `on_change` |
| StateFlow | Equal writes do nothing. A slow collector skips distinct intermediate values | Documented | SF-API conflation |
| Rust Crux | One `Vec` of effect requests per core call. Render effects are not deduped | Source | RX-CORE `process` |
| Elm | Draws coalesce per animation frame. The latest model wins | Source | EL-BROWSER-JS animator |
| React `useSyncExternalStore` | The store has no commit API. Store updates render as sync work | Documented | R-DOC Transition caveat. R-SHIM comment |
| SolidJS | `batch` defers downstream work until the function returns | Documented | S-BATCH |
| Feldera | One input change is one output change. There is no SQL transaction | Documented | F-INTRO |
| Materialize | Several updates can share one timestamp. That timestamp is the batch | Documented | M-SUB timestamps and `WITHIN TIMESTAMP ORDER BY` |

### Order

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | Commit, then latest-output write, then delivery, then post-commit work. Wire sequences are exact | Documented | ETA-LAW `O-02`, `D-02`, `W-02`. ETA-DRV lines 528-545 |
| Incremental | Handlers run after recompute, not during `stabilize`. Cross-observer order is unspecified | Documented plus unspecified | INC-INTF `on_update_exn` timing |
| Bonsai | `flush`, then `result`, then deactivate, activate, after-display | Documented | BON-DRV-I main loop and `trigger_lifecycles` |
| StateFlow | No documented order among collectors | Unspecified | SF-API silence on collector order |
| Rust Crux | Request ids ascend and are not reused. Effect order inside one batch is not documented | Source plus unspecified | RX-CORE `process`. RX-RFC-CMD task wake order |
| Elm | Update runs, then the stepper, then effects. Command result order has no law | Source plus documented | EL-PLATFORM `sendToApp`. EL-CMD `batch` |
| React `useSyncExternalStore` | The subscriber re-renders. Cross-listener order is not a law | Unspecified | R-DOC example loop is not a law |
| SolidJS | Effect order among several effects is not guaranteed | Documented | S-EFF subsequent runs |
| Feldera | Chunks carry `sequence_number` on one subscribe stream | Documented | F-SUB schema |
| Materialize | `mz_timestamp` never decreases on one `SUBSCRIBE` | Documented | M-SUB output |

### Backpressure

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | Ingress and request capacities are explicit and never exceeded. Delivery waits for one answer. There is no loss | Documented | ETA-LAW `A-09`, `D-02`. ETA-MLI lines 665-670 and 718-725 |
| Incremental | None. The handler is a sync `unit` callback | Documented | INC-INTF `on_update_exn` type |
| Bonsai | None. The action queue is an unbounded `Queue.t`. Effects have no acknowledgment | Source | BON-DRV `queue`. BON-DRV-I `schedule_event` |
| StateFlow | The writer never waits. A slow collector skips fast updates and still receives the latest value | Documented | SF-API updates are always conflated |
| Rust Crux | None. Effect and event channels are unbounded | Documented | RX-CMD `new` comment on unbounded channels |
| Elm | None. The scheduler queue is unbounded | Source | EL-SCHED process queue |
| React `useSyncExternalStore` | None. A store change forces a sync re-render | Source | R-SHIM force update. R-DOC has no queue bound |
| SolidJS | None. Observer work is sync graph work | Source | S-SRC write and flush |
| Feldera | Default HTTP `backpressure` is `false` and drops chunks. `true` can block the pipeline | Documented | F-SUB `backpressure` |
| Materialize | `DECLARE` plus `FETCH` bounds pull. `TIMEOUT '0s'` returns ready rows only. The protocol does not drop | Documented | M-FET. M-SUB duration warning |

### Reconnection

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | `Serialized_session.replace` closes the old session, installs a fresh registry, and redelivers the current output. It never replays requests | Documented | ETA-LAW `W-08`, `W-09`. ETA-DRV lines 292-338 |
| Incremental | A disposed observer cannot be reused. A new `observe` is required | Documented | INC-INTF raise after `disallow_future_use` |
| Bonsai | There is no session replace API. A new driver or `invalidate_observers` is a new observation | Documented | BON-DRV-I `create` and `invalidate_observers` |
| StateFlow | A later `collect` is a new subscription. It replays the current value only | Documented | SF-API never completes. Replay size one |
| Rust Crux | Not applicable. The bridge has no session | Documented absence | RX-CORE three methods only |
| Elm | Browser.Events and Time keep a process for an unchanged key and spawn a process for a new key | Source | EL-EVENTS and EL-TIME `onEffects` |
| React `useSyncExternalStore` | A later mount is a new subscription. It pulls the current snapshot again. There is no resume cursor | Inference | R-DOC has hydration, not a network cursor |
| SolidJS | A new owner is a new subscription. There is no resume cursor | Inference | S-EFF SSR and hydration skip |
| Feldera | HTTP subscribe has no `AS OF` cursor. A completion token from a prior incarnation returns `410` | Documented | F-SUB. F-COMP `410` |
| Materialize | The client stores the last progress timestamp and resumes with `AS OF`. History must still exist | Documented | M-DUR |

### Latest-value ownership

| System | Fact | Class | Source |
|---|---|---|---|
| Eta Crux | The driver owns `last_output`. Pull reads that field. Delivery and terminal state do not clear it | Documented | ETA-LAW `D-07`, `O-01`. ETA-DRV lines 679-680. ETA-API lines 670-671 |
| Incremental | The Incremental node holds the stable value. `Observer.value_exn` pulls it after stabilize | Documented | INC-INTF `value` errors |
| Bonsai | The Incremental result observer holds the value. `Driver.result` pulls it. The driver does not copy a last-result field | Documented | BON-DRV-I `result` |
| StateFlow | The flow instance stores one `value`. Collectors do not own it | Documented | SF-API `value` |
| Rust Crux | The core owns the model. Each `view` pull recomputes a view model. The shell owns the last pulled copy | Source | RX-CORE `view` |
| Elm | The runtime owns the model and the current vdom | Source | EL-PLATFORM. EL-BROWSER-JS |
| React `useSyncExternalStore` | The external store owns the live value. React caches the last rendered snapshot | Documented | R-DOC `getSnapshot`. R-SHIM `inst.value` |
| SolidJS | Each signal node owns its current value | Documented | S-SIG getter and setter |
| Feldera | A materialized view retains a complete snapshot inside the pipeline | Documented | F-MAT. F-INTRO storage note |
| Materialize | The subscribed object holds current contents. The client rebuilds its own copy from diffs | Documented | M-SUB conceptual framework. M-DUR client persist |

## Closest reference implementations

Closest means the largest overlap on the eight dimensions. It is not a public-interface choice.

### Incremental Observer

Incremental is the closest stabilize-then-publish reference. Publication waits for `stabilize`. One observer gets at most one notice per stabilize. The first notice is `Initialized`. Later notices are `Changed`. `value_exn` pulls the latest stable value.

This matches Eta Crux commit-then-publish and latest-output pull. It does not match acknowledgment, capacity, or serialized sessions.

### Bonsai driver

Bonsai is the closest post-commit lifecycle reference. The loop is `flush`, then `result`, then lifecycle work. That order is close to Eta Crux `O-02`.

`Edge.on_change` is a first-activation plus later-change effect. It is not a transport.

### React `useSyncExternalStore`

React is the closest missed-wake reference. Attachment pulls the current snapshot, subscribes, then re-reads. Later notices carry no value. Each notice causes another pull.

This is the only documented pull-subscribe-reread fence in the matrix. It has no transport acknowledgment and no session.

### Rust Crux render plus view

Rust Crux is the closest payload-free notice. `RenderOperation` is a unit struct. The shell pulls `view` later.

The pull recomputes from the live model. That conflicts with Eta Crux retained committed output (`D-07`, `D-08`).

### StateFlow current value

StateFlow is the closest current-value slot. One value exists at all times. A new collector receives that value. A slow collector can skip distinct intermediate values and still receive the latest value.

The writer never waits. StateFlow suppresses equal committed outputs. That conflicts with `T-03` and `C-05`.

### Materialize `SUBSCRIBE`

Materialize is the closest snapshot-plus-subscribe reference. One operation emits the current relation and later diffs. `PROGRESS` marks prefix completeness. `FETCH` bounds pull without drop.

The client rebuilds state. Resume is application-owned. `PROGRESS` is a progress token, not a transport acknowledgment.

### Feldera DBSP

Feldera is the closest multi-view one-change reference. One input change produces one output change across views.

Default HTTP subscribe drops chunks. The completion token reports input processing, not subscriber delivery.

### Elm whole-program view

Elm is a complete-output renderer with frame coalescing. It has no per-projection observation contract. It is not a close delivery reference.

## What transfers

These facts fit the Eta Crux ownership seam. Later design can use them. They do not select an interface.

1. Publication waits for stabilize or commit. Incremental, Bonsai, and current Eta Crux share this fence.
2. Many internal writes become one publication unit. Incremental stabilize, Bonsai flush, Feldera input change, and Materialize timestamps show this shape.
3. First snapshot and later change are distinct. Incremental `Initialized` versus `Changed` is the clearest pair.
4. A latest-value pull can sit beside a notice. Incremental `value_exn`, StateFlow `value`, React `getSnapshot`, and Eta Crux `latest_committed_output` share this shape.
5. A new attach receives the current snapshot. It does not receive a history log. StateFlow, React, Incremental `Initialized`, and Eta Crux session replace agree here.
6. React attachment pulls, then subscribes, then re-reads. That sequence closes the missed-wake hole.
7. Only the Rust Crux payload-free notice transfers. Eta Crux then pulls the retained complete output from the driver. Rust Crux pull-time recompute does not transfer.
8. Removal is an explicit call. Incremental `disallow_future_use`, React cleanup, Solid owner dispose, and Materialize cancel are explicit.
9. Cutoff stays inside the graph. Incremental cutoff, Bonsai `cutoff`, and Solid `equals` stop derived work. Those cutoffs must not drop a committed root output (`C-05`).
10. After-commit lifecycle runs after result publication. Bonsai documents that order.
11. A progress signal marks prefix completeness. Materialize `PROGRESS` is the source. It is not a delivery answer.
12. Pull can bound the consumer. Materialize `FETCH` is the source. Drop is not a transfer.
13. Subscriptions reconcile with manager-local add, keep, and remove. Elm Browser.Events and Time show that pattern.
14. Request identities ascend and are not reused. Rust Crux `EffectId` shows that pattern.
15. A collector checks cancellation before each emission. SharedFlow documents that check.

## What does not transfer

These facts conflict with the matrix row for Eta Crux, or they leave a required dimension unspecified.

1. Missing transport acknowledgment. Incremental, Bonsai, StateFlow, Rust Crux, Elm, React, Solid, Feldera, and Materialize have no `Output_result`. Eta Crux requires one answer (`D-02`, `T-05`).
2. Progress tokens as if they were delivery answers. A Feldera completion token reports input processing (F-ING, F-COMP). Materialize `PROGRESS` reports timestamp completeness (M-SUB). Neither is subscriber acknowledgment.
3. Producer acceptance as if it were delivery. Eta Crux endpoint send accepts input (`A-01`). It does not answer output delivery.
4. Suppression of a committed root output. StateFlow equal writes do nothing. Incremental and Bonsai cutoff can stop derived work. Eta Crux still delivers an equal committed output (`T-03`, `C-05`).
5. Independent streams without one atomic commit. Separate StateFlow values, Solid signals, and two React stores have no shared frame. Eta Crux commits one root frame (`T-04`).
6. Unspecified collector or effect order as a delivery law. StateFlow, Solid, React listeners, and Rust Crux tasks leave order unspecified. Eta Crux owns order (`O-02`, `W-02`).
7. Unbounded queues and sync callbacks with no bound. Incremental, Bonsai, Rust Crux, Elm, React, and Solid have no capacity law. Eta Crux forbids overflow (`A-09`).
8. Default drop. Feldera HTTP `backpressure=false` drops chunks (F-SUB). Eta Crux forbids loss.
9. Pull-time recompute of a projection. Rust Crux `view` reads the live model (RX-CORE). Eta Crux pull returns the retained committed output (`D-07`, `D-08`).
10. Client-rebuilt diffs as the root frame. Materialize and Feldera streams send inserts and deletes. Current Eta Crux publishes one complete output (`T-03`).
11. Application-owned resume as serialized session replace. Materialize `AS OF` resume belongs to the client (M-DUR). Feldera HTTP has no cursor. Eta Crux replace redelivers the current output and does not replay requests (`W-08`, `W-09`).
12. Hydration or checkpoint resume as session replace. React `getServerSnapshot` is hydration. Feldera `410` invalidates an old completion token. Neither matches `Serialized_session.replace`.
13. Finalizer-based close. Incremental can finalize an observer with no handlers. Eta Crux close is an explicit session or stop path.
14. Application effects as transport writes. Bonsai `Edge.on_change`, Elm ports, Solid `createEffect`, and React re-render are not driver writes. The map keeps the driver as the only writer.
15. A value that exists before the first commit. StateFlow always has an initial value. Eta Crux latest output is absent before the first commit (`D-07`).
16. Animation-frame order. Elm coalesces draws to the browser clock. Eta Crux owns delivery order, not frame timing.
17. DAG invalidation or `Unnecessary` as a wire tag. Incremental necessity is graph-local.
18. An Elm or Rust Crux whole-program view as a typed projection contract. Neither system defines per-projection delivery.

## Later design comparison

The map names four designs for later work. This matrix maps prior art onto those designs. It does not select one.

### Complete-output delivery

Current Eta Crux, Incremental `value_exn`, Bonsai `result`, StateFlow `value`, Elm view, and React `getSnapshot` publish one complete current value.

This is the current Eta Crux baseline.

### Notification followed by pull

React later changes, Incremental `on_update_exn` plus `value_exn`, and Rust Crux render plus `view` separate notice from value.

If later design uses this split, the notice comes after commit. The pull owner stays `Driver.latest_committed_output`.

### Independent streams

Solid signals, separate StateFlow values, and Feldera per-view HTTP streams are independent.

They do not give one atomic observation unless a higher commit exists. Feldera has that commit at the input-change boundary. Solid and StateFlow `combine` do not.

### Application effects

Bonsai `Edge.on_change`, Elm ports, and Solid `createEffect` run application work on change.

They are not delivery. Application effects as transport break the single-writer seam.

## Remaining uncertainty

Later tickets must not treat these items as contracts.

1. Bonsai public text says `Edge.on_change` always runs the first time a component becomes active. Ticket 02 source compares retained state and does not schedule an equal reactivate. The two readings conflict.
2. Incremental cross-observer handler order is source stack order. It is not a documented law.
3. Solid live docs mark `createSignal` `equals` default as `false`. Ticket 05 source default is `===`. The source is the authority.
4. Feldera completion-token pages describe input processing. That token is not subscriber delivery. Later text must keep that split.
5. Materialize `RETAIN HISTORY` was private preview in ticket 05. Resume through `AS OF` depends on retained history.
6. React listener order in the store example is array order. The hook page does not make that a law.
7. Rust Crux effect order inside one batch is not documented. Request ids are ordered. Effects are not.
8. Elm outgoing port order is the reverse of bag prepend in kernel source. The guide gives no order law.
9. The live Elm guide, react.dev, Feldera pages, and Materialize pages have no commit pin. Those pages can change.
10. Ticket 01 records three Eta Crux gate gaps. Those gaps are coverage holes. They are not prior-art contracts.
11. This report did not re-run kernels for Elm Platform.js, Incremental `state.ml`, or Solid `signal.ts`. Those cells reuse ticket 02 through 05 primary pins that still match the live public pages.

## Self-check

Mode: pragmatic Simplified Technical English. Text class: descriptive.

Chosen nouns: publication, delivery, acknowledgment, replay, commit, snapshot, pull, session. Chosen verbs: publish, deliver, acknowledge, replay, commit, pull, remove, retain.

No procedure steps. No `should`, `would`, `may`, `might`, or `could` in report prose. No semicolon in report prose.

Longest sentences were split to 25 words or fewer. Conditions stand at the start of their sentence. Identity names and paths are technical nouns.

# Incremental and Bonsai publication semantics

Ticket: [`docs/wayfinder/eta-crux-typed-projection-delivery/issues/02-incremental-and-bonsai-publication-semantics.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/issues/02-incremental-and-bonsai-publication-semantics.md)

## Question

Which Jane Street Incremental and Bonsai observation semantics can inform Eta Crux typed projection delivery?

This report records publication contracts. It does not select a public interface.

## Answer

Incremental and Bonsai publish after a stabilize step. They do not publish during graph recompute.

`Observer.on_update_exn` sends at most one update per observer per stabilize. The first update is `Initialized`. Later value changes are `Changed`. Graph death is `Invalidated`.

Bonsai `Edge.on_change` sends at most one effect per frame. It always runs on first activation. It carries the latest value.

`Bonsai.cutoff` and Incremental `Cutoff` stop graph propagation. They are not a root-output delivery switch.

Eta Crux can take stabilize-then-publish, one notice per commit, first-versus-later updates, explicit dispose, and latest-value pull.

Eta Crux cannot take unbounded sync callbacks, DAG necessity as a wire protocol, independent observer streams, or Bonsai frame effects as delivery.

## Method

Primary sources only.

| Class | Meaning |
|---|---|
| Documented | Public comment or Jane Street how-to text |
| Source | Current implementation behavior |
| Inference | Reading that this report adds |

This report did not run Incremental or Bonsai tests.

## Source revisions

This report used GitHub `master` commits from 2026-07-10. The commit message on each repo is `v0.18~preview.130.106+341`.

| Repo | Commit | Role |
|---|---|---|
| [janestreet/incremental](https://github.com/janestreet/incremental) | [`98b5750ec3c006641351bfd858a89136a5dbc52c`](https://github.com/janestreet/incremental/commit/98b5750ec3c006641351bfd858a89136a5dbc52c) | Observer, cutoff, stabilize |
| [janestreet/bonsai](https://github.com/janestreet/bonsai) | [`f31661450eb133fe89564219d97669c2735c6622`](https://github.com/janestreet/bonsai/commit/f31661450eb133fe89564219d97669c2735c6622) | Cutoff, Edge, driver, lifecycle |
| [janestreet/bonsai_web](https://github.com/janestreet/bonsai_web) | [`989c18b5381cad767365923d4f0b758c6f3c602c`](https://github.com/janestreet/bonsai_web/commit/989c18b5381cad767365923d4f0b758c6f3c602c) | Runtime loop and test handle |

Stable file URLs use those commits.

| ID | File | URL |
|---|---|---|
| INC-INTF | `src/incremental_intf.ml` | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/incremental_intf.ml |
| INC-STATE | `src/state.ml` | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/state.ml |
| INC-OUH | `src/on_update_handler.ml` | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/on_update_handler.ml |
| INC-NODE | `src/node.ml` | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/node.ml |
| INC-IOBS | `src/internal_observer.ml` | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/internal_observer.ml |
| INC-ML | `src/incremental.ml` | https://github.com/janestreet/incremental/blob/98b5750ec3c006641351bfd858a89136a5dbc52c/src/incremental.ml |
| BON-CONT-I | `src/cont.mli` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli |
| BON-CONT | `src/cont.ml` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.ml |
| BON-PROC | `src/proc.ml` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/proc.ml |
| BON-VAL | `src/private_base/value.ml` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/value.ml |
| BON-LC-I | `src/private_base/lifecycle.mli` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/lifecycle.mli |
| BON-LC | `src/private_base/lifecycle.ml` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/private_base/lifecycle.ml |
| BON-DRV-I | `src/driver/bonsai_driver.mli` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli |
| BON-DRV | `src/driver/bonsai_driver.ml` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml |
| WEB-RT | `docs/how_to/bonsai_runtime.md` | https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/bonsai_runtime.md |
| WEB-LC | `docs/how_to/lifecycles.md` | https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/lifecycles.md |
| WEB-EDGE | `docs/how_to/edge_triggered_effects.md` | https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/edge_triggered_effects.md |
| WEB-TEST | `docs/how_to/testing.md` | https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/docs/how_to/testing.md |
| BON-README | `README.md` | https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/README.md |

Eta Crux context is the current delivery baseline and the typed-projection map. Those files are local project sources.

## Incremental stabilize fence

Documented in INC-INTF, section `Incremental in a nutshell`.

`observe` marks a node as observed. `stabilize` brings observed values up to date. `Observer.on_update_exn` runs after a stabilize in which the observer value changed or was first set.

Documented in INC-INTF, section `Stabilization`.

`stabilize` walks the DAG from changed variables. It recomputes each necessary stale node at most once. A node change adds parents to the heap. A cutoff can stop that walk. If `stabilize` raises, later `stabilize` calls raise.

Source in INC-STATE, `stabilize`.

`stabilize` refuses a nested call. It then runs `stabilize_start`, the recompute heap, and `stabilize_end`. `stabilize_start` adds new observers and unlinks disallowed observers before recompute.

Source in INC-STATE, `ensure_not_stabilizing`.

A call named `stabilize` is illegal during stabilize. It is also illegal during on-update handlers.

Inference. Incremental treats stabilize as a closed batch. Publication is after that batch.

## Incremental `Observer.on_update_exn`

Documented in INC-INTF, `module Observer`.

```ocaml
module Update : sig
  type 'a t =
    | Initialized of 'a
    | Changed of 'a * 'a
    | Invalidated
end

val on_update_exn : 'a t -> f:('a Update.t -> unit) -> unit
```

`on_update_exn t ~f` calls `f` after the current stabilize. It then calls `f` after later stabilizes in which `t` changes. It stops after `disallow_future_use t`. `f` runs at most once per stabilize. If future use is already disallowed, `on_update_exn` raises.

The documented Observer state machine is in INC-INTF, `on_update_exn`.

- `Start` goes to `Initialized`
- `Initialized` goes to `Changed` or `Invalidated`
- `Changed` can repeat as `Changed`
- `Changed` can go to `Invalidated`
- `Invalidated` is terminal

Source in INC-OUH, `run`, confirms the terminal `Invalidated` case. Incremental does not make an invalid node valid again (INC-INTF, bind invalidation).

Source in INC-ML, `Observer.on_update_exn`.

The wrapper maps node `Necessary a` to `Initialized a`. It maps `Changed` and `Invalidated` as themselves. `Unnecessary` is an Incremental bug for this API.

Source in INC-STATE, `observer_on_update_exn` and `stabilize_end`.

A new handler is stamped with the current stabilize number. The observed node is pushed onto `handle_after_stabilization`. `stabilize_end` first classifies the node, then runs handlers. A handler created during handler run waits for the next stabilize (INC-OUH, `run`, and INC-STATE comment on `stabilization_num`).

Source in INC-IOBS, `on_update_exn`.

A live observer prepends the handler. A created observer stores the handler and bumps the count at the next `stabilize_start`.

### Matrix: `Observer.on_update_exn`

| Field | Fact | Class |
|---|---|---|
| Publication trigger | After stabilize. The observer was first set, or its value changed | Documented, INC-INTF `on_update_exn` |
| Initial replay | First call is `Initialized` with the current value. There is no history replay | Documented state machine, INC-INTF |
| Removal or disposal | `disallow_future_use` stops later handler runs. A later `on_update_exn` raises | Documented, INC-INTF |
| Batching or coalescing | At most one `f` call per stabilize. Intermediate `Var.set` values are not pushed | Documented `f` bound, INC-INTF. Documented `Var.set` delay, INC-INTF `module Var` |
| Order | After recompute. Not during stabilize. Cross-observer order is not a public law | Documented timing, INC-INTF. Source stack walk, INC-STATE `stabilize_end` |
| Backpressure | None. `f` is a sync `unit` callback | Documented type, INC-INTF |
| Reconnection or reactivation | A disallowed observer cannot be reused. A new `observe` is required | Documented raise after dispose, INC-INTF |
| Latest-value owner | The Incremental node holds `value_opt`. `Observer.value_exn` pulls it after stabilize | Documented `value` errors, INC-INTF. Source `Internal_observer.value_exn`, INC-IOBS |
| Transferable | Stabilize, then publish. One notice per commit. First value versus later change. Explicit dispose | Inference |
| Non-transferable | Sync `f` with no ack. DAG invalidation as a wire tag. Finalizer dispose | Inference |

## Incremental `Initialized`, `Changed`, and `Invalidated`

Documented in INC-INTF, `Observer.Update`.

`Initialized of 'a` is the first stable value. `Changed of 'a * 'a` is `(old_value, new_value)`. `Invalidated` means the observed node is no longer valid.

Documented in INC-INTF, section `Bind, scopes, and invalidation`.

A bind left-hand change invalidates nodes created on the right-hand side. Incremental does not make an invalid node valid again.

Source in INC-STATE, `stabilize_end`.

Classification is:

1. invalid node -> `Invalidated`
2. unnecessary node -> `Unnecessary`
3. no stored old value -> `Necessary`
4. else -> `Changed (old, new)`

`Observer.on_update_exn` never exposes `Unnecessary`.

Source in INC-OUH, `run`.

A first `Changed` seen by a new handler becomes `Necessary`. After `Invalidated`, later updates are ignored.

Inference. `Initialized` is observer birth. `Changed` is a later distinct value. `Invalidated` is terminal for that observer.

## Incremental notification frequency

Documented in INC-INTF, `on_update_exn`.

`f` runs at most once per stabilize.

Documented in INC-INTF, section `Stabilization`.

Each node is recomputed at most once per stabilize.

Source in INC-STATE, `maybe_change_value`.

A cutoff that returns true does not write a new value. It does not mark the node changed. It does not enqueue parents. It does not enqueue on-update handlers.

Source in INC-NODE, `is_in_handle_after_stabilization`.

A node is on the after-stabilize stack at most once.

Inference. Many `Var.set` calls before one `stabilize` become one publication. That matches one Eta Crux commit per advancement.

## Incremental observer disposal

Documented in INC-INTF, section `Garbage collection`, and `disallow_future_use`.

If an observer has no on-update handlers, a finalizer can call `disallow_future_use` after user code drops the observer. If an observer has on-update handlers, only `disallow_future_use` removes it. Finalizers can run late. Eager dispose is the stated preference.

After `disallow_future_use t`:

- later `on_update_exn` and `value_exn` raise
- `value` returns `Error`
- handlers never run again
- the next `stabilize` marks `t` unobserved before recompute
- nodes that exist only for `t` become unnecessary

Documented in INC-INTF, `observe`.

Default `should_finalize` is `true`. `observe ~should_finalize:false` lives until an explicit dispose. `observe_no_finalization` is the portable form of that.

Source in INC-STATE, `stabilize_start`.

New observers are linked first. Disallowed observers are unlinked next. That order avoids a short necessary and unnecessary flip.

Inference. Eta Crux can take explicit session dispose. It cannot take GC finalizers as a delivery close.

## Incremental after-stabilize callback order

Documented in INC-INTF, `on_update_exn` and `on_update`.

Handlers run after stabilize, not during recompute. `Observer.value` is an error in the middle of stabilize.

Source in INC-STATE, comments on `handle_after_stabilization`.

There are two passes.

The first pass classifies each queued node from the stable graph. It pushes `(node, update)` onto `run_on_update_handlers`.

The second pass sets status `Running_on_update_handlers` and runs handlers. User code can call Incremental functions except `stabilize`. Those calls can queue later work. They cannot change the current run list.

Source in INC-STATE, `stabilize_end`.

`stabilization_num` grows before handler run. Handlers created in this pass wait for the next stabilize.

Source in INC-NODE, `run_on_update_handlers`.

For one node, Incremental `on_update` handlers run first. Observer handlers run next. If an observer becomes `Disallowed` mid-run, later handlers on that observer do not run.

Inference. After-stabilize is a hard fence. Exact cross-node order is stack order. That order is not a documented public law.

### Matrix: after-stabilize order

| Field | Fact | Class |
|---|---|---|
| Publication trigger | End of `stabilize`, after the recompute heap is empty | Source, INC-STATE `stabilize` |
| Initial replay | A new handler runs on the next eligible stabilize. Attach outside stabilize does not run it immediately | Source, INC-OUH `created_at` |
| Removal or disposal | Dispose before the next stabilize prevents later runs | Documented, INC-INTF |
| Batching or coalescing | One classified update per node per stabilize | Source, INC-STATE `stabilize_end` |
| Order | Classify all, then run all. No nested `stabilize` | Source, INC-STATE |
| Backpressure | None. Handler run is sync and unbounded | Source type and loop |
| Reconnection or reactivation | New handlers created during this pass run on the next stabilize | Source, INC-STATE comment |
| Latest-value owner | Classification reads `node.value_opt` before user handlers run | Source, INC-STATE `stabilize_end` |
| Transferable | The publication set comes from a frozen commit. Delivery then runs. Delivery cannot start the next commit | Inference |
| Non-transferable | Stack order as a law. Sync handler reentry into graph builders | Inference |

## Incremental `observe` and `Observer.value_exn`

Documented in INC-INTF, `observe` and `Observer.value`.

`observe` creates a new observer. `value` returns `Error` during stabilize, before the first stabilize, or after dispose. If the node is invalid, `value` also returns `Error`. `value_exn` raises in those cases.

This is pull observation. It is not a push stream.

### Matrix: `observe` plus `value_exn`

| Field | Fact | Class |
|---|---|---|
| Publication trigger | Caller pulls after `stabilize` | Documented, INC-INTF |
| Initial replay | Before the first stabilize, pull fails | Documented, INC-INTF |
| Removal or disposal | `disallow_future_use` makes later pull fail | Documented, INC-INTF |
| Batching or coalescing | Pull sees the latest stable value only | Documented, INC-INTF |
| Order | Pull is sync and has no delivery sequence | Documented type |
| Backpressure | None | Documented type |
| Reconnection or reactivation | New `observe` after dispose | Documented |
| Latest-value owner | Incremental node, read through the observer | Documented plus INC-IOBS |
| Transferable | Latest committed output as a pull boundary | Inference. Matches current Eta Crux `Driver.latest_committed_output` |
| Non-transferable | Pull failure during stabilize as a public transport error | Inference |

## Incremental `on_update`

Documented in INC-INTF, `module Update` and `on_update`.

This API does not make the node necessary. It uses `Necessary`, `Changed`, `Invalidated`, and `Unnecessary`. If a node gets a new value but is unnecessary at the end of stabilize, `f` does not get `Changed`. If the diagram allows `Unnecessary`, `f` can receive that tag.

Jane Street text names `Observer.on_update_exn` as the usual API. `on_update` exists for `Unnecessary` updates.

### Matrix: Incremental `on_update`

| Field | Fact | Class |
|---|---|---|
| Publication trigger | After stabilize, for necessity or value change | Documented, INC-INTF |
| Initial replay | First useful tag is `Necessary`, not `Initialized` | Documented |
| Removal or disposal | No public unsubscribe. Handlers only grow on the node | Source, INC-NODE `on_update_handlers` comment |
| Batching or coalescing | At most one call per stabilize | Same handler machine as observers, INC-OUH |
| Order | Same after-stabilize passes | Source, INC-STATE |
| Backpressure | None | Documented type |
| Reconnection or reactivation | `Unnecessary` then later `Necessary` is allowed | Documented diagram |
| Latest-value owner | Incremental node | Source |
| Transferable | Necessity as an internal graph fact, not a wire frame | Inference |
| Non-transferable | `Unnecessary` as a client protocol tag. No unsubscribe | Inference |

## Incremental `Cutoff` and `set_cutoff`

Documented in INC-INTF, section `Stabilization` and section `Cutoffs`.

A cutoff is a function on old value and new value. If it returns true, change does not propagate. The default cutoff is `phys_equal`. `Cutoff.of_equal` builds a cutoff from equality.

Source in INC-STATE, `maybe_change_value`.

If there is no old value, the new value is stored. If a cutoff does not fire, the node stores the new value, records `changed_at`, and notifies parents and handlers. If a cutoff fires, none of that happens.

### Matrix: Incremental `Cutoff`

| Field | Fact | Class |
|---|---|---|
| Publication trigger | Cutoff does not publish. It can stop a later publish | Documented stabilize step 3, INC-INTF |
| Initial replay | First compute has no old value, so cutoff does not apply | Source, INC-STATE `maybe_change_value` |
| Removal or disposal | `set_cutoff` replaces the function on that node | Documented `set_cutoff` |
| Batching or coalescing | Equal values drop parent work and handler work | Source, INC-STATE |
| Order | Cutoff runs during recompute, before after-stabilize handlers | Source |
| Backpressure | None | Source |
| Reconnection or reactivation | Not applicable | Inference |
| Latest-value owner | If cutoff fires, the node keeps the old value | Source |
| Transferable | Cutoff as a graph fence for derived projections | Inference |
| Non-transferable | Cutoff as a suppressor of committed root delivery | Inference. Conflicts with Eta Crux law `C-05` |

## Bonsai `Value.cutoff` and `Bonsai.cutoff`

Documented in BON-CONT-I, `val cutoff`.

When a dependency changes, the runtime recomputes a node. `Bonsai.cutoff` takes `equal` and treats close values as the same.

Source in BON-CONT, `cutoff`.

The public function calls `Value.cutoff ~added_by_let_syntax:false`.

Source in BON-VAL, `cutoff` and `eval`.

`Value.cutoff` builds a `Cutoff` node. `eval` turns that node into an Incremental node and calls `Incremental.set_cutoff` with `Cutoff.of_equal equal`. For `Named`, `Incr`, or nested `Cutoff` inputs, `eval` first maps with `Fn.id` so the cutoff does not mutate a shared node.

Inference. Public `Bonsai.cutoff` is Incremental cutoff on a derived value. It is not a delivery API.

### Matrix: `Bonsai.cutoff` / `Value.cutoff`

| Field | Fact | Class |
|---|---|---|
| Publication trigger | None. Equal values stop downstream Incremental work | Documented BON-CONT-I. Source BON-VAL `eval` |
| Initial replay | None | Inference |
| Removal or disposal | The cutoff lives with the value node | Source BON-VAL type |
| Batching or coalescing | Equal values do not propagate | Documented |
| Order | During Incremental recompute | Source |
| Backpressure | None | Source |
| Reconnection or reactivation | Not applicable | Inference |
| Latest-value owner | The Incremental node behind the Bonsai value | Source BON-VAL `eval` |
| Transferable | Application-owned equality on derived projections | Inference |
| Non-transferable | Silent drop of a committed root output | Inference. Eta Crux `C-05` forbids that |

## Bonsai `Edge.on_change` and `Edge.on_change'`

Documented in BON-CONT-I, `module Edge`.

When a `Bonsai.t` changes, `on_change` schedules an effect. `equal` decides change. The callback always runs the first time the component becomes active. The callback runs at most once per frame. It receives the latest value.

`` `Before_display `` can react in the same frame. The callback still runs at most once per frame. If two `before_display` steps change `t`, the callback sees only one of the new values. Default trigger is `` `Before_display ``.

`on_change'` also receives the previous value. The previous value is `None` on first run.

Documented in WEB-EDGE.

When the value changes, `on_change'` runs. It also runs when the value is first calculated. Jane Street warns that `Edge` makes programs less declarative.

Source in BON-PROC, `Edge.on_change'`.

The implementation stores prior input in `state_opt`. If state is `None`, it sets `Some input` and runs `callback None input`. If state is `Some` and `phys_equal` or `equal` holds, it schedules nothing. If those tests fail, it sets the new input and runs `callback (Some state) input`. `` `Before_display `` uses `before_display'`. `` `After_display `` uses `after_display'`.

### Matrix: `Edge.on_change`

| Field | Fact | Class |
|---|---|---|
| Publication trigger | First activation, or a later unequal value, as a scheduled effect | Documented BON-CONT-I |
| Initial replay | First run always happens. Previous value is `None`. There is no log replay | Documented BON-CONT-I |
| Removal or disposal | If the `match%sub` or `assoc` branch is inactive, the Edge node is inactive | Documented WEB-LC |
| Batching or coalescing | At most one callback per frame, with the latest value | Documented BON-CONT-I |
| Order | `` `Before_display `` before view update. `` `After_display `` after Incremental and DOM update | Documented BON-CONT-I lifecycle list |
| Backpressure | None. The effect is scheduled. There is no ack | Documented type `unit Effect.t` |
| Reconnection or reactivation | State in the branch is retained. An equal value after reactivate does not schedule | Documented state retain, WEB-LC. Source compare, BON-PROC |
| Latest-value owner | `state_opt` holds the last seen input. The callback receives the current input | Source BON-PROC |
| Transferable | First snapshot, then later diffs. One notice per commit frame. Latest value only | Inference |
| Non-transferable | Application `Effect.t` as the delivery path. Same-frame `before_display` loops | Inference |

Inference about reactivation. Documented text says the callback always runs the first time the component becomes active. Source compares retained `state_opt`. An equal reactivate does not fire. This report treats "first time" as first activation, not every activation.

## Related Bonsai Edge operations

### `Edge.lifecycle`

Documented in BON-CONT-I.

`lifecycle` can attach `on_activate`, `on_deactivate`, `before_display`, and `after_display`. Most lifecycle events run at the end of the frame. Incremental updates and DOM updates run first.

`before_display` is the exception. It runs before the view update. One `before_display` effect runs at most once per frame. It can cause other `before_display` effects in the same frame.

Documented order:

1. `before_display`
2. Incremental and DOM updates
3. `on_deactivate`
4. `on_activate`
5. `after_display`

`lifecycle'` takes optional effects inside `Bonsai.t`. `before_display` and `after_display` are helpers over `lifecycle'`.

### `wait_before_display` and `wait_after_display`

Documented in BON-CONT-I.

These return an effect that blocks until the next frame start or the next frame end.

### `Edge.Poll.effect_on_change`

Documented in BON-CONT-I, `module Edge.Poll`.

It runs `~effect` each time the input changes. It stores the result as a new `Bonsai.t`. If an earlier effect completes later, a later scheduled effect still wins.

Source in BON-PROC. `effect_on_change` uses `on_change` with `` `After_display ``.

### `Edge.Poll.manual_refresh`

Documented in BON-CONT-I.

It stores the latest effect result and returns a refresh effect.

### Matrix: related Edge operations

| Field | `lifecycle` | `Poll.effect_on_change` |
|---|---|---|
| Publication trigger | Activate, deactivate, or each frame for an active node | Input change through `on_change` |
| Initial replay | If the code becomes active, `on_activate` runs. Outside control flow it runs once at start (WEB-LC) | First `on_change` run starts the first effect |
| Removal or disposal | If the branch becomes inactive, `on_deactivate` runs | The poll node becomes inactive with its branch |
| Batching or coalescing | One `before_display` run per effect per frame | Later scheduled result wins |
| Order | Documented five-step list | After display, then stored result |
| Backpressure | None | None. Out-of-order completes are reordered by schedule time |
| Reconnection or reactivation | New activate after later reactivate | Same `on_change` compare as above |
| Latest-value owner | Lifecycle collection on the driver | Stored poll result `Bonsai.t` |
| Transferable | Activate and deactivate as session edges. Strict after-commit lifecycle order | Latest-result ownership after async work |
| Non-transferable | Every-frame `after_display`. DOM-timed `before_display` | Async effect racing as a transport protocol |

Class for this table: documented BON-CONT-I and WEB-LC, plus source BON-PROC for poll trigger.

### Matrix: `wait_*` and `Poll.manual_refresh`

| Field | `wait_before_display` / `wait_after_display` | `Poll.manual_refresh` |
|---|---|---|
| Publication trigger | Caller waits for the next frame edge | Caller runs the refresh effect |
| Initial replay | None. The effect blocks until the next edge | `Starting.empty` or `Starting.initial` sets the first stored result |
| Removal or disposal | The wait effect is ordinary Bonsai effect lifetime | The stored result becomes inactive with its branch |
| Batching or coalescing | One wake per next frame edge | Latest stored result only |
| Order | Before-display or after-display of the next frame | Refresh is caller-driven |
| Backpressure | The effect blocks the caller fiber | None |
| Reconnection or reactivation | A new wait is a new effect | Same retained-state rules as other Bonsai state |
| Latest-value owner | Time source inside the driver | Stored poll result `Bonsai.t` |
| Transferable | Frame-edge wait is not a delivery ack | Explicit pull-or-refresh of a latest result |
| Non-transferable | Browser frame clock | Application-owned refresh as transport |

Class for this table: documented BON-CONT-I.

## Bonsai dynamic activation

Documented in WEB-LC.

When a branch or key becomes inactive, `match%sub` and `Bonsai.assoc` keep state. Recompute of that output pauses. The branch or key is inactive until it is selected again.

`Edge.lifecycle` sees that switch as `on_deactivate` and `on_activate`. If `lifecycle` is outside all `match%sub` and `assoc` uses, `on_activate` runs once at start. `on_deactivate` never runs.

Documented in BON-README.

Bonsai incrementalizes every value, not only the view. State is not tied to one UI component object.

Inference. Dynamic activation is graph necessity. It is not a transport reconnect.

### Matrix: dynamic activation

| Field | Fact | Class |
|---|---|---|
| Publication trigger | Control-flow switch changes which Incremental nodes are necessary | Documented WEB-LC |
| Initial replay | Reactivate resumes retained state. A reset is the only path that rebuilds from zero | Documented WEB-LC |
| Removal or disposal | Inactive code pauses. State remains. A resetter is the only clear path | Documented WEB-LC |
| Batching or coalescing | Inactive branches do not recompute | Documented WEB-LC |
| Order | Deactivate old branch, then activate new branch, after the view update | Documented BON-CONT-I and BON-DRV-I |
| Backpressure | None | Inference |
| Reconnection or reactivation | Same path and key reuse retained state | Documented WEB-LC |
| Latest-value owner | Per-path Bonsai model | Documented WEB-LC |
| Transferable | Unused projections can pause. Pause is not commit rollback | Inference |
| Non-transferable | Retained inactive models as serialized session state | Inference |

## Bonsai lifecycle collection

Source in BON-LC-I and BON-LC.

A lifecycle record has optional `on_activate`, `on_deactivate`, `before_display`, and `after_display`. The collection is a `Path.Map`.

`get_before_display ~old ~new_` keeps `before_display` effects that appear only in `new_`. Empty input returns `None`. That `None` stops the driver loop.

`get_after_display ~old ~new_` builds one `Ui_effect.Many` in this order:

1. deactivations from keys only in `old`
2. activations from keys only in `new_`
3. every `after_display` in `new_`

Source in BON-DRV, `trigger_before_display` and `trigger_lifecycles`.

`flush` applies actions, stabilizes, then loops `before_display` until none remain. Each loop can apply actions again. `trigger_lifecycles` diffs `last_lifecycle` against the current observer value. It then runs after-display clock events.

### Matrix: lifecycle

| Field | Fact | Class |
|---|---|---|
| Publication trigger | Collection diff after stabilize | Source BON-DRV |
| Initial replay | First `flush` uses empty old collection for `before_display` | Source BON-DRV `has_before_display_events` and `trigger_before_display` |
| Removal or disposal | Keys only in `old` produce `on_deactivate` | Source BON-LC |
| Batching or coalescing | One effect bundle per phase. Each `before_display` effect at most once per frame | Documented BON-CONT-I. Source BON-DRV loop |
| Order | `before_display`, then result, then deactivate, activate, after-display | Documented BON-DRV-I |
| Backpressure | None. Effects are scheduled | Source `schedule_event` |
| Reconnection or reactivation | New key in `new_` produces `on_activate` | Source BON-LC |
| Latest-value owner | Driver field `last_lifecycle` plus Incremental lifecycle observer | Source BON-DRV |
| Transferable | Post-commit lifecycle after result publication. Activate after deactivate | Inference |
| Non-transferable | Path-map identity. Same-frame `before_display` action loops | Inference |

## Bonsai stabilized result observation

Documented in BON-DRV-I.

The driver main loop is `flush`, then `result`, then `trigger_lifecycles`. `flush` applies pending actions and stabilizes. `result` returns the computed value. `trigger_lifecycles` runs deactivate, activate, and after-display. If the trigger is after display, after-display includes `on_change`.

`Expert.result_incr` is an Incremental handle on the result. `Expert.invalidate_observers` calls `disallow_future_use` on result, action input, and lifecycle observers.

Source in BON-DRV.

Create observes `result_incr`, `action_input_incr`, and `lifecycle_incr`. It then calls `Incr.stabilize` once. `result` is `Incr.Observer.value_exn`. There is no `Observer.on_update_exn` on the result. Observation is pull after stabilize.

Documented in WEB-RT.

Startup builds the graph, compiles to `Vdom.Node.t Incremental.t`, stabilizes, and attaches DOM.

The runtime frame is:

1. clock flush
2. action application
3. stabilize
4. `before_display` loop
5. DOM diff and patch
6. other lifecycles
7. next `requestAnimationFrame`

Actions from after-display lifecycles wait for the next frame.

Documented in WEB-TEST.

`Handle.recompute_view` runs one Bonsai runtime frame. `Handle.show` runs that frame and then prints the result. While lifecycle or `on_change` work remains, `Handle.recompute_view_until_stable` repeats. Jane Street calls that last helper an antipattern for product code.

### Matrix: stabilized result rendering

| Field | Fact | Class |
|---|---|---|
| Publication trigger | Pull `Observer.value_exn` after `flush` stabilize | Documented BON-DRV-I. Source BON-DRV `result` |
| Initial replay | Create stabilize computes the first result before the first frame | Source BON-DRV create |
| Removal or disposal | `invalidate_observers` disallows the three observers. Later calls can raise | Documented BON-DRV-I |
| Batching or coalescing | One result per flush. Action queue drains before that result | Documented WEB-RT |
| Order | Flush and stabilize, then result, then after-display lifecycles | Documented BON-DRV-I |
| Backpressure | None. Action queue is an unbounded `Queue.t`. Frame clock is `requestAnimationFrame` | Source BON-DRV. Documented WEB-RT |
| Reconnection or reactivation | A new driver, or observer invalidate. Not a session replace API | Documented BON-DRV-I |
| Latest-value owner | Incremental result observer. Driver does not copy a last-result field | Source BON-DRV `result` |
| Transferable | Complete stabilized result after commit, before after-commit work | Inference. Close to current Eta Crux `O-02` |
| Non-transferable | DOM patch as publication. Unbounded action queue. Frame clock | Inference |

## What Eta Crux can transfer

Eta Crux owns stabilize, atomic commit, delivery order, serialized sessions, and delivery ack. The driver is the only transport writer. Current Eta Crux already delivers one complete committed output.

These Incremental and Bonsai facts can inform later design.

1. Publication is after stabilize, never during recompute.
2. There is one notice per observer per commit.
3. Inputs that land before the commit fence coalesce.
4. First snapshot, later change, and observer death are distinct.
5. Cutoff stays inside the graph. It does not drop a committed root output.
6. Observer dispose is an explicit call, not a finalizer.
7. The publication set comes from a frozen graph. Delivery then runs. Delivery cannot start the next stabilize.
8. Latest-value pull can sit beside push notice.
9. When a projection subscription starts, a first value is published.
10. After-commit lifecycle runs after result publication.
11. Unused projections can pause without commit rollback.

## What Eta Crux cannot transfer

1. Unbounded sync callbacks with no ack.
2. Incremental necessity and invalidation as wire frames.
3. Independent Incremental observers as independent transport streams.
4. Finalizer-based close.
5. A raise in user code that poisons all later stabilize calls.
6. Bonsai `Effect.t` and `before_display` loops as the delivery path.
7. DOM frame timing and `requestAnimationFrame`.
8. Retained inactive Bonsai models as serialized session state.
9. `Unnecessary` as a client protocol tag.
10. Cutoff that suppresses committed root delivery.

## Inform later comparison

The typed-projection map requires a later comparison of four designs. Incremental and Bonsai map onto those designs as follows.

### Complete-output delivery

Bonsai `Driver.result` and Incremental `Observer.value_exn` are complete-value pull after stabilize.

This is the closest match to current Eta Crux. One advancement still publishes one complete root output.

Incremental `Changed` is only an internal hint. The complete committed output must stay.

### Notification followed by pull

`Observer.on_update_exn` is a change notice. `Observer.value_exn` is the pull of the latest stable value.

Bonsai `on_change` is weaker. It already inlines the latest value. It has no separate pull.

If Eta Crux uses notice-then-pull, Incremental says the notice must follow stabilize. The pull owner must be the driver latest committed output.

### Independent streams

Many Incremental observers can watch many nodes.

Bonsai does not expose that as transport. The driver has one result observer.

Independent streams break the Eta Crux single-writer seam and serialized session order.

### Application effects

Bonsai `Edge.on_change` is an application effect on a value change.

Jane Street documents this as a last resort. It is not the result renderer.

Application effects as delivery make the driver not the only writer. That violates the map.

## Remaining uncertainty

1. Cross-observer Incremental handler order is source stack order. It is not a documented law.
2. `on_change` on reactivate with an equal retained value does not fire in source. Public text says "first time" the component becomes active. The two statements can be read in more than one way.
3. This report did not read every Incremental unit test. The `Unnecessary` conversion for observers is taken from INC-ML and INC-OUH.
4. Bonsai web `Handle` implementation lives in `bonsai_web_test`. This report uses the Jane Street how-to and `Bonsai_driver` instead of that test file.
5. Released opam `v0.17.0` was not used as authority. Current `master` preview `v0.18~preview.130.106+341` is the cited surface.

## Self-check

Mode: pragmatic Simplified Technical English. Text class: descriptive.

Chosen nouns: publication, delivery, cutoff, observer, lifecycle. Chosen verbs: publish, stabilize, observe, dispose.

No procedure steps. No `should`, `would`, `may`, `might`, or `could` in report prose. No semicolon in report prose.

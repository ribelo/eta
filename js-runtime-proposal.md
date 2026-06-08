
# Eta on JavaScript via Melange — Design Guide

Source package used for Eta contracts and implementation details: 

## 0. Core conclusion

Eta’s **public effect value is portable in spirit**, because `Effect.t` is a lazy, runtime-interpreted value with typed success and typed failure channels. The package describes `Effect.t` as a facade over Eta’s effect algebra, structured concurrency, and observability hooks, not as an application-owned environment system. `Effect.sync` explicitly treats ordinary OCaml exceptions as unchecked defects (`Cause.Die`) and keeps runtime cancellation as interruption. 

The hard boundary is the **direct-style runtime contract**. `Runtime_contract.RUNTIME` requires operations such as:

```ocaml
val sleep : Duration.t -> unit
val await_promise : 'a promise -> 'a
val stream_take : 'a stream -> 'a
val run_scope : ?name:string -> (scope -> 'a) -> 'a
val fork : scope -> (unit -> unit) -> unit
val protect : (unit -> 'a) -> 'a
```

Those signatures are synchronous from Eta’s interpreter’s point of view. Eio can satisfy them because Eio uses OCaml 5 effect handlers to suspend and resume fibers behind ordinary-looking function calls. JavaScript cannot faithfully implement an unresolved `await_promise : 'a promise -> 'a` or `sleep : Duration.t -> unit` without transforming the Eta interpreter into async/CPS form. 

**Design decision:** implement a JavaScript backend as `eta_js` with a **JS-specific async interpreter boundary**, for example `Eta_js.Runtime.run_promise : rt -> ('a, 'err) Eta_js.Effect.t -> ('a, 'err) Exit.t Js.Promise.t`. Do not pretend the existing native `Eta.Runtime.run : rt -> eff -> Exit.t` can drive timers, promises, channels, or cancellation on JavaScript. Pure/immediate effects can have a `run_now` helper, but the meaningful subset requested here needs an async runtime.

Melange/Dune can support a JS build by enabling Melange in `dune-project`, using Melange-mode libraries, and emitting JS with `melange.emit`; Dune’s current documentation states that Melange support is enabled with `(using melange 1.0)`, libraries add `melange` to `(modes ...)`, and `melange.emit` produces JavaScript artifacts. ([Dune][1]) Melange’s compilation model is one OCaml source file to one JavaScript module, which fits an Eta runtime split into small scheduler/primitives modules. ([Melange][2])

---

## 1. Melange compilation strategy

### 1.1 Package and dune layout

**Recommended first target:** add a new optional package/library `eta_js`, not a mode flag on the existing native `eta` package.

```lisp
; dune-project
(lang dune 3.23)
(using melange 1.0)
```

```lisp
; lib/js/dune
(library
 (name eta_js)
 (public_name eta_js)
 (modes melange)
 (synopsis "JavaScript runtime backend and Melange-compatible Eta subset"))

(melange.emit
 (target eta_js_dist)
 (module_systems (es6 mjs))
 (libraries eta_js))
```

[must-have] All Melange dependencies in the `melange.emit` closure must themselves support Melange mode; Dune documents that Melange libraries must add `melange` to `(modes ...)`, and that `melange.emit` dependencies must support Melange mode. ([Dune][1])

[must-have] Keep `lib/eio`, `lib/blocking` native worker implementations, and current `lib/stream` Eio file/stream sources out of the Melange closure.

[should-have] Use `eta_js` first to avoid destabilizing native `eta`. Once the JS interpreter is proven, factor shared pure modules into a dual-mode library and expose a consistent `Eta` surface for Melange.

### 1.2 Module classification

| Area                                                                                             |                         Status for Melange | Reason                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------ | -----------------------------------------: | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Duration`, `Exit`, `Schedule`, `String_helpers`, `Log_level`, `Sampler`, `Trace_context`        |                        mostly source-share | Pure data/logic. `Schedule` is pure and exposes stateful drivers with `start`/`next`.                                                                                                           |
| `Cause`                                                                                          |         source-share with diagnostics shim | The public `Die` payload contains `Printexc.raw_backtrace option`; JS can set `None` or capture a JS `Error.stack` through a JS-specific exception wrapper. Cause shape must remain unchanged.  |
| `Capabilities.random`, `Mutable_ref`, `Sync_lock`, runtime counters                              |                                      adapt | Current code uses `Atomic`. In single-thread JS, use mutable fields; no spin locks.                                                                                                             |
| `Effect_core`, `Runtime_core`, `Effect_concurrent`, `Effect_resource`, `Effect_supervisor_scope` |                       rewrite/adapt deeply | Current interpreter is direct style and calls `sleep`, `await_promise`, `fiber_await_cancel`, and `run_scope` synchronously.                                                                    |
| `Channel`, `Queue`, `PubSub`, `Semaphore`, `Pool`                                                | rewrite wait path, preserve state machines | Their contracts are valid on JS, but waiter blocking must become scheduler suspension rather than native/Eio blocking.                                                                          |
| `Resource`                                                                                       |      mostly reusable once runtime is async | `manual`, `auto`, `get`, `refresh`, and `failures` are effect-level logic; `auto` relies on daemon and schedule.                                                                                |
| `Supervisor` / `Runtime_supervisor`                                                              |         adapt atomics and child scheduling | Rank-2 public scope design is reusable; child promises/cancel handles must be JS scheduler objects.                                                                                             |
| `lib/eio`                                                                                        |          exclude/rewrite as reference only | It is the native Eio backend.                                                                                                                                                                   |
| `lib/blocking`                                                                                   |               replace with JS async bridge | Current package is explicitly for native blocking worker pools.                                                                                                                                 |
| `lib/stream`                                                                                     |                                      split | Pure stream AST/operators can be reused; Eio streams, file I/O, mailbox, and drain counter need JS implementations.                                                                             |
| `lib/test`                                                                                       |                                    rewrite | Current helpers depend on Eio, Eio_main, and Alcotest; preserve concepts, not implementation.                                                                                                   |

### 1.3 OCaml 5 / native assumptions to remove

[must-have] **OCaml 5 effect-handler substrate:** Eta itself mostly describes effects as an AST, but `eta_eio` satisfies the runtime contract through Eio `Switch`, `Fiber`, `Promise`, `Stream`, and `Cancel`. The Eio backend directly maps `sleep`, `fork`, `await_cancel`, `yield`, `check`, `create_promise`, `await_promise`, and stream operations to Eio operations. 

[must-have] **Direct-style waits:** `Effect.delay`, `timeout_as`, `repeat`, and `retry` call `frame.runtime.sleep` synchronously in the current interpreter. On JS these must become scheduler suspension points. 

[must-have] **Atomics and spin locks:** `Sync_lock`, `Runtime_core`, `Runtime_supervisor`, `Effect_concurrent`, `Semaphore`, `Portable_queue`, `Capabilities.random`, and blocking pools use `Atomic`. In JS main-thread execution, state changes are atomic within one turn of the event loop; replace CAS loops with ordinary mutation and never busy-wait.

[must-have] **Domains / DLS / threads:** `eta_eio.ml` uses `Domain.DLS`, `Thread`, `Mutex`, and `Eio_unix.run_in_systhread` for native worker and fiberless context support. JS uses scheduler-owned fiber-local maps and optional Web Worker bridges, not native threads.

[nice-to-have] Preserve `Obj` erasure boundaries only where Eta already uses them: runtime contract erasure, effect erasure, and typed-failure packing. Do not introduce ad hoc `Obj.magic` sites.

---

## 2. JavaScript runtime backend

### 2.1 Existing runtime contract

The native authoring surface is:

```ocaml
module type RUNTIME = sig
  type scope
  type cancel_context
  type 'a promise
  type 'a resolver
  type 'a stream

  val root_scope : scope
  val now_ms : unit -> int
  val sleep : Duration.t -> unit
  val protect : (unit -> 'a) -> 'a
  val run_scope : ?name:string -> (scope -> 'a) -> 'a
  val fail_scope : ?bt:Printexc.raw_backtrace -> scope -> exn -> unit
  val fork : scope -> (unit -> unit) -> unit
  val fork_daemon : scope -> (unit -> [ `Stop_daemon ]) -> unit
  val await_cancel : unit -> 'a
  val yield : unit -> unit
  val check : unit -> unit
  val create_promise : unit -> 'a promise * 'a resolver
  val resolve_promise : 'a resolver -> 'a -> unit
  val await_promise : 'a promise -> 'a
  val create_stream : int -> 'a stream
  val stream_add : 'a stream -> 'a -> unit
  val stream_take : 'a stream -> 'a
  val stream_take_nonblocking : 'a stream -> 'a option
  val with_worker_context : (unit -> 'a) -> 'a
  val in_worker_context : unit -> bool
  val cancellation_reason : exn -> exn option
  val multiple_exceptions : exn -> (exn * Printexc.raw_backtrace) list option
  val cancel_sub : (cancel_context -> 'a) -> 'a
  val cancel : cancel_context -> exn -> unit
  val local_get : 'a local -> 'a option
  val local_with_binding : 'a local -> 'a -> (unit -> 'b) -> 'b
end
```

Eta says this module-shaped backend is the typed authoring surface for runtime packages; the erased record is the interpreter representation. 

### 2.2 JS-compatible contract shape

[must-have] Introduce a JS async contract. The smallest useful shape is:

```ocaml
type 'a task
type 'a promise
type 'a resolver

module type JS_RUNTIME = sig
  type scope
  type cancel_context
  type 'a stream

  val root_scope : scope
  val now_ms : unit -> int

  val sleep : Duration.t -> unit task
  val protect : (unit -> 'a task) -> 'a task
  val run_scope : ?name:string -> (scope -> 'a task) -> 'a task
  val fail_scope : scope -> exn -> unit

  val fork : scope -> (unit -> unit task) -> unit
  val fork_daemon : scope -> (unit -> [ `Stop_daemon ] task) -> unit
  val await_cancel : unit -> 'a task
  val yield : unit -> unit task
  val check : unit -> unit

  val create_promise : unit -> 'a promise * 'a resolver
  val resolve_promise : 'a resolver -> 'a -> unit
  val await_promise : 'a promise -> 'a task

  val create_stream : int -> 'a stream
  val stream_add : 'a stream -> 'a -> unit task
  val stream_take : 'a stream -> 'a task
  val stream_take_nonblocking : 'a stream -> 'a option

  val local_get : 'a Runtime_contract.local -> 'a option
  val local_with_binding :
    'a Runtime_contract.local -> 'a -> (unit -> 'b task) -> 'b task
end
```

[must-have] The public JS runtime should resolve a JavaScript promise:

```ocaml
val run_promise :
  'err Eta_js.Runtime.t ->
  ('a, 'err) Eta_js.Effect.t ->
  ('a, 'err) Eta.Exit.t Js.Promise.t
```

[should-have] Provide `run_now` only for effects that complete without suspension:

```ocaml
val run_now :
  'err Eta_js.Runtime.t ->
  ('a, 'err) Eta_js.Effect.t ->
  ('a, 'err) Eta.Exit.t option
```

`None` means the effect attempted to sleep, await, yield, fork-and-join, or use a blocking primitive.

### 2.3 Fiber representation

Do **not** use JS `async/await` as the whole runtime model. It is acceptable at the outer boundary, but Eta needs scopes, cancellation protection, local context propagation, finalizer ordering, daemon drain accounting, and deterministic testing hooks.

Use a custom cooperative scheduler.

```ocaml
type fiber_status =
  | Ready
  | Waiting
  | Done
  | Cancelled of exn

type scope = {
  id : int;
  parent : scope option;
  mutable closing : bool;
  mutable cancel_reason : exn option;
  mutable children : fiber list;
}

and fiber = {
  id : int;
  scope : scope;
  mutable status : fiber_status;
  mutable locals : (int, Obj.t) Hashtbl.t;
  mutable protect_depth : int;
  mutable cancel_reason : exn option;
  mutable kont : kont;
}

and kont =
  | K_done
  | K_eval : ('a, 'err) Effect_core.t * Obj.t list -> kont
  | K_resume : (Obj.t -> step) -> kont

and step =
  | Complete of Obj.t
  | Failed of exn
  | Suspend
```

[must-have] A fiber is the unit of cancellation, local context, finalizer stack, and scheduler fairness.

[must-have] A blocking Eta operation never blocks the JS call stack. It registers the fiber continuation with a timer, promise, stream, channel, or queue waiter, then returns to the scheduler.

[must-have] `yield` requeues the current fiber behind already-ready fibers. Use `queueMicrotask` for ordinary continuation and occasionally a macrotask to avoid starving browser rendering or Node timers.

JS interop stubs:

```ocaml
type timeout_id

external date_now : unit -> float = "Date.now" [@@mel.val]
external set_timeout :
  (unit -> unit) -> int -> timeout_id = "setTimeout" [@@mel.val]
external clear_timeout :
  timeout_id -> unit = "clearTimeout" [@@mel.val]
external queue_microtask :
  (unit -> unit) -> unit = "queueMicrotask" [@@mel.val]
```

Melange’s interop model is based on OCaml `external` declarations plus Melange attributes such as `mel.val`, `mel.module`, `mel.send`, `mel.new`, and record/field mapping attributes. ([Melange][3])

### 2.4 Scheduler loop

```ocaml
let ready : fiber Queue.t = Queue.create ()
let draining = ref false

let enqueue fiber =
  if fiber.status <> Done then Queue.add fiber ready;
  if not !draining then (
    draining := true;
    queue_microtask drain
  )

and drain () =
  let budget = ref 1024 in
  while !budget > 0 && not (Queue.is_empty ready) do
    decr budget;
    step_fiber (Queue.take ready)
  done;
  if Queue.is_empty ready then draining := false
  else queue_microtask drain
```

[must-have] Scheduler steps are run-to-suspension. A fiber may mutate primitive state freely during one step because no other fiber runs until it returns.

[should-have] Add a fairness budget. After N steps, yield to a macrotask so timers, I/O promise callbacks, and UI work can run.

[nice-to-have] Expose deterministic test hooks: `drain_ready`, `ready_count`, `timer_count`.

### 2.5 Mapping `perform` / `continue`

Eta does not expose direct OCaml `perform` in the public API here; the native backend relies on Eio to suspend in direct style. The JS equivalent is:

| Native/Eio idea         | JS runtime mapping                                                   |
| ----------------------- | -------------------------------------------------------------------- |
| `perform sleep`         | register timer, mark fiber waiting, return to scheduler              |
| `perform await_promise` | add continuation to one-shot promise waiters                         |
| `continue k v`          | resolver/timer enqueues fiber with value `v`                         |
| `discontinue k exn`     | enqueue fiber with cancellation/defect exception                     |
| `Eio.Cancel.protect`    | increment `protect_depth`; defer cancellation throw until exit/check |
| `Eio.Switch.fail`       | mark scope closing, cancel children, wake waiters                    |

[must-have] Do not resume a continuation twice. One-shot promise resolution must be idempotent or fail loudly.

[must-have] Do not throw raw JS cancellation exceptions as ordinary defects. Only exceptions recognized by `cancellation_reason` become `Cause.Interrupt`; bare user exceptions stay `Cause.Die`, matching native `Runtime_core.cause_of_exn`. 

### 2.6 Cancellation propagation

```ocaml
exception Js_cancelled of exn

let cancel_fiber fiber reason =
  match fiber.status with
  | Done -> ()
  | _ ->
      fiber.cancel_reason <- Some reason;
      if fiber.protect_depth = 0 then enqueue fiber

let check fiber =
  match fiber.cancel_reason, fiber.protect_depth with
  | Some reason, 0 -> raise (Js_cancelled reason)
  | _ -> ()
```

[must-have] Cancellation is cooperative. A long synchronous `Effect.sync` callback blocks the JS event loop and cannot be preempted. Cleanup runs only after that callback returns or yields through an Eta-aware async primitive.

[must-have] Cancelling a scope cancels all child fibers registered under that scope. `run_scope` must wait for child settlement and finalizers before completing the parent continuation.

[must-have] `protect` must defer cancellation around finalizers and `uninterruptible`.

[should-have] `cancel_sub` should install a cancellable child context for the current fiber; `cancel` records a reason and wakes the fiber if it is waiting.

### 2.7 Runtime-local context

The Eio backend uses fiber keys and a fallback `Domain.DLS` context when no Eio fiber exists. The JS runtime should use only scheduler-owned fiber locals.

```ocaml
let local_get fiber key =
  Hashtbl.find_opt fiber.locals (Runtime_contract.Backend.local_id key)
  |> Option.map Obj.obj

let local_with_binding fiber key value body =
  let id = Runtime_contract.Backend.local_id key in
  let old = Hashtbl.find_opt fiber.locals id in
  Hashtbl.replace fiber.locals id (Obj.repr value);
  Task.finally
    (fun () ->
      match old with
      | None -> Hashtbl.remove fiber.locals id
      | Some v -> Hashtbl.replace fiber.locals id v)
    body
```

[must-have] Child fibers receive a copy of parent locals at `fork`.

[must-have] Dynamic bindings restore after async completion, not merely after returning from the immediate OCaml function.

[should-have] Observability spans and trace context must use these locals; current tracer/logging relies on `Runtime_contract.local_get` and `local_with_binding`.

---

## 3. Critical invariants from the Eio runtime to preserve

The Eio runtime implementation binds Eta’s logical contract to Eio’s clock, switches, fibers, promises, streams, cancellation, and fiber-local context. It sets `root_scope`, `now_ms`, `sleep`, `run_scope`, `fail_scope`, `fork`, `fork_daemon`, `await_cancel`, `yield`, `check`, `create_promise`, `await_promise`, stream operations, cancellation recognition, and locals. 

[must-have] **Scope ownership:** every child fiber is owned by a scope; scope exit cancels/waits children.

[must-have] **Cancellation recognition:** only backend cancellation exceptions map to `Cause.Interrupt`. User exceptions must remain `Cause.Die`.

[must-have] **Protection:** finalizers and `uninterruptible` must run with cancellation deferred.

[must-have] **One-shot promises:** `create_promise`/`resolve_promise`/`await_promise` must not lose wakeups; resolving a promise wakes all or exactly the registered waiter set according to the promise kind.

[must-have] **Bounded streams:** `create_stream capacity`, `stream_add`, and `stream_take` are the internal result handoff used by `race`, `merge`, and parallel stream operators. The JS equivalent must provide backpressure or explicit buffering semantics.

[must-have] **Locals:** runtime locals are task/fiber-local, inherited by child fibers, and dynamically scoped.

[should-have] **Multiple exception aggregation:** native `multiple_exceptions` maps Eio multiple failures into `Cause.concurrent`. JS can approximate by constructing a runtime-owned `Multiple` exception when a scope observes several failures before settlement.

[should-have] **Daemon drain accounting:** `Effect.daemon` increments runtime active count and `Runtime.drain` waits until active daemon work reaches zero. The current `Runtime_core` has explicit active counters and drain waiters. 

---

## 4. Effect system, failures, exits, causes

### 4.1 Contracts to keep

[must-have] `Effect.t` keeps typed success and typed failure: `('a, 'err) Effect.t`.

[must-have] `Effect.sync` exceptions become `Cause.Die`, not typed failures; cancellation remains interruption.

[must-have] `catch` catches typed `Cause.Fail` only. It must not catch defects, interruption, or finalizer diagnostics. The public documentation explicitly states this behavior. 

[must-have] `race`, `par`, `all`, and `all_settled` preserve Eta semantics: race cancels losers; `par`/`all` are fail-fast; `all_settled` returns child outcomes in input order. 

[must-have] `Cause` shape is unchanged: `Fail`, `Die`, `Interrupt`, `Sequential`, `Concurrent`, `Finalizer`, and `Suppressed`. 

### 4.2 Interpreter rewrite

The current internal interpreter is direct recursive evaluation over `Pure`, `Fail`, `Custom`, `Map`, and `Bind`; `eval` returns `Exit.t` immediately. 

[must-have] JS interpreter must become stack-safe and async-aware:

```ocaml
type packed_eff = Eff : ('a, 'err) Effect_core.t -> packed_eff

type frame_stack =
  | Done
  | Map : ('a -> 'b) * frame_stack -> frame_stack
  | Bind : ('a -> ('b, 'err) Effect_core.t) * frame_stack -> frame_stack

type eval_state = {
  mutable current : packed_eff;
  mutable stack : frame_stack;
}
```

[must-have] `Custom` leaves that may suspend must be rewritten. Existing `Custom.eval : frame -> Exit.t` cannot call async wait points and resume its own OCaml stack.

[should-have] Keep pure `Pure`/`Fail`/`Map`/`Bind` layout if possible, so existing effect construction APIs remain familiar.

[nice-to-have] Add a JS-only expert operation:

```ocaml
val async_leaf :
  ?name:string ->
  (Eta_js.Expert.context -> ('a, 'err) Eta_js.Task.t) ->
  ('a, 'err) Eta_js.Effect.t
```

This replaces direct-style `Expert.make` for JS runtime leaves.

---

## 5. Concurrency primitives on JS

### 5.1 Channel

Source contract excerpt:

```ocaml
val create : capacity:int -> unit -> ('a, 'err) t
val send :
  ('a, 'err) t ->
  'a ->
  (unit, [> `Closed | `Closed_with_error of 'err ]) Effect.t
val recv :
  ('a, 'err) t -> ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t
val try_send : ('a, 'err) t -> 'a -> ('err send_result, 'never) Effect.t
val try_recv : ('a, 'err) t -> (('a, 'err) recv_result, 'never) Effect.t
val close : ('a, 'err) t -> unit
val close_with_error : ('a, 'err) t -> 'err -> unit
```

The source states that Channel is same-domain, bounded, backpressured, FIFO for buffered values, FIFO for active blocked senders, and that cancelled senders are removed before admission. 

JS sketch:

```ocaml
type 'err close_reason = Clean | Error of 'err

type ('a, 'err) sender = {
  value : 'a;
  resume : 'err send_result -> unit;
  mutable active : bool;
}

type ('a, 'err) t = {
  capacity : int;
  buffer : 'a Queue.t;
  senders : ('a, 'err) sender Queue.t;
  receivers : (('a, 'err) recv_result -> unit) Queue.t;
  mutable closed : 'err close_reason option;
}
```

```ocaml
let send t value =
  Effect_js.async_leaf @@ fun ctx k ->
    match admit_or_enqueue_sender ctx t value k with
    | `Ready result -> k result
    | `Suspended cancel_waiter ->
        Expert.on_cancel ctx cancel_waiter
```

[must-have] Register waiter and observe full/empty/closed state in one scheduler step. No lost wakeups.

[must-have] Cancellation while a sender is waiting removes the sender and increments `cancelled_senders`.

[must-have] Closing wakes senders and receivers; buffered values remain drainable before receivers observe close.

[should-have] Preserve fixed-capacity ring buffer for native-like statistics and predictable memory.

### 5.2 Queue

Queue is same-domain, unbounded, and owns the close fence: sends are rejected after close, but buffered values remain drainable before receivers see the close reason. 

[must-have] Implement `send` as immediate enqueue-or-fail.

[must-have] Implement `recv` as dequeue-or-suspend.

[must-have] `try_recv` never suspends.

[must-have] `close` and `close_with_error` are idempotent; first reason wins.

JS sketch:

```ocaml
let recv t =
  Effect_js.async_leaf @@ fun ctx k ->
    match Queue.take_opt t.values, t.closed with
    | Some v, _ -> k (`Item v)
    | None, Some Clean -> k `Closed
    | None, Some (Error e) -> k (`Closed_with_error e)
    | None, None ->
        let waiter = { resume = k; active = true } in
        Queue.add waiter t.receivers;
        Expert.on_cancel ctx (fun () -> waiter.active <- false)
```

### 5.3 Semaphore

Source contract includes cancellation-safe acquire, release bounds, `with_permits`, and `with_permits_or_abort`; the latter guarantees permit lifetime is scoped to `f` and releases on success, typed failure, defect, abort, or cancellation, including discarded outer race results. 

[must-have] Preserve the native waiter state machine:

```ocaml
type waiter_state =
  | Waiting
  | Resolved_unclaimed
  | Claimed
  | Cancelled
```

[must-have] If cancellation happens after a waiter was granted permits but before the fiber claims them, return permits to `available`.

[must-have] `release` must wake FIFO waiters whose requested permits fit.

[should-have] In JS, no lock is needed, but keep a single `wake_waiters` function that is called after every release/cancel to preserve native reasoning.

### 5.4 PubSub

PubSub retains each published message until all current subscribers receive it or unsubscribe; late subscribers do not receive earlier messages. `Backpressure` waits for capacity and cancellation while waiting removes the publisher before admission. 

[must-have] Keep entries with `seq`, `value`, and `remaining`.

[must-have] Subscription lifetime is scoped; on release, decrement `remaining` for all entries at or after the subscription cursor.

[must-have] For `Backpressure`, a cancelled publisher must not partially publish.

[must-have] Closed hubs wake waiting publishers and receivers; buffered messages remain drainable.

### 5.5 Pool

Pool is same-runtime, bounded, and owns resource checkout/release. It is not a cross-domain handoff primitive; idle resources are LIFO, waiting acquirers are cancellation-safe, and shutdown closes idle resources and waits for checked-out resources. 

[must-have] Keep Pool on top of JS Semaphore. The pool’s resource count includes idle, checked-out, opening, and closing resources.

[must-have] `with_resource` must scope resource ownership to the body and release on success, typed failure, defect, or cancellation.

[must-have] Shutdown sets a close fence, wakes pending acquirers with `Pool_shutdown`, closes idle resources, and waits for active count to reach zero.

[should-have] Replace current 1ms polling drain with active waiters resolved on active-count decrement. The native implementation polls with `Effect.delay (Duration.ms 1)`; JS can do better without changing observable behavior. 

---

## 6. Resource safety

### 6.1 Bracket/finalizer contract

Source contract excerpt:

```ocaml
val finally : (unit, 'cleanup_err) t -> ('a, 'err) t -> ('a, 'err) t
val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a, 'err) t
val acquire_use_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
val scoped : ('a, 'err) t -> ('a, 'err) t
```

The source requires cleanup on success, typed failure, unchecked defect, or cancellation; cleanup runs in a cancellation-protected frame; cleanup failure after success becomes `Cause.Finalizer`; cleanup failure after primary failure becomes `Cause.Suppressed`. 

Current `Runtime_core.with_finalizers` implements exactly that suppression/finalizer logic. 

[must-have] JS finalizers are LIFO and async-aware.

[must-have] Finalizers run under `protect`.

[must-have] If a finalizer returns a rejected JS promise or raises, convert it through the same `cause_of_exn` path as native defects/typed raises.

[must-have] Parent cancellation waits for finalizers. Cancellation can be recorded while protected, but not thrown until finalizers finish.

[should-have] If a finalizer never resolves, the scope remains pending. This is correct; add diagnostics rather than forcibly dropping cleanup.

### 6.2 Cached `Resource`

Source contract excerpt:

```ocaml
val manual :
  ('a, 'err) Effect.t ->
  (('a, 'err) t, 'err) Effect.t

val auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:Schedule.t ->
  unit ->
  (('a, 'err) t, 'err) Effect.t

val get : ('a, 'err) t -> ('a, 'err) Effect.t
val refresh : ('a, 'err) t -> (unit, 'err) Effect.t
val failures : ('a, 'err) t -> ('err Cause.t list, 'outer_err) Effect.t
```

`Resource.auto` seeds once, refreshes in a runtime-owned background fiber, keeps the last good value on refresh failure, records failures, and continues after typed failures and defects. 

JS sketch:

```ocaml
let auto ~load ~schedule ?random ?on_error () =
  let* initial = load in
  let resource = loaded load initial in
  let rec loop driver =
    match Schedule.next driver with
    | None -> Effect.unit
    | Some (delay, driver') ->
        Effect.delay delay
          (Effect.all_settled [ refresh resource ])
        >>= fun results ->
        record_refresh_outcome resource on_error results >>= fun () ->
        loop driver'
  in
  Effect.daemon (loop (Schedule.start ?random schedule))
  |> Effect.map (fun () -> resource)
```

[must-have] `auto` refresh daemon must be included in JS `Runtime.drain_promise`.

[must-have] Refresh updates cache only after loader success.

[must-have] `on_error` defects are recorded as additional defects and do not stop the loop.

---

## 7. Schedule and retry/repeat

The schedule contract is pure: `Schedule.t` describes recurrence, `start` creates a driver, and `next` returns `(delay, next_driver)` or `None`. 

[must-have] Reuse schedule semantics unchanged.

[must-have] Replace `Capabilities.random` atomics with a JS single-thread mutable seed, but keep deterministic seeded behavior.

[must-have] `retry` retries only typed `Cause.Fail err` when the predicate accepts it; defects and interruption do not retry.

JS retry sketch:

```ocaml
let retry schedule predicate eff =
  Effect_js.custom @@ fun frame ->
    let rec loop driver =
      Eval.run_scope frame eff >>= function
      | Exit.Ok _ as ok -> Task.pure ok
      | Exit.Error (Cause.Fail err) when predicate err -> (
          match Schedule.next driver with
          | None -> Task.pure (Exit.Error (Cause.Fail err))
          | Some (delay, driver') ->
              Runtime.sleep frame.runtime delay >>= fun () ->
              loop driver')
      | Exit.Error _ as err -> Task.pure err
    in
    loop (Schedule.start ~random:frame.runtime.random schedule)
```

[should-have] Test jitter with explicit seeds only; do not rely on wall-clock default random in deterministic tests.

---

## 8. Supervisor scope

The public supervisor API uses a rank-2 body so child handles cannot escape the scope. `Supervisor.Scope.start` starts a child under a supervisor; `await` re-enters its typed error channel; `cancel` cancels and waits; `failures` returns observed child failures; `check` fails after a configured threshold. 

[must-have] Preserve the rank-2 API shape.

[must-have] JS child handle = one-shot promise of `('a, 'err Cause.t) result` plus `cancel : unit -> unit`.

[must-have] `supervisor_scoped` creates a child scope and cancels all live children in its finalizer.

[must-have] Child failures are recorded on the supervisor and do not fail the parent unless awaited or `check` is called.

[should-have] Same-domain JS observation order should be scheduler settlement order. Because JS is single-threaded, this is deterministic under the scheduler.

[nice-to-have] Provide dev-mode leak diagnostics if a child is still registered when the supervisor finalizer begins.

---

## 9. Streams on JS

The stream API is pull-based and chunked. It includes pure constructors/operators, concurrent `merge`, `flat_map_par`, queue/mailbox sources, Eio stream bridges, file sources, mailboxes, drain counters, sinks, and `run`/`run_collect`/`run_drain`. 

### 9.1 What can remain

[should-have] Keep pure stream constructors and transformations: `empty`, `succeed`, `from_chunk`, `from_iterable`, `range`, `map`, `filter`, `take`, `drop`, `scan`, `grouped`, `concat`, `flat_map`.

[must-have] Rewrite `merge` and `flat_map_par` to use Eta_js scheduler streams/queues instead of `Eio.Stream`.

[must-have] `from_queue` should use JS Eta Queue semantics: clean close ends stream; `close_with_error err` fails stream with `err`.

### 9.2 Mailbox

Current mailbox uses `Eio.Mutex`, `Eio.Condition`, and blocking `take`. 

JS mailbox sketch:

```ocaml
type 'a mailbox = {
  capacity : int;
  values : 'a Queue.t;
  takers : ('a take -> unit) Queue.t;
  mutable closed : bool;
  mutable dropped : int;
}

let offer m value =
  if m.closed then Closed
  else if Queue.length m.values >= m.capacity then (
    m.dropped <- m.dropped + 1;
    Dropped
  ) else (
    Queue.add value m.values;
    wake_one_taker m;
    Enqueued
  )
```

[must-have] `offer` is synchronous and never waits.

[must-have] Full mailbox drops the new value, not an old value.

[must-have] `close` wakes takers; consumers drain existing values before stream end.

### 9.3 Drain counter

Current drain counter waits on `Eio.Condition` until `count = 0`. 

JS sketch:

```ocaml
type t = {
  mutable count : int;
  waiters : (unit -> unit) Queue.t;
}

let decr_by t n =
  if n < 0 || n > t.count then invalid_arg "Drain_counter.decr_by";
  t.count <- t.count - n;
  if t.count = 0 then wake_all t.waiters

let await_zero t =
  if t.count = 0 then Effect.unit
  else Effect_js.async_leaf (fun _ctx k -> Queue.add k t.waiters)
```

[must-have] Underflow remains an immediate `Invalid_argument`.

[must-have] `await_zero` must not poll.

### 9.4 File and JS streams

[must-have] `from_eio_stream` is unavailable in JS.

[should-have] Replace with `from_js_readable` for WHATWG `ReadableStream` and/or Node streams.

[should-have] Replace `from_file` with separate browser `File`/`Blob` and Node `fs/promises` adapters. Do not keep `Eio.Path` or `Cstruct` in the Melange surface.

---

## 10. Blocking runtime bridge

The native `eta_blocking` package is explicitly for synchronous calls that a native runtime can offload to a worker substrate; the source notes that runtime packages such as `eta_eio` provide the worker runner, and the `Pool.runner` is `run_worker : label:string -> (unit -> 'a) -> 'a`. 

[must-have] Do not implement native `Eta_blocking.run` on the JS main thread as “real blocking.” Running a long synchronous callback blocks the event loop, prevents timers/promises from resolving, and prevents cooperative cancellation.

[must-have] Provide a JS async bridge instead:

```ocaml
val await_promise :
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a Js.Promise.t) ->
  ('a, 'err) Eta_js.Effect.t
```

[should-have] Provide an `AbortController`-style helper:

```ocaml
type abort_controller
type abort_signal

external make_abort_controller :
  unit -> abort_controller = "AbortController" [@@mel.new] [@@mel.val]

external signal :
  abort_controller -> abort_signal = "signal" [@@mel.get]

external abort :
  abort_controller -> unit = "abort" [@@mel.send]
```

```ocaml
val await_abortable :
  ?name:string ->
  (abort_signal -> ('a, 'err) result Js.Promise.t) ->
  ('a, 'err) Eta_js.Effect.t
```

[must-have] Cancellation calls the abort hook at most once.

[must-have] Promise rejection that is not cancellation becomes `Cause.Die` unless the adapter maps it into a typed error.

[should-have] Keep metrics/tracing field names compatible with `eta.blocking.*`, but report it as `eta.async` or `eta.js.promise` to avoid implying off-main-thread blocking.

[nice-to-have] Web Worker offload can be a separate package. It is not Eta.Par, because values must be serialized and workers are not same-heap fibers.

---

## 11. Testing strategy

### 11.1 Port the concepts from `Eta_test`

The current test helpers provide a virtual clock, runtime constructors with in-memory logger/tracer, async fork helpers, cause-aware expectations, and deterministic random. 

[must-have] Create `eta_js_test` with:

```ocaml
module Test_clock : sig
  type t
  val create : unit -> t
  val sleep : t -> Duration.t -> unit Eta_js.Task.t
  val adjust : t -> Duration.t -> unit Eta_js.Task.t
  val set_time : t -> int -> unit Eta_js.Task.t
  val sleeper_count : t -> int
end
```

[must-have] `adjust` wakes sleepers in `(deadline_ms, sequence)` order, then drains the scheduler ready queue.

[must-have] Tests must return JS promises to the runner.

```ocaml
val run_test :
  string ->
  (unit -> unit Js.Promise.t) ->
  unit
```

[should-have] Mirror `Expect.expect_ok`, `expect_typed_failure`, `expect_die`, and `expect_interrupt`.

[should-have] Run tests in Node first. Browser tests can come after timers and microtasks are deterministic.

### 11.2 Required test matrix

[must-have] Pure algebra: `Cause`, `Exit`, `Duration`, `Schedule`, `Trace_context`, deterministic random.

[must-have] Runtime: `pure`, `fail`, `sync` defects, `delay`, `timeout_as`, `retry`, `repeat`, `uninterruptible`, cancellation check/yield.

[must-have] Concurrency: `race` winner cancels losers; loser finalizer failure is surfaced; `par` fail-fast; `all_settled` preserves input order.

[must-have] Primitives: Channel close fences, sender cancellation, receiver cancellation, FIFO; Queue close drain; Semaphore resolved-unclaimed cancellation; PubSub backpressure cancellation; Pool release on cancellation.

[must-have] Resource safety: finalizer after success, finalizer after typed failure, finalizer after cancellation, finalizer defect suppression.

[should-have] Supervisor: child failure recording, `await`, `cancel`, `max_failures`.

[should-have] Streams: pure fusion, mailbox drops, merge cancellation, `flat_map_par` max concurrency.

---

## 12. Minimal code snippets by major contract

### 12.1 Runtime

Source signature:

```ocaml
val create_with_runtime :
  (module Runtime_contract.RUNTIME) ->
  ?sleep:(Duration.t -> unit) ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?services:Runtime_contract.service list ->
  ?capture_backtrace:bool ->
  unit ->
  'err t

val run : 'err t -> ('a, 'err) Effect.t -> ('a, 'err) Exit.t
val run_exn : 'err t -> ('a, 'err) Effect.t -> 'a
val drain : 'err t -> unit
```

Eta’s native runtime constructors consume `Runtime_contract.RUNTIME`, and `run` returns an `Exit.t` synchronously. 

JS sketch:

```ocaml
type 'err t = {
  scheduler : Scheduler.t;
  root_scope : Scheduler.scope;
  tracer : Capabilities.tracer;
  random : Capabilities.random;
}

let run_promise rt eff =
  Scheduler.spawn_root rt.scheduler rt.root_scope eff
  |> Scheduler.promise_of_fiber

let drain_promise rt =
  Scheduler.await_daemon_zero rt.scheduler
```

Interop stubs:

```ocaml
external queue_microtask : (unit -> unit) -> unit =
  "queueMicrotask" [@@mel.val]

external date_now : unit -> float =
  "Date.now" [@@mel.val]
```

### 12.2 Fiber

Source reference from the Eio host abstraction:

```ocaml
module type FIBER = sig
  val get : 'a Eio.Fiber.key -> 'a option
  val with_binding : 'a Eio.Fiber.key -> 'a -> (unit -> 'b) -> 'b
  val await_cancel : unit -> 'a
  val fork : sw:Eio.Switch.t -> (unit -> unit) -> unit
  val fork_daemon : sw:Eio.Switch.t -> (unit -> [ `Stop_daemon ]) -> unit
  val yield : unit -> unit
  val check : unit -> unit
end
```

The JS equivalent should not expose Eio keys; it should implement the logical behavior with scheduler locals, cancellation, fork, daemon fork, yield, and check. 

JS sketch:

```ocaml
let fork scope body =
  let child = Fiber.create ~scope ~locals:(Fiber.copy_locals current) body in
  Scope.add_child scope child;
  Scheduler.enqueue child

let yield () =
  Task.suspend (fun resume ->
    Scheduler.enqueue_continuation current resume)

let check () =
  match Fiber.cancel_reason current with
  | None -> ()
  | Some reason when Fiber.protected current -> ()
  | Some reason -> raise (Js_cancelled reason)
```

### 12.3 Channel

Source signature excerpt already shown in section 5.1. 

JS sketch:

```ocaml
let try_send t value =
  Effect.sync @@ fun () ->
    match t.closed with
    | Some Clean -> `Closed
    | Some (Error e) -> `Closed_with_error e
    | None when Queue.length t.buffer < t.capacity ->
        Queue.add value t.buffer;
        wake_one_receiver t;
        `Sent
    | None -> `Full

let send t value =
  try_send t value >>= function
  | `Sent -> Effect.unit
  | `Closed -> Effect.fail `Closed
  | `Closed_with_error e -> Effect.fail (`Closed_with_error e)
  | `Full -> await_send_slot t value
```

[must-have] `await_send_slot` is not `Effect.sync`; it is an async/suspending Eta_js leaf.

### 12.4 Resource / bracket

Source signatures:

```ocaml
val acquire_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a, 'err) t

val acquire_use_release :
  acquire:('a, 'err) t ->
  release:('a -> (unit, 'release_err) t) ->
  ('a -> ('b, 'err) t) ->
  ('b, 'err) t
```

Finalizer semantics are success/failure/cancellation cleanup with protected cleanup and finalizer/suppressed reporting. 

JS sketch:

```ocaml
let acquire_use_release ~acquire ~release body =
  Effect.scoped (
    Effect.acquire_release ~acquire ~release
    >>= fun resource ->
    body resource
  )
```

Runtime-side finalizer loop:

```ocaml
let rec run_finalizers_protected frame = function
  | [] -> Task.pure None
  | f :: rest ->
      Runtime.protect frame.runtime (fun () -> Eval.run frame (f ()))
      >>= fun exit ->
      run_finalizers_protected frame rest
      >>= fun tail ->
      Task.pure (combine_finalizer_exit exit tail)
```

### 12.5 Schedule

Source signature:

```ocaml
type driver

val start : ?random:Capabilities.random -> t -> driver
val next : driver -> (Duration.t * driver) option
val next_delay :
  ?random:Capabilities.random -> t -> step:int -> Duration.t option
```

Schedule is pure recurrence state; it drives retry/repeat. 

JS sketch:

```ocaml
let rec repeat schedule eff =
  let rec loop driver =
    match Schedule.next driver with
    | None -> Effect.unit
    | Some (delay, driver') ->
        Effect.delay delay eff >>= fun () ->
        loop driver'
  in
  eff >>= fun () ->
  loop (Schedule.start schedule)
```

[must-have] `Effect.delay` must suspend through JS timers, not call a blocking sleep.

Interop timer stub:

```ocaml
type timeout_id
external set_timeout :
  (unit -> unit) -> int -> timeout_id = "setTimeout" [@@mel.val]
```

---

## 13. What cannot be fully satisfied in JS

[must-have] The existing native `Runtime_contract.RUNTIME` cannot be faithfully implemented for asynchronous waits in JavaScript, because it requires synchronous return from operations that are naturally asynchronous (`sleep`, `await_promise`, `stream_take`). The closest correct approximation is an async/CPS interpreter plus `run_promise`.

[must-have] Native `Eta_blocking.run` cannot become nonblocking on the JS main thread. The closest approximation is an abortable Promise bridge; true CPU offload requires Web Workers and serialization.

[must-have] OCaml raw backtraces are not guaranteed to be faithful in JS. Preserve `Cause.Die` shape, but store `None` or JS stack diagnostics depending on what the Melange target/runtime exposes.

[must-have] Cancellation cannot preempt arbitrary synchronous JS/OCaml code. It is cooperative at Eta suspension points and `check`/`yield`.

[should-have] `multiple_exceptions` can be approximated by scheduler-owned aggregation. Exact Eio exception shapes are native-specific.

[nice-to-have] Provide a compatibility layer that rejects unsupported native-only APIs loudly at compile time or with immediate `Invalid_argument`, matching Eta’s “break loudly” engineering style.

[1]: https://dune.readthedocs.io/en/stable/melange.html "https://dune.readthedocs.io/en/stable/melange.html"
[2]: https://melange.re/v2.2.0/build-system/ "https://melange.re/v2.2.0/build-system/"
[3]: https://melange.re/v6.0.1/working-with-js-objects-and-values.html "https://melange.re/v6.0.1/working-with-js-objects-and-values.html"



Yes: **Eta is close to “Effect/ZIO semantics implemented in modern OCaml,” but the JavaScript port should learn from TypeScript Effect’s runtime architecture, not copy its whole programming model.** Eta deliberately does not own an Effect-TS/ZIO-style environment/layer graph; its source says dependencies are ordinary OCaml values and Eta owns effect description and interpretation, not application state. 

## What to learn from TypeScript Effect

TypeScript Effect treats an `Effect` as a lazy description, then runs it by creating a root fiber and stepping an instruction loop until it produces an `Exit`; the docs list the runtime’s jobs as execution, error handling, concurrency, cooperative yielding, cleanup, and async callback handling. That is the exact mental model Eta needs on JS. ([Effect][1])

The big lesson is: **a JS runtime should be a fiber interpreter, not a Promise wrapper.** Effect fibers have identity, local state, status, and an eventual success/failure exit; the runtime source keeps explicit fiber refs, a message queue, child set, observers, exit value, stack, async interruptor/blocking state, runtime flags, scheduler, supervisor, tracer, and context. ([Effect][2])

Effect’s scheduler abstraction is also worth copying conceptually: tasks are scheduled with priority, each fiber can ask whether it should yield, and the runtime has sync, mixed, controlled, timer, and batched scheduler shapes. For Eta, this suggests a small scheduler interface around `enqueue`, `yield`, timer wakeups, and deterministic test stepping. ([effect-ts.github.io][3])

The strongest architectural signal is in Effect’s run loop: when the interpreter hits `OP_YIELD`, it schedules a cooperative resume; when it hits `OP_ASYNC`, it stops evaluating and waits for an async resumption to continue. That is almost exactly the shape Eta needs for `sleep`, `await_promise`, `stream_take`, channel waits, semaphore waits, and queue waits in JavaScript. ([GitHub][4])

## Is CPS the best architecture?

**Yes, but not “CPS everywhere” in the source API.** The best architecture is a **defunctionalized CPS fiber interpreter**:

```ocaml
type cont =
  | Done
  | Map : ('a -> 'b) * cont -> cont
  | Bind : ('a -> ('b, 'err) Effect.t) * cont -> cont

type step =
  | Continue of packed_effect * cont
  | Suspend of resume_handle
  | Complete of Exit.t
```

In other words, keep the public Eta API normal:

```ocaml
val bind : ('a -> ('b, 'err) Effect.t) -> ('a, 'err) Effect.t -> ('b, 'err) Effect.t
val delay : Duration.t -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
val race : ('a, 'err) Effect.t list -> ('a, 'err) Effect.t
```

…but internally, interpret it as an explicit state machine that can stop and resume.

That is better than three alternatives:

**1. Raw `Promise` chaining:** too weak. It gives async sequencing, but it does not naturally preserve Eta’s fiber-local context, child scopes, structured cancellation, finalizer ordering, supervisor failure recording, or deterministic testing.

**2. JavaScript `async/await` everywhere:** convenient but leaky. It hides continuations inside JS promises, which makes cancellation/finalizer control harder. It also makes “run synchronously if possible” difficult. Effect itself exposes a distinction: `runPromise` is the async edge API, while `runSync` throws when an effect performs async work. Eta should make the same distinction: `run_promise` as the main JS runner and maybe `run_now` only for pure/sync effects. ([Effect][1])

**3. Generators:** tempting because Effect-TS has `Effect.gen`, but generators are mostly a user-facing syntax trick. They do not by themselves solve cancellation trees, scope cleanup, async callback interruption, child supervision, or runtime-local state. They can be added later as syntax, not used as the runtime substrate.

## The Eta-specific answer

For Eta/Melange, I would implement:

```ocaml
val run_promise :
  'err Eta_js.Runtime.t ->
  ('a, 'err) Eta.Effect.t ->
  ('a, 'err) Eta.Exit.t Js.Promise.t
```

Internally:

```ocaml
type fiber = {
  id : int;
  mutable kont : cont;
  mutable current : packed_effect option;
  mutable exit : packed_exit option;
  mutable children : fiber list;
  mutable locals : local_table;
  mutable interrupted : Cause.interrupt_id option;
  mutable finalizers : finalizer list;
}
```

Suspending operations register a continuation and return to the scheduler:

```ocaml
let sleep duration k =
  let id =
    setTimeout
      (fun () -> Scheduler.enqueue (Resume k))
      (Duration.to_ms duration)
  in
  Suspend { cancel = (fun () -> clearTimeout id) }
```

That is CPS, but **defunctionalized CPS**: you represent continuations as data frames plus a small amount of callback state, rather than turning every Eta function into hand-written callback code.

## What to copy from Effect-TS, concretely

Copy these ideas:

1. **Root fiber + child fibers.** Every Eta run creates one root fiber; `race`, `par`, `all`, supervisors, streams, and daemons create child fibers. Effect docs describe `runFork` as returning a fiber that can be observed, interrupted, or joined; Eta should expose similar internal handles even if the public API stays OCaml-shaped. ([Effect][1])

2. **Inbox/message queue per fiber.** Effect’s runtime uses `tell(...)` to enqueue messages and schedules draining when the fiber is not running. This avoids reentrant resumes and gives a clean place to deliver interrupts, state queries, async completions, and yields. ([GitHub][4])

3. **Explicit async boundary.** `OP_ASYNC` terminates the current evaluation and relies on later resumption. Eta’s JS backend should do the same for timers, promises, channels, queues, pubsub, semaphore, and stream pulls. ([GitHub][4])

4. **Cooperative interruption.** Effect records an interrupt cause and propagates interruption to children. Eta should model cancellation the same way: mark fiber interrupted, wake it if suspended, propagate to children, and run finalizers before settlement. ([GitHub][4])

5. **Finalizers are runtime-owned.** Effect docs emphasize finalizers running on success, failure, or interruption; Eta’s `finally`/`acquire_release` semantics require the same, including cleanup on cancellation. ([Effect][5])

Do **not** copy these blindly:

1. **Environment/layers.** Eta explicitly says dependencies are ordinary OCaml values, not a universal environment parameter. Keep that.

2. **All Effect services.** Eta should not import Effect’s whole service ecosystem. For JS, only runtime services are needed: clock, scheduler, random, logger/tracer/meter, and optional Promise/Abort bridges.

3. **Effect’s huge API surface.** Eta’s strength is a small OCaml surface. Preserve that.

## Final recommendation

Use **Effect-TS’s fiber-runtime architecture** as prior art, but implement it in Eta style:

**Public API:** normal Eta `Effect.t`, typed failures, `Exit`, `Cause`, `Schedule`, `Resource`, `Supervisor`.

**JS runtime API:** `run_promise`, `fork`, `interrupt`, `await`, scheduler hooks.

**Interpreter core:** defunctionalized CPS with an explicit continuation stack.

**Suspension model:** timers/promises/queues/channels store resume callbacks and cancellation hooks.

**Testing:** controlled scheduler and virtual clock, not real timers.

So the answer is: **CPS is the right internal architecture, but only as a runtime implementation technique.** The public Eta API should remain declarative and OCaml-ish; the JS backend should be a small Effect-like fiber VM.

[1]: https://effect.website/docs/runtime/ "Introduction to Runtime | Effect Documentation"
[2]: https://effect.website/docs/concurrency/fibers/ "Fibers | Effect Documentation"
[3]: https://effect-ts.github.io/effect/effect/Scheduler.ts.html "Scheduler.ts - effect"
[4]: https://github.com/Effect-TS/effect/blob/main/packages/effect/src/internal/fiberRuntime.ts "effect/packages/effect/src/internal/fiberRuntime.ts at main · Effect-TS/effect · GitHub"
[5]: https://effect.website/docs/resource-management/introduction/?utm_source=chatgpt.com "Introduction"

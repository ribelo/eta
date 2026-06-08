# Eta JavaScript Runtime Implementation Plan

> Use the subagent-driven-development skill to implement this plan task-by-task when delegation is available.

**Goal:** Build an optional `eta_js` Melange package that preserves Eta's typed effects, causes, resource safety, structured concurrency, and same-runtime primitives on JavaScript through an async fiber interpreter.

**Architecture:** Treat the current `Runtime_contract.RUNTIME` as the Eio-era native contract, not as a fixed abstraction boundary. JavaScript should force a contract audit: either introduce a substrate-agnostic runtime contract that both Eio and JS can implement, or keep `eta_js` separate only until that contract is proven. The target runtime shape is a cooperative fiber VM with explicit continuation stack, scheduler queue, child scopes, cancellation state, async waiter registration, runtime locals, and async finalizers.

**Tech Stack:** OCaml, Dune, Melange, Node for first tests, existing Eta native code as behavioral reference, and `.reference/effect-smol` as runtime architecture prior art.

---

## Grounding

### Current Eta Code Anchors

- `lib/eta/runtime_contract.mli:38` defines the erased native runtime record. The blocking boundary is direct-style: `sleep : Duration.t -> unit`, `await_promise : 'a promise -> 'a`, `stream_take : 'a stream -> 'a`, `run_scope : (scope -> 'a) -> 'a`, and `protect : (unit -> 'a) -> 'a`. This is evidence that the current contract is shaped around Eio's ability to suspend direct-style OCaml code, not proof that the contract is substrate-agnostic.
- `lib/eta/runtime_contract.ml:124` is the only native typed-module-to-erased-record adapter today. The implementation plan may replace or reshape this boundary if doing so produces a cleaner runtime contract; do not add a JS adapter that pretends async operations can satisfy the current record unchanged.
- `lib/eio/eta_eio.ml:220` to `lib/eio/eta_eio.ml:269` shows the native backend mapping that works only because Eio can suspend direct-style code.
- `lib/eta/runtime.ml:14` to `lib/eta/runtime.ml:46` runs an effect synchronously and returns `Exit.t`; JS must expose `run_promise` instead.
- `lib/eta/effect_core.ml:58` to `lib/eta/effect_core.ml:67` defines the current private effect AST, and `lib/eta/effect_core.ml:102` to `lib/eta/effect_core.ml:126` evaluates it recursively to an immediate `Exit.t`.
- `lib/eta/effect_core.ml:285` to `lib/eta/effect_core.ml:378` contains the first direct wait call sites: `delay`, `timeout_as`, `repeat`, and `retry`.
- `lib/eta/effect_concurrent.ml:50` to `lib/eta/effect_concurrent.ml:316` implements race/par/all with `run_scope`, `fork`, `create_stream`, `stream_take`, `create_promise`, and `await_promise`.
- `lib/eta/effect_resource.ml:6` to `lib/eta/effect_resource.ml:40` and `lib/eta/runtime_core.ml:216` to `lib/eta/runtime_core.ml:269` define current finalizer and suppressed-cause behavior. JS must preserve this behavior but make finalizers async-aware.
- `lib/eta/channel.ml:303` to `lib/eta/channel.ml:364`, `lib/eta/queue.ml:144` to `lib/eta/queue.ml:168`, `lib/eta/semaphore.ml:104` to `lib/eta/semaphore.ml:159`, and `lib/eta/pubsub.ml:253` to `lib/eta/pubsub.ml:277` share the same pattern: mutate state under a short lock, enqueue a waiter, then synchronously `await_promise`. The JS ports should reuse the state-machine reasoning but replace the wait path with scheduler suspension.
- `lib/eta/sync_lock.ml:8` to `lib/eta/sync_lock.ml:19`, `lib/eta/mutable_ref.ml:1` to `lib/eta/mutable_ref.ml:29`, `lib/eta/runtime_supervisor.ml:1` to `lib/eta/runtime_supervisor.ml:78`, and `lib/eta/capabilities.ml:5` to `lib/eta/capabilities.ml:131` use `Atomic`; JS single-thread state should use ordinary mutation and no spin loops.
- `lib/stream/dune:1` to `lib/stream/dune:6` depends on `eio` and `cstruct`; stream file/Eio sources are out of the first Melange closure.
- Local tool state checked while writing this plan: `dune --version` is `3.21.1`; `js-runtime-proposal.md` is untracked.

### Effect-Smol Runtime Prior Art

Use these as architecture references only:

- `.reference/effect-smol/packages/effect/src/internal/core.ts` defines `Primitive` with `evaluate`, success continuation, failure continuation, and finalizer continuation hooks. This maps well to an Eta JS continuation stack.
- `.reference/effect-smol/packages/effect/src/internal/effect.ts` defines `FiberImpl` with an id, context, scheduler, op counters, stack, observers, exit, children, interrupted cause, and yielded continuation.
- `.reference/effect-smol/packages/effect/src/internal/effect.ts` `runLoop` runs until it produces an exit or yields, and injects scheduler yields after an operation budget.
- `.reference/effect-smol/packages/effect/src/internal/effect.ts` `callbackOptions` is the relevant async pattern: register a one-shot resume callback, optionally attach an `AbortController`, push an async finalizer, and yield.
- `.reference/effect-smol/packages/effect/src/internal/effect.ts` `forkUnsafe`, `runPromiseExitWith`, and `runSyncExitWith` show the separation Eta needs: a root fiber, observer-based promise completion, and sync run that fails loudly if async work remains.
- `.reference/effect-smol/packages/effect/src/Scheduler.ts` defines a small scheduler interface, dispatcher, batched task queue, and op-count based yielding. Eta JS should copy the idea, not the full Effect service/context model.

### Contract Redesign Decision

Do not assume the existing native runtime contract is good enough because it is named `Runtime_contract`. It was designed after the Eio implementation path, and several operations are not neutral abstractions over async runtimes; they are direct-style operations that Eio happens to satisfy.

The first implementation may expose `Eta_js.Effect.t` as a contained prototype, but the plan must leave freedom to change the shared root contract and interpreter if the prototype shows a better abstraction. Breaking the current runtime contract is allowed when it removes Eio coupling; update all Eio/native callers instead of adding compatibility shims.

Known pressure point: `Eta.Effect.t` is private in `lib/eta/effect.mli:23`, backed by synchronous `Effect_core.Custom.eval : frame -> Exit.t` in `lib/eta/effect_core.ml:61` to `lib/eta/effect_core.ml:67`. A shared JS/native effect surface likely requires changing the internal custom leaf contract and interpreter, not only adding a new backend.

### Initial Runtime Contract Audit Table

| Current operation | Eta-owned semantic role | Eio-shaped issue | vNext direction |
| --- | --- | --- | --- |
| `now_ms` | runtime clock read | neutral enough | keep as pure clock capability |
| `sleep : Duration.t -> unit` | suspend current fiber until time | direct-style wait only works because Eio can suspend under a function call | replace with explicit suspension/task operation |
| `protect : (unit -> 'a) -> 'a` | defer cancellation around cleanup/uninterruptible regions | assumes dynamic direct-style cancellation scope | model interruptibility/protect depth on the fiber and make protected bodies async-aware |
| `run_scope : (scope -> 'a) -> 'a` | lexical child scope and finalizer boundary | synchronous body/return hides async child settlement | replace with scope open/close plus async body evaluation |
| `fail_scope` | cancel/fail scope children | mostly semantic but tied to Eio switch failure | keep semantic operation, adapt to scheduler-owned scope cancellation |
| `fork`, `fork_daemon` | start child fibers | callback returns `unit`; child result is only observable through side effects/promises | return or internally track fiber handles with observers and daemon accounting |
| `await_cancel` | suspend until cancellation | direct-style wait | replace with explicit cancellation waiter registration |
| `yield`, `check` | cooperative fairness/interruption | semantically neutral, implementation direct | keep as fiber scheduler operations |
| `create_promise`, `resolve_promise`, `await_promise` | one-shot handoff | `await_promise` is direct-style blocking | split into one-shot state plus explicit await suspension |
| `create_stream`, `stream_add`, `stream_take` | bounded internal result handoff | `stream_take` and potentially `stream_add` are direct-style waits | split into bounded queue state plus explicit suspend/resume |
| `with_worker_context`, `in_worker_context` | native worker safety fence | native-thread concept, not JS main-thread neutral | move to native worker service; JS promise/worker bridges get separate services |
| `cancellation_reason` | classify backend cancellation as interrupt | needed but exception-shaped | keep classification, but scheduler-owned JS cancellation should not be raw user exceptions |
| `multiple_exceptions` | aggregate concurrent failures | Eio exception shape leaks into root | replace with Eta-owned multiple-cause aggregation in scope settlement |
| `cancel_sub`, `cancel` | create cancellable child context | Eio cancel-context API leaks through | replace with fiber/scope cancel handles |
| `local_get`, `local_with_binding` | runtime-local context | semantic role is neutral; implementation is Eio Fiber key/DLS in `eta_eio` | keep concept, implement with scheduler-owned fiber locals |

### Phase 0 Verified Runtime Contract Outcome

Repository audit date: 2026-06-08.

Verification sources:

- `lib/eta/runtime_contract.mli` and `lib/eta/runtime_contract.ml` still expose direct-style `sleep`, `run_scope`, `await_promise`, `stream_take`, `await_cancel`, and `protect`.
- `lib/eio/eta_eio.ml` maps those operations directly to Eio `Time.sleep`, `Switch.run`, `Promise.await`, `Stream.take`, `Fiber.await_cancel`, and `Cancel.protect`.
- `lib/eta/effect_core.ml` still backs `Eta.Effect.t` with synchronous `Custom.eval : frame -> Exit.t` and recursive immediate evaluation.
- `lib/eta/runtime.ml` still exposes synchronous `Runtime.run : runtime -> effect -> Exit.t`.

| Current role | Operations | Next-contract action |
| --- | --- | --- |
| Clock read | `now_ms` | Keep as a pure runtime capability. |
| Timer suspension | `sleep` | Split into explicit async suspension in `eta_js`; do not pretend this fits the current direct return signature. |
| Lexical scope | `root_scope`, `run_scope`, `fail_scope` | Keep scope ownership semantics, but model JS scope open/close/settlement explicitly. `run_scope` is not substrate-neutral. |
| Child fibers | `fork`, `fork_daemon` | Split into scheduler-owned fiber handles, observers, and daemon accounting in `eta_js`. |
| One-shot handoff | `create_promise`, `resolve_promise`, `await_promise` | Keep one-shot state semantics; replace `await_promise` with fiber suspension in `eta_js`. |
| Bounded handoff | `create_stream`, `stream_add`, `stream_take`, `stream_take_nonblocking` | Keep stream state semantics; replace blocking take/add paths with explicit wait queues in `eta_js`. |
| Cancellation and protection | `protect`, `await_cancel`, `yield`, `check`, `cancel_sub`, `cancel`, `cancellation_reason`, `multiple_exceptions` | Keep Eta cancellation semantics; represent interruptibility, cancel waiters, and concurrent-cause aggregation inside the JS scheduler. |
| Context and services | `local_get`, `local_with_binding`, worker context, runtime services | Keep locals/services as concepts; JS locals are scheduler-owned mutable fiber state, and native worker context remains absent from `eta_js`. |

Runtime contract decision: temporary eta_js prototype first
Reason: The current shared `Eta.Effect.t` is not just coupled to an Eio-shaped runtime contract; it is backed by synchronous custom leaves and immediate recursive evaluation. A shared vNext would need to replace the root effect representation, interpreter, runtime contract, Eio adapter, and native tests before the first Melange package can be verified. The prototype path lets the JS scheduler/interpreter prove the async contract shape without preserving the current direct-style signatures as a compatibility layer.
Files owned by the decision: `lib/js/**`, `test/js/**`, `lib/js_test/**`, `dune-project`, and this plan. Shared `lib/eta/**`, `lib/eio/**`, and `test/eta/**` stay unchanged during the prototype unless a later phase deliberately replaces the shared contract in one implementation series.
Deletion/merge path if prototype: once `eta_js` passes the required JS behavior matrix and native tests still pass, compare `lib/js/effect_core.ml`, `lib/js/runtime_core.ml`, `lib/js/fiber.ml`, `lib/js/scope.ml`, `lib/js/runtime_local.ml`, `lib/js/runtime_promise.ml`, and `lib/js/runtime_stream.ml` against the native interpreter. If a shared async contract is selected, move substrate-neutral pieces into `lib/eta/`, replace the old `Runtime_contract.RUNTIME` and `Effect_core.Custom.eval` shape, update `eta_eio` and all native callers in the same series, then delete the temporary JS-only modules instead of leaving wrappers.

## Acceptance Criteria

- `eta_js` is a new optional package/library aligned as package `eta_js`, public library `eta_js`, top-level module `Eta_js`, unless Phase 0 selects a shared runtime-contract vNext that makes a dual-mode root effect/runtime feasible immediately.
- The root `eta` package does not gain Melange-only, JS, testing, Eio, blocking, HTTP, C-stub, or provider dependencies.
- The first public JS runner is either `Eta_js.Runtime.run_promise` or a shared runtime-vNext equivalent. The required shape is:

```ocaml
val run_promise :
  'err Runtime.t ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Exit.t Js.Promise.t
```

- `run_now`, if added, returns `None` when the effect attempts any suspension. It must not fake a completed value.
- JS cancellation is cooperative at Eta suspension points, `yield`, and `check`; ordinary synchronous callbacks can block the JS event loop and are documented as such.
- Unsupported native-only surfaces are absent from `eta_js` or fail immediately with a clear `Invalid_argument`; no silent fallback logic.
- The plan includes an explicit runtime-contract redesign gate before implementation. A shared contract vNext is preferred if it can cleanly support Eio and JS without preserving the current direct-style wait signatures.
- A Node-based Melange test target covers pure effects, typed failures, defects, delay, timeout, retry/repeat, race/par/all/all_settled, finalizers, Queue, Channel, Semaphore, PubSub, Pool cancellation, Resource.auto, runtime locals, and supervisor child handling.
- Native tests still pass with `nix develop -c dune runtest --force`.

## Phase 0: Runtime Contract Design Gate And Build Probe

### Task 0.0: Audit Runtime Roles Versus Eio Mechanics

**Objective:** Separate Eta-owned runtime semantics from the current Eio-shaped implementation details.

**Files:**
- Read: `lib/eta/runtime_contract.mli`
- Read: `lib/eta/runtime_contract.ml`
- Read: `lib/eta/runtime.ml`
- Read: `lib/eta/runtime_core.ml`
- Read: `lib/eta/effect_core.ml`
- Read: `lib/eta/effect_concurrent.ml`
- Read: `lib/eta/effect_resource.ml`
- Read: `lib/eta/effect_supervisor_scope.ml`
- Read: `lib/eio/eta_eio.ml`
- Update: `js-runtime-implementation-plan.md`

**Steps:**

1. Classify every `Runtime_contract.RUNTIME` operation into one of these roles:
   - time: `now_ms`, `sleep`
   - lexical scope and child ownership: `root_scope`, `run_scope`, `fail_scope`, `fork`, `fork_daemon`
   - suspension and handoff: `create_promise`, `resolve_promise`, `await_promise`, `create_stream`, `stream_add`, `stream_take`, `stream_take_nonblocking`
   - cancellation: `protect`, `await_cancel`, `yield`, `check`, `cancel_sub`, `cancel`, `cancellation_reason`, `multiple_exceptions`
   - context and services: locals, worker context, runtime services
2. For each role, write down whether Eta owns the semantic contract or Eio owns the implementation mechanism.
3. Mark operations that are not substrate-neutral. The known initial list is `sleep`, `await_promise`, `stream_take`, `run_scope`, `fork`, `fork_daemon`, `await_cancel`, and `protect`, because their direct-style signatures assume a suspension substrate below ordinary function calls.

**Verification:** The plan contains a short table naming which current operations are kept, renamed, split, or removed in the next contract.

### Task 0.0a: Design Runtime Contract vNext

**Objective:** Decide whether to improve the shared root runtime contract now instead of building a long-lived JS-only parallel universe.

**Files:**
- Modify if vNext is selected: `lib/eta/runtime_contract.mli`
- Modify if vNext is selected: `lib/eta/runtime_contract.ml`
- Modify if vNext is selected: `lib/eta/runtime.ml`
- Modify if vNext is selected: `lib/eta/runtime_core.ml`
- Modify if vNext is selected: `lib/eta/effect_core.ml`
- Modify if vNext is selected: `lib/eio/eta_eio.ml`
- Test if vNext is selected: `test/eta/test_eta_runtime_contract.ml`

**Candidate direction:**

Replace the single Eio-era direct contract with two layers:

```ocaml
module type SCHEDULER = sig
  type fiber
  type scope
  type 'a wait

  val now_ms : unit -> int
  val suspend : (resume:('a -> unit) -> cancel:(exn -> unit) -> unit) -> 'a wait
  val fork : scope -> (unit -> unit wait) -> fiber
  val await : 'a wait -> 'a wait
  val cancel : fiber -> exn -> unit wait
  val protect : (unit -> 'a wait) -> 'a wait
end
```

Do not treat this sketch as final API. The important direction is that suspension is explicit in the contract instead of hidden behind Eio-style direct returns.

**Decision criteria:**

- Prefer a shared vNext when Eio can adapt through a small direct-style wrapper and JS can adapt without fake blocking.
- Prefer a temporary `eta_js` effect/runtime only if changing root `Eta.Effect.t` and `Runtime_contract` would make the first milestone too large to verify.
- If temporary `eta_js` is chosen, write down the deletion path: which modules disappear or merge once the shared contract exists.
- Do not keep old and new runtime contracts as compatibility shims. If vNext replaces the current contract, update `eta_eio`, tests, and callers in the same implementation series.

**Verification:** Before implementing runtime code, update this plan with one explicit decision:

```markdown
Runtime contract decision: [shared vNext now | temporary eta_js prototype first]
Reason: [...]
Files owned by the decision: [...]
Deletion/merge path if prototype: [...]
```

### Task 0.0b: Add Contract vNext Regression Tests First

**Objective:** If the shared contract is changed, lock behavior before updating implementations.

**Files:**
- Modify: `test/eta/test_eta_runtime_contract.ml`
- Modify as needed: `test/eta/test_eta_effect_core.ml`
- Modify as needed: `test/eta/test_eta_effect_concurrency.ml`

**Required tests:**

- A runtime leaf can suspend and resume without relying on Eio direct-style effects.
- Finalizers still run on success, typed failure, defect, and cancellation.
- `Effect.delay`, `timeout_as`, `race`, `par`, and `all_settled` preserve existing native behavior under the Eio adapter.
- Worker-context protection still rejects unsafe `Runtime.run` entry where that check remains meaningful.

**Verification:** The new tests fail against the old contract for the new abstraction point, then pass after the vNext implementation.

### Task 0.1: Verify Melange Stanza Compatibility

**Objective:** Confirm whether local Dune `3.21.1` accepts `(using melange 1.0)` before committing a Dune version bump.

**Files:**
- Read: `dune-project`
- Modify later only after the probe: `dune-project`

**Steps:**

1. Create a throwaway branch or stashless local edit with:

```lisp
(using melange 1.0)
```

under the existing `(lang dune 3.21)`.

2. Add a tiny temporary `lib/js/dune` and `lib/js/eta_js.ml` skeleton.

3. Run the Melange probe in a dedicated JavaScript build switch:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); dune build @melange'
```

Expected: either Melange builds, or Dune reports that the extension/stanza requires a newer Dune. JS compilation is a separate mainline OCaml build path.

4. If Dune requires newer support, change `dune-project` to:

```lisp
(lang dune 3.23)
(using melange 1.0)
```

and update package `dune` lower bounds consistently. Do not edit generated `*.opam` files directly.

**Verification:** The chosen Dune version and `(using melange 1.0)` parse with the skeleton.

### Task 0.2: Add `eta_js` Package Metadata

**Objective:** Add an optional JS package without adding JS dependencies to root `eta`.

**Files:**
- Modify: `dune-project`
- Generated later by Dune: `eta_js.opam`

**Dune package stanza:**

```lisp
(package
 (name eta_js)
 (synopsis "JavaScript runtime backend and Melange-compatible Eta subset")
 (description
  "eta_js provides a Melange JavaScript runtime and Eta-compatible effect surface for JS programs.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.21))
  (melange (>= 6.0.1))))
```

If Task 0.1 requires Dune `3.23`, use `(dune (>= 3.23))`.

**Verification:** `nix develop -c dune build eta_js.opam` generates an opam file and does not modify root `eta.opam` dependencies except the generated Dune lower-bound normalization.

### Task 0.3: Add Minimal Library And Emit Target

**Objective:** Create the package shell and prove JS output can be emitted.

**Files:**
- Create: `lib/js/dune`
- Create: `lib/js/eta_js.ml`
- Create: `lib/js/eta_js.mli`

**Initial `lib/js/dune`:**

```lisp
(library
 (name eta_js)
 (public_name eta_js)
 (modules eta_js)
 (modes melange)
 (synopsis "JavaScript runtime backend and Melange-compatible Eta subset"))

(melange.emit
 (target eta_js_dist)
 (modules)
 (module_systems (esm mjs))
 (libraries eta_js))
```

**Initial modules:**

```ocaml
(* eta_js.mli *)
val version : string
```

```ocaml
(* eta_js.ml *)
let version = "dev"
```

**Verification:** Run the Melange build command discovered in Task 0.1. If Dune's alias differs from `@melange`, record the exact working command in this file before continuing.

**Task 0.1 probe result:** `(using melange 1.0)` parses under local Dune `3.21.1`, `nix develop -c dune build eta_js.opam` generates `eta_js.opam`, and the Melange build works in the dedicated mainline JS switch:

```bash
nix develop .#mainline -c opam switch create eta-js-5.4.1 ocaml-system.5.4.1 --yes --assume-depexts
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); opam install ./eta_js.opam --deps-only --with-test --assume-depexts --yes'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @melange @test/js/js-tests-build'
```

No Dune language bump is required by the probe. Future JS verification should use the final command above; native Eta verification remains `nix develop -c dune runtest --force`.

## Phase 1: Pure JS-Compatible Core Modules

### Task 1.1: Port Pure Data Modules

**Objective:** Give `eta_js` its own pure data types without depending on native `eta`.

**Files:**
- Create: `lib/js/duration.ml`, `lib/js/duration.mli`
- Create: `lib/js/exit.ml`, `lib/js/exit.mli`
- Create: `lib/js/cause.ml`, `lib/js/cause.mli`
- Create: `lib/js/schedule.ml`, `lib/js/schedule.mli`
- Create: `lib/js/log_level.ml`, `lib/js/log_level.mli`
- Create: `lib/js/sampler.ml`, `lib/js/sampler.mli`
- Create: `lib/js/string_helpers.ml`, `lib/js/string_helpers.mli`
- Create: `lib/js/trace_context.ml`, `lib/js/trace_context.mli`
- Modify: `lib/js/eta_js.ml`, `lib/js/eta_js.mli`

**Source reference:**
- `lib/eta/duration.ml`
- `lib/eta/exit.ml`
- `lib/eta/cause.ml`
- `lib/eta/schedule.ml`
- `lib/eta/log_level.ml`
- `lib/eta/sampler.ml`
- `lib/eta/string_helpers.ml`
- `lib/eta/trace_context.ml`

**Implementation notes:**

- Preserve public type shapes and behavior where practical.
- For `Cause.Die`, keep the field shape with `Printexc.raw_backtrace option`, but JS defect conversion should set `None` until a deliberate JS stack diagnostic type is designed.
- Do not copy native-only dependencies, `Atomic`, Eio, Unix, or domain assumptions.

**Verification:** Add a small Node test for `Duration.to_ms`, `Exit.to_result`, `Cause.map`, and deterministic `Schedule.next_delay`.

### Task 1.2: Port Capabilities And Random Without Atomics

**Objective:** Preserve deterministic random behavior with JS-safe mutation.

**Files:**
- Create: `lib/js/capabilities.ml`, `lib/js/capabilities.mli`
- Create: `lib/js/random.ml`, `lib/js/random.mli`

**Source reference:**
- `lib/eta/capabilities.ml:106` to `lib/eta/capabilities.ml:131`
- `lib/eta/random.ml`

**Implementation note:**

Use:

```ocaml
type random = { mutable seed : int }
```

and replace the native CAS loop with a single mutation:

```ocaml
let advance_random random =
  let next = next_seed random.seed in
  random.seed <- next;
  next
```

**Verification:** Port the native deterministic random tests with fixed seeds. Do not rely on wall-clock default random in JS tests.

## Phase 2: Runtime Kernel

**Placement rule:** If Phase 0 selects a temporary JS prototype, create the runtime-kernel files under `lib/js/`. If Phase 0 selects a shared runtime-contract vNext, place the substrate-neutral pieces under `lib/eta/` with names that match existing private-module style, then adapt `lib/eio/eta_eio.ml` and expose only the JS-specific Melange bindings from `lib/js/`.

### Task 2.1: Add JS Interop Module

**Objective:** Localize all Melange externals for timers, microtasks, promises, and abort signals.

**Files:**
- Create: `lib/js/js_interop.ml`
- Create: `lib/js/js_interop.mli`

**Initial shape:**

```ocaml
type timeout_id
type abort_controller
type abort_signal

external date_now : unit -> float = "Date.now" [@@mel.val]
external set_timeout : (unit -> unit) -> int -> timeout_id = "setTimeout" [@@mel.val]
external clear_timeout : timeout_id -> unit = "clearTimeout" [@@mel.val]
external queue_microtask : (unit -> unit) -> unit = "queueMicrotask" [@@mel.val]
external make_abort_controller : unit -> abort_controller = "AbortController" [@@mel.new] [@@mel.val]
external signal : abort_controller -> abort_signal = "signal" [@@mel.get]
external abort : abort_controller -> unit = "abort" [@@mel.send]
```

**Verification:** A Melange test imports the compiled module and checks `date_now () >= 0.0`.

### Task 2.2: Implement Scheduler

**Objective:** Build a small scheduler similar to effect-smol's `Scheduler.ts`, with batching, operation budget, and test hooks.

**Files:**
- Create: `lib/js/scheduler.ml`
- Create: `lib/js/scheduler.mli`

**Core API:**

```ocaml
type t
type priority = int

val create : ?max_ops_before_yield:int -> unit -> t
val enqueue : t -> ?priority:priority -> (unit -> unit) -> unit
val drain_ready : t -> unit
val ready_count : t -> int
val should_yield : t -> op_count:int -> bool
```

**Implementation notes:**

- Use `queue_microtask` for normal async scheduling.
- Add a fairness budget. After a configured number of fiber steps, schedule through a macrotask `set_timeout 0` so browser/Node timers can run.
- Expose `drain_ready` only through an expert/test module, not as an ordinary user runtime operation.

**Verification:** Unit test three queued callbacks run FIFO at the same priority, and lower numeric priority ordering matches the chosen convention.

### Task 2.3: Implement One-Shot Promise And Bounded Stream

**Objective:** Provide runtime-owned wait handles that suspend fibers without blocking the JS stack.

**Files:**
- Create: `lib/js/runtime_promise.ml`, `lib/js/runtime_promise.mli`
- Create: `lib/js/runtime_stream.ml`, `lib/js/runtime_stream.mli`

**Promise shape:**

```ocaml
type 'a state =
  | Pending of ('a -> unit) Queue.t
  | Resolved of 'a

type 'a t = { mutable state : 'a state }
type 'a resolver = 'a t
```

**Rules:**

- `resolve` after `Resolved _` raises `Invalid_argument "Eta_js.Promise.resolve: already resolved"`.
- `await` returns immediately if resolved; otherwise it registers the current fiber continuation.
- Resolving wakes all registered waiters in scheduler order.

**Stream rules:**

- Preserve `create_stream capacity`, `stream_add`, `stream_take`, and `stream_take_nonblocking` semantics used by native `Effect_concurrent`.
- No lost wakeups: observe state and register waiter in one scheduler step.
- Capacity overflow raises loudly unless a backpressure design is explicitly added.

**Verification:** Tests cover await-before-resolve, resolve-before-await, double resolve failure, `stream_take_nonblocking`, and FIFO stream delivery.

### Task 2.4: Implement Fiber And Scope Records

**Objective:** Define the unit of execution, cancellation, locals, children, finalizers, and observers.

**Files:**
- Create: `lib/js/fiber.ml`, `lib/js/fiber.mli`
- Create: `lib/js/scope.ml`, `lib/js/scope.mli`

**Fiber shape:**

```ocaml
type fiber_status =
  | Ready
  | Running
  | Waiting
  | Done

type packed_exit = Exit : ('a, 'err) Exit.t -> packed_exit
type local_value = Local_value : 'a Runtime_local.key * 'a -> local_value

type t = {
  id : int;
  scheduler : Scheduler.t;
  scope : Scope.t;
  mutable status : fiber_status;
  mutable op_count : int;
  mutable interruptible : bool;
  mutable cancel_cause : Obj.t Cause.t option;
  mutable exit : packed_exit option;
  mutable observers : (packed_exit -> unit) list;
  mutable children : t list;
  locals : (int, local_value list) Hashtbl.t;
  mutable cancel_waiter : (unit -> unit) option;
}
```

Adjust exact types during implementation to avoid unnecessary `Obj.magic`; keep unsafe erasure in one small module if it is required for typed failures.

**Scope rules:**

- A scope owns child fibers.
- Closing a scope cancels live children and waits for settlement before the parent resumes.
- Scope failure aggregates multiple child failures into a scheduler-owned multiple-cause representation.

**Verification:** Test that a child registered under a scope is removed on exit, and closing a scope interrupts an uncompleted child.

### Task 2.5: Implement Runtime Locals

**Objective:** Replace Eio fiber keys and Domain.DLS with scheduler-owned fiber locals.

**Files:**
- Create: `lib/js/runtime_local.ml`, `lib/js/runtime_local.mli`
- Modify: `lib/js/fiber.ml`

**Rules:**

- `create_local` returns a typed key with a stable integer id.
- Child fibers copy the parent local table at fork.
- `local_with_binding` restores after async completion, not merely when the immediate OCaml callback returns.

**Verification:** A local binding is visible across `Effect.delay`, inherited by a forked child, and restored after nested async bindings complete.

### Task 2.6: Implement Runtime Core And Public Runtime

**Objective:** Create the async runtime value and public execution boundary.

**Files if Phase 0 selects temporary `eta_js`:**
- Create: `lib/js/runtime_core.ml`, `lib/js/runtime_core.mli`
- Create: `lib/js/runtime.ml`, `lib/js/runtime.mli`
- Modify: `lib/js/eta_js.ml`, `lib/js/eta_js.mli`

**Files if Phase 0 selects shared contract vNext:**
- Modify/create private runtime-kernel modules under `lib/eta/`
- Modify: `lib/eta/runtime.ml`, `lib/eta/runtime.mli`
- Modify: `lib/eio/eta_eio.ml`
- Create only JS host bindings under `lib/js/`

**Public API target:**

```ocaml
type 'err t

val create :
  ?scheduler:Scheduler.t ->
  ?tracer:Capabilities.tracer ->
  ?sampler:Sampler.t ->
  ?logger:Capabilities.logger ->
  ?meter:Capabilities.meter ->
  ?random:Capabilities.random ->
  ?capture_backtrace:bool ->
  unit ->
  'err t

val run_promise :
  'err t ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Exit.t Js.Promise.t

val run_now :
  'err t ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Exit.t option

val drain_promise : 'err t -> unit Js.Promise.t
```

**Rules:**

- `run_promise` creates a root fiber and resolves a JS promise from a fiber observer.
- `run_now` or synchronous `Runtime.run` runs with a sync scheduler flush and returns `None` or a clear async-work failure if any async waiter remains, matching effect-smol's `runSyncExit` behavior that reports async work loudly.
- `drain_promise` resolves when daemon active count reaches zero; no polling.

**Verification:** `run_promise (Effect.pure 42)` resolves `Exit.Ok 42`; `run_now (Effect.delay ...)` returns `None`.

## Phase 3: Effect AST And Interpreter

### Task 3.1: Add Or Refactor Effect Representation

**Objective:** Create the async-aware effect representation selected by Phase 0: either a temporary JS-specific type or a refactored shared `Eta.Effect.t`.

**Files if Phase 0 selects temporary `eta_js`:**
- Create: `lib/js/effect_core.ml`, `lib/js/effect_core.mli`
- Create: `lib/js/effect.ml`, `lib/js/effect.mli`
- Modify: `lib/js/eta_js.ml`, `lib/js/eta_js.mli`

**Files if Phase 0 selects shared contract vNext:**
- Modify: `lib/eta/effect_core.ml`
- Modify: `lib/eta/effect.ml`, `lib/eta/effect.mli`
- Modify: `lib/eta/effect_erasure.ml`
- Modify: `lib/eta/runtime_erasure.ml`
- Modify every native caller that depends on the old direct `Custom.eval` shape.

**Core shape:**

```ocaml
type ('a, +'err) t =
  | Pure : 'a -> ('a, 'err) t
  | Fail : 'err -> ('a, 'err) t
  | Sync : (unit -> 'a) -> ('a, 'err) t
  | Async : {
      name : string option;
      register : context -> ('a, 'err) async_result;
    } -> ('a, 'err) t
  | Map : { inner : ('a, 'err) t; f : 'a -> 'b } -> ('b, 'err) t
  | Bind : { inner : ('a, 'err) t; k : 'a -> ('b, 'err) t } -> ('b, 'err) t
```

The exact `async_result` type should be driven by the fiber implementation, but it must support immediate completion, suspension with cancel hook, and failure. If this lands in shared `Eta.Effect.t`, remove or replace the old direct-style `Custom.eval : frame -> Exit.t` contract; do not keep both as a compatibility layer.

**Public API parity target:**

Start with `pure`, `fail`, `unit`, `from_result`, `sync`, `map`, `bind`, `tap`, `seq`, `concat`, `catch`, `map_error`, `tap_error`, `delay`, `timeout_as`, `timeout`, `retry`, `repeat`, `finally`, `acquire_release`, `acquire_use_release`, `scoped`, `race`, `par`, `all`, `all_settled`, `for_each_par`, `for_each_par_bounded`, `uninterruptible`, `daemon`, `with_background`, `supervisor_scoped`, and `Expert.async_leaf`.

**Verification:** Typecheck a program that opens the selected public surface (`Eta_js` or shared `Eta`) and builds the same pure/map/bind/catch shape used in `test/eta/test_eta_effect_core.ml:88` to `test/eta/test_eta_effect_core.ml:154`.

### Task 3.2: Implement Stack-Safe Evaluation Loop

**Objective:** Replace recursive direct eval with defunctionalized continuation frames.

**Files:**
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/fiber.ml`

**Continuation shape:**

```ocaml
type packed_eff = Eff : ('a, 'err) t -> packed_eff

type cont =
  | Done
  | Map : ('a -> 'b) * cont -> cont
  | Bind : ('a -> ('b, 'err) t) * cont -> cont
  | Finalizer : (unit -> (unit, 'err) t) * cont -> cont
```

**Rules:**

- A fiber step runs until it reaches `Async`, `yield`, a timer/promise wait, completion, or operation budget yield.
- `Sync f` catches ordinary exceptions as `Cause.Die`; cancellation exceptions recognized by the JS runtime become `Cause.Interrupt`.
- `Fail err` becomes `Cause.Fail err`.
- `catch` catches typed `Cause.Fail` only, matching `lib/eta/effect_core.ml:238` to `lib/eta/effect_core.ml:253`.

**Verification:** Add a deep bind test, for example 100_000 binds, and verify `run_promise` resolves without stack overflow.

### Task 3.3: Implement Async Leaf API

**Objective:** Provide the JS equivalent of effect-smol `callbackOptions` for timers, JS promises, channels, queues, semaphores, and custom runtime leaves.

**Files:**
- Modify: `lib/js/effect.mli`
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect_core.ml`

**API:**

```ocaml
module Expert : sig
  type context

  val async_leaf :
    ?name:string ->
    (context ->
     resume:(('a, 'err) Exit.t -> unit) ->
     on_cancel:((unit -> unit) -> unit) ->
     unit) ->
    ('a, 'err) t
end
```

Adjust the signature if the runtime task representation makes a more typed API possible.

**Rules:**

- Resume is one-shot. A second resume raises or is ignored with a dev assertion; pick one and test it.
- Cancellation runs the registered cancel hook at most once.
- If cancellation happens after the async operation resolved but before the fiber claimed the result, the result wins only where native Eta semantics already allow committed results to win, such as the timeout body cleanup case.

**Verification:** Test an async leaf that resumes immediately, resumes later, double-resumes, and is cancelled before resume.

## Phase 4: Core Runtime Semantics

### Task 4.1: Implement Delay, Yield, Check, And Timeout

**Objective:** Make basic suspension and cancellation work.

**Files:**
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/runtime_core.ml`
- Modify: `lib/js/js_interop.ml`

**Rules:**

- `delay d eff` registers `set_timeout` and resumes with `eff` after `Duration.to_ms d`; zero/negative delay should yield rather than busy-loop.
- `yield` requeues the current fiber behind already-ready work.
- `check` raises/returns interrupt if the fiber has a pending cancellation and is interruptible.
- `timeout_as` should be implemented with JS child fibers and scope cancellation, not with raw `Promise.race`.

**Verification:** Port native delay/timeout tests from `test/eta/test_eta_effect_resource_timeout.ml` using a virtual JS test clock before relying on real timers.

### Task 4.2: Implement Finalizer Semantics

**Objective:** Preserve Eta's LIFO cleanup and suppressed-cause behavior in async form.

**Files:**
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/runtime_core.ml`
- Create or modify: `lib/js/effect_resource.ml`

**Source reference:**
- `lib/eta/runtime_core.ml:216` to `lib/eta/runtime_core.ml:269`
- `lib/eta/effect_resource.ml:6` to `lib/eta/effect_resource.ml:40`

**Rules:**

- Finalizers are LIFO.
- Finalizers run with cancellation deferred.
- Success plus finalizer failure becomes `Cause.Finalizer`.
- Primary failure plus finalizer failure becomes `Cause.Suppressed`.
- Cancellation waits for finalizers and resumes only after cleanup settles.

**Verification:** Tests cover finalizer after success, typed failure, defect, cancellation, and finalizer defect suppression.

### Task 4.3: Implement Retry And Repeat

**Objective:** Reuse pure schedule semantics with async sleep.

**Files:**
- Modify: `lib/js/effect_core.ml`

**Rules:**

- `retry` retries only `Cause.Fail err` accepted by the predicate.
- Defects, interruptions, and finalizer diagnostics do not retry.
- `repeat` runs the first iteration immediately, then uses `Schedule.next` delays.

**Verification:** Port `test/eta/test_eta_effect_retry_repeat.ml` with a deterministic clock and fixed random seed.

## Phase 5: Structured Concurrency

### Task 5.1: Implement Fork And Scope Lifecycle

**Objective:** Make child fibers and scope closure the primitive for race/par/supervisor/daemon.

**Files:**
- Modify: `lib/js/fiber.ml`
- Modify: `lib/js/scope.ml`
- Modify: `lib/js/runtime_core.ml`

**Rules:**

- Fork copies parent locals.
- Non-daemon children are attached to the current scope.
- Scope close cancels live children and waits for child observers before resuming parent.
- Multiple child failures aggregate into `Cause.concurrent`.

**Verification:** A parent with two sleeping children does not complete its scope until both child finalizers complete after cancellation.

### Task 5.2: Implement Race, Par, All, All_Settled

**Objective:** Preserve native `Effect_concurrent` behavior with observer-based JS fibers.

**Files:**
- Create: `lib/js/effect_concurrent.ml`
- Modify: `lib/js/effect.ml`, `lib/js/effect.mli`

**Source reference:**
- `lib/eta/effect_concurrent.ml:50` to `lib/eta/effect_concurrent.ml:316`
- `.reference/effect-smol/packages/effect/src/internal/effect.ts` race/all observer patterns around `raceAll` and `raceAllFirst`

**Rules:**

- `race []` raises `Invalid_argument`.
- Race returns the first success; loser finalizer diagnostics are surfaced.
- `par` and `all` are fail-fast and cancel siblings on first observed failure.
- `all_settled` waits for every child and preserves input order.
- `for_each_par_bounded ~max` rejects `max <= 0` immediately.

**Verification:** Port concurrency tests from `test/eta/test_eta_effect_concurrency.ml` and add deterministic scheduler-order assertions.

### Task 5.3: Implement Daemon Accounting

**Objective:** Support runtime-owned background loops such as `Resource.auto` and `Pool` eviction.

**Files:**
- Modify: `lib/js/runtime_core.ml`
- Modify: `lib/js/effect.ml`, `lib/js/effect.mli`

**Rules:**

- `Effect.daemon` increments active daemon count before scheduling and decrements on settlement.
- Daemon failures emit runtime diagnostics through logger/tracer when present.
- `Runtime.drain_promise` waits on active-count waiters, not polling.

**Verification:** Start a finite daemon, assert `drain_promise` waits until it updates a ref, and assert daemon failure is recorded.

## Phase 6: Same-Runtime Primitives

### Task 6.1: Add JS Mutable Ref And Lock-Free State Helpers

**Objective:** Replace native atomics/spin locks with JS-safe mutable state.

**Files:**
- Create: `lib/js/mutable_ref.ml`, `lib/js/mutable_ref.mli`
- Create: `lib/js/state_guard.ml`, `lib/js/state_guard.mli` if a reusable guard is needed

**Rules:**

- `Mutable_ref.compare_and_set` is a single equality check plus mutation.
- Do not port `Sync_lock.lock` as a busy-wait. If a reentrancy guard is needed, fail loudly on reentrant use.

**Verification:** Port `test/eta/test_eta_mutable_ref.ml`.

### Task 6.2: Port Queue

**Objective:** Implement unbounded close-fenced queue with suspending `recv`.

**Files:**
- Create: `lib/js/queue.ml`, `lib/js/queue.mli`

**Source reference:** `lib/eta/queue.ml`

**Rules:**

- `send` is immediate enqueue-or-fail.
- `recv` dequeues or suspends.
- `try_recv` never suspends.
- Close is idempotent; first reason wins.
- Buffered values are drained before receivers observe close.
- Receiver cancellation removes the waiter and increments `cancelled_receivers`.

**Verification:** Port `test/eta/test_eta_queue.ml`.

### Task 6.3: Port Channel

**Objective:** Implement bounded FIFO channel with backpressure and cancellation-safe waiters.

**Files:**
- Create: `lib/js/channel.ml`, `lib/js/channel.mli`

**Source reference:** `lib/eta/channel.ml`

**Rules:**

- Keep fixed-capacity ring buffer and stats shape.
- Register waiter and observe state in one scheduler step.
- Cancelled senders are removed before admission and increment `cancelled_senders`.
- Closing wakes senders and receivers; buffered values remain drainable.

**Verification:** Port `test/eta/test_eta_channel.ml`, especially sender cancellation, receiver cancellation, FIFO, and close-with-error.

### Task 6.4: Port Semaphore

**Objective:** Preserve cancellation-safe permit ownership.

**Files:**
- Create: `lib/js/semaphore.ml`, `lib/js/semaphore.mli`

**Source reference:** `lib/eta/semaphore.ml:1` to `lib/eta/semaphore.ml:183`

**Rules:**

- Preserve waiter states: `Waiting`, `Resolved_unclaimed`, `Claimed`, `Cancelled`.
- If cancellation happens after permits are granted but before claim, return permits.
- `release` rejects overflow and wakes FIFO waiters that fit.
- `with_permits_or_abort` keeps ownership scoped to the body and releases on discarded race results.

**Verification:** Port `test/eta/test_eta_semaphore.ml`.

### Task 6.5: Port PubSub

**Objective:** Preserve subscription lifetime, retained entries, backpressure, and close fences.

**Files:**
- Create: `lib/js/pubsub.ml`, `lib/js/pubsub.mli`

**Source reference:** `lib/eta/pubsub.ml`

**Rules:**

- Keep entries with `seq`, `value`, and `remaining`.
- Late subscribers start at current sequence.
- Releasing a subscription decrements remaining for entries at or after the cursor.
- Backpressure publisher cancellation must not partially publish.
- Closing wakes publishers and receivers; buffered messages remain drainable.

**Verification:** Port `test/eta/test_eta_pubsub.ml`.

### Task 6.6: Port Pool

**Objective:** Keep Pool semantics on top of JS Semaphore and async finalizers.

**Files:**
- Create: `lib/js/pool.ml`, `lib/js/pool.mli`

**Source reference:** `lib/eta/pool.ml`

**Rules:**

- Same resource accounting: idle, active, opening, closing, total, opened, closed, health rejected.
- `with_resource` scopes checkout ownership to body and releases on success, typed failure, defect, or cancellation.
- Shutdown sets close fence, wakes pending acquirers with `Pool_shutdown`, closes idle entries, and waits for active count to zero.
- Replace native `wait_until_drained` 1ms polling with active waiters resolved by active-count decrement.

**Verification:** Port `test/eta/test_eta_pool.ml`, especially shutdown timeout and release-on-cancellation cases.

## Phase 7: Resource And Supervisor

### Task 7.1: Port Resource

**Objective:** Reuse the current cached-resource logic on top of JS effects.

**Files:**
- Create: `lib/js/resource.ml`, `lib/js/resource.mli`

**Source reference:** `lib/eta/resource.ml`

**Rules:**

- Refresh updates cache only after loader success.
- `auto` starts a daemon refresh loop and participates in `Runtime.drain_promise`.
- Refresh failures are recorded in observation order.
- `on_error` defects are recorded as additional defects and do not stop the loop.

**Verification:** Port resource tests and add a deterministic virtual-clock test for scheduled auto-refresh.

### Task 7.2: Port Supervisor Scope

**Objective:** Preserve the rank-2 public supervisor API and child failure recording.

**Files:**
- Create: `lib/js/runtime_supervisor.ml`, `lib/js/runtime_supervisor.mli`
- Create: `lib/js/effect_supervisor_scope.ml`
- Create: `lib/js/supervisor.ml`, `lib/js/supervisor.mli`

**Source reference:**
- `lib/eta/effect_supervisor_scope.ml`
- `lib/eta/runtime_supervisor.ml`

**Rules:**

- Child handle is one-shot promise of `('a, 'err Cause.t) result` plus `cancel : unit -> unit`.
- Child failures are recorded and do not fail parent unless awaited or `check` crosses `max_failures`.
- `supervisor_scoped` cancels live children in its finalizer.
- Observation order is scheduler settlement order.

**Verification:** Port `test/eta/test_eta_supervisor.ml`.

## Phase 8: JS Promise Bridge

### Task 8.1: Add Abortable Promise Await

**Objective:** Provide the JS replacement for native blocking bridges.

**Files:**
- Create: `lib/js/promise.ml`, `lib/js/promise.mli`

**API:**

```ocaml
val await_promise :
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a Js.Promise.t) ->
  ('a, 'err) Effect.t

val await_abortable :
  ?name:string ->
  (Js_interop.abort_signal -> ('a, 'err) result Js.Promise.t) ->
  ('a, 'err) Effect.t
```

**Rules:**

- Cancellation calls abort/on_cancel at most once.
- Promise rejection becomes `Cause.Die` unless the adapter maps rejection into typed error through `await_abortable`.
- Do not implement `Eta_blocking.run` in `eta_js`.

**Verification:** Test resolve, typed reject through `await_abortable`, defect reject through `await_promise`, and cancellation abort.

## Phase 9: Test Infrastructure

### Task 9.1: Add `eta_js_test` Package

**Objective:** Create JS-native test helpers instead of depending on `eta_test`, Eio, Eio_main, or Alcotest.

**Files:**
- Modify: `dune-project`
- Create: `lib/js_test/dune`
- Create: `lib/js_test/eta_js_test.ml`, `lib/js_test/eta_js_test.mli`

**Package stanza:**

```lisp
(package
 (name eta_js_test)
 (synopsis "Testing helpers for eta_js")
 (description "eta_js_test provides virtual clocks and Node test helpers for eta_js.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.21))
  melange
  eta_js))
```

Use `dune (>= 3.23)` if Task 0.1 requires it.

**Verification:** The package builds in Melange mode and is not a dependency of root `eta`.

### Task 9.2: Implement Virtual Clock

**Objective:** Make timer tests deterministic.

**Files:**
- Create: `lib/js_test/test_clock.ml`, `lib/js_test/test_clock.mli`

**API:**

```ocaml
type t

val create : unit -> t
val now_ms : t -> int
val sleep : t -> Duration.t -> unit Effect.t
val adjust : t -> Duration.t -> unit Effect.t
val set_time : t -> int -> unit Effect.t
val sleeper_count : t -> int
```

**Rules:**

- Sleepers wake in `(deadline_ms, sequence)` order.
- `adjust` wakes due sleepers, then drains the scheduler ready queue.

**Verification:** Two sleepers with same deadline wake by insertion sequence; a later deadline does not wake early.

### Task 9.3: Add Node Test Runner

**Objective:** Run Melange output under Node from `dune runtest`.

**Files:**
- Create: `test/js/dune`
- Create: `test/js/run_js_tests.ml`
- Create: `test/js/node_runner.mjs` if needed

**Runner shape:**

```ocaml
val run_test : string -> (unit -> unit Js.Promise.t) -> unit
```

Use a minimal Node harness first. Add richer assertion formatting only after the first tests run.

**Verification:** `nix develop -c dune runtest test/js` or the exact Dune alias chosen in Task 0.1 runs one passing JS promise test.

### Task 9.4: Port Required Test Matrix

**Objective:** Lock the JS runtime behavior against native Eta semantics.

**Files:**
- Create: `test/js/test_pure.ml`
- Create: `test/js/test_runtime.ml`
- Create: `test/js/test_concurrency.ml`
- Create: `test/js/test_resource.ml`
- Create: `test/js/test_queue.ml`
- Create: `test/js/test_channel.ml`
- Create: `test/js/test_semaphore.ml`
- Create: `test/js/test_pubsub.ml`
- Create: `test/js/test_pool.ml`
- Create: `test/js/test_supervisor.ml`

**Minimum coverage:**

- Pure algebra: `Cause`, `Exit`, `Duration`, `Schedule`, `Trace_context`, deterministic random.
- Runtime: `pure`, `fail`, `sync` defects, `delay`, `timeout_as`, `retry`, `repeat`, `uninterruptible`, cancellation check/yield.
- Concurrency: race winner cancels losers, loser finalizer failure is surfaced, par fail-fast, all_settled preserves input order.
- Primitives: Channel close fences, sender cancellation, receiver cancellation, FIFO; Queue close drain; Semaphore resolved-unclaimed cancellation; PubSub backpressure cancellation; Pool release on cancellation.
- Resource safety: finalizer after success, typed failure, cancellation, and finalizer defect suppression.
- Supervisor: child failure recording, `await`, `cancel`, and `max_failures`.

**Verification:** JS tests pass under Node and native `nix develop -c dune runtest --force` still passes.

## Phase 10: Streams, After Core Runtime

### Task 10.1: Split JS Stream Surface

**Objective:** Avoid pulling `lib/stream` Eio/Cstruct code into Melange.

**Files:**
- Create later: `lib/js_stream/dune`
- Create later: `lib/js_stream/eta_js_stream.ml`, `lib/js_stream/eta_js_stream.mli`

**Rules:**

- Keep pure constructors/operators: `empty`, `succeed`, `from_chunk`, `range`, `map`, `filter`, `take`, `drop`, `scan`, `grouped`, `concat`, `flat_map`.
- Reimplement `merge` and `flat_map_par` on JS fibers/queues.
- Exclude `from_eio_stream`, `from_file` with `Eio.Path`, and `Cstruct` from the JS package.
- Add separate browser `Blob/File` and Node `fs/promises` adapters only after core stream tests pass.

**Verification:** JS stream tests cover pure fusion, mailbox drops, merge cancellation, and `flat_map_par` max concurrency.

## Phase 11: Dedupe And Native Integration, Only After JS Passes

### Task 11.1: Decide Whether To Factor Pure Modules

**Objective:** Remove duplication only after `eta_js` semantics are proven.

**Files:**
- Potentially create: `lib/core_pure/dune`
- Potentially move: pure modules currently duplicated between `lib/eta` and `lib/js`
- Modify: `lib/eta/dune`
- Modify: `lib/js/dune`

**Decision criteria:**

- JS test suite is passing.
- Native full test suite is passing.
- The shared module does not require `Atomic`, Eio, Unix, domains, C stubs, or native-only annotations.
- Moving the module does not widen public APIs accidentally.

**Rule:** Do not add compatibility modules. If a shared pure module is created, update all internal callers or leave duplication in place.

**Verification:** Both native and JS test suites pass after each moved module.

## Non-Goals For The First Implementation

- Do not make synchronous `Eta.Runtime.run` pretend it can block on JavaScript timers or promises. If the shared contract grows a JS-capable runner, it must be explicitly async, such as `run_promise`.
- Do not make `eta_js` depend on `eta_eio`, `eta_blocking`, `eta_stream`, `eta_http`, `eta_sql`, or provider packages. If shared root modules are refactored, keep optional package boundaries intact.
- Do not implement `Eta_blocking.run` on JS main thread.
- Do not add web worker offload in the first package; that should be a later `eta_js_worker` or similar package because values need serialization.
- Do not copy Effect-TS environment/layer machinery. Eta dependencies remain ordinary OCaml values.

## Suggested Commit Sequence

1. `docs: decide runtime contract vnext direction`
2. `refactor: decouple runtime contract from eio direct style` if Phase 0 selects shared vNext, otherwise skip
3. `build: add eta_js melange package shell`
4. `feat(js): add pure eta_js data modules`
5. `feat(js): add scheduler and fiber runtime kernel`
6. `feat(js): add async effect interpreter`
7. `feat(js): add core runtime combinators`
8. `feat(js): add structured concurrency`
9. `feat(js): add queue channel semaphore pubsub`
10. `feat(js): add pool resource supervisor`
11. `test(js): add node melange runtime suite`
12. `docs: document eta_js runtime boundary`

## Final Verification Commands

Use the exact Melange command discovered in Task 0.1. The expected final shape is:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @melange @test/js/js-tests-build'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js'
nix develop -c dune runtest --force
```

The native Eta verification substrate is separate from the JavaScript build path. JS test stanzas are guarded by `ETA_JS_TESTS=true` so default native `dune runtest --force` does not require Melange.

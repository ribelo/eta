# Eta JS Production Readiness And Effect-Smol Parity Implementation Plan

> Use the subagent-driven-development skill to implement this plan task-by-task when delegation is available.

**Goal:** Bring `eta_js` from a verified prototype toward production readiness and closer behavioral parity with the local `.reference/effect-smol` runtime, without weakening Eta package boundaries.

**Architecture:** Keep `eta_js` as an optional Melange package while hardening the async fiber runtime, test harness, cancellation model, public fiber/deferred primitives, stream package, observability hooks, and release gates. Treat effect-smol as behavioral prior art, not a dependency and not a mandate to copy its environment/layer/application-framework surface into Eta.

**Tech Stack:** OCaml 5 mainline JS switch, Dune, Melange, Node, optional browser smoke tests, `eta_js`, `eta_js_test`, local `.reference/effect-smol`, native Eta tests through Nix.

---

## Baseline And Assumptions

This plan assumes the repository already contains the first `eta_js` prototype from `js-runtime-implementation-plan.md`:

- `dune-project` declares package `eta_js` and package `eta_js_test`.
- `lib/js/` contains the JS async effect runtime and core primitives.
- `lib/js_test/` contains JS test helpers and a virtual clock.
- `test/js/run_js_tests.ml` compiles through Melange and runs under Node.
- `eta_js.opam` and `eta_js_test.opam` are generated from `dune-project`.

If an implementing agent starts from a clean checkout without those files, stop and first complete `js-runtime-implementation-plan.md`. Do not merge this plan into the original implementation plan; keep this file as the production-readiness follow-up.

Important constraints:

- Do not use OxCaml with Melange. The JS path uses the dedicated mainline OCaml switch:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @melange @test/js/js-tests-build'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js'
```

- Keep root package `eta` free of Melange, JS, Node, browser, testing, Eio, blocking, HTTP, SQL, C-stub, or provider dependencies.
- Keep `eta_js` free of `eta_eio`, `eta_blocking`, `eta_stream`, `eta_http`, `eta_sql`, and provider packages.
- Prefer deleting stale prototype APIs over compatibility shims. Eta does not carry migration shims inside the library.
- Do not copy effect-smol's full environment/layer machinery into Eta unless a later design explicitly changes Eta's application-boundary policy. Eta programs should keep ordinary OCaml values for application state.
- Do not claim `eta_js` is production ready until all gates in this plan pass.

## Current Gaps

Current `eta_js` is a useful prototype, but it is not production ready.

Known gaps to close:

- JS tests are concentrated in `test/js/run_js_tests.ml`; they are harder to audit and are not organized as a parity matrix.
- The current Node test style schedules many promises directly. It needs a runner that records all async tests and awaits them before process exit.
- `eta_js_test.Test_clock.sleep` exists, but `Eta_js.Effect.delay` still uses host timers directly. Production tests need deterministic control over runtime timers.
- Public `Eta_js.Fiber` currently exposes runtime internals more than a production user-facing fiber handle.
- `eta_js` lacks effect-smol-like public fiber handles: `fork`, `join`, `await`, `interrupt`, `poll`.
- `eta_js` lacks public `Deferred`, `Latch`, effectful `Ref`, and `Synchronized_ref` equivalents.
- `eta_js` lacks `Effect.die`, `fail_cause`, `sandbox`, `unsandbox`, `catch_cause`, `tap_cause`, `match`, `match_effect`, and richer timeout variants.
- `Effect.uninterruptible` and `uninterruptible_mask` are absent, yet native Eta has tests for those semantics.
- The JS stream surface is not implemented as an optional `eta_js_stream` package.
- Observability capabilities exist, but effect combinators are not wired deeply enough for production-level span/log/metric behavior.
- Browser compatibility is not verified. Node passing is necessary but not sufficient for production JS use.
- Stress/property testing is much shallower than native Eta and effect-smol.
- API stability, docs, package build artifacts, and release criteria are not written down.

## Effect-Smol Parity Scope

Effect-smol is broad. This plan intentionally prioritizes the subset that strengthens Eta's runtime model.

### Tier P0: Required For Production-Like Runtime Semantics

- Effect construction and composition: `pure`, `fail`, `sync`, `async`, `map`, `bind`, `tap`, `zip`, `match`, `catch`.
- Cause-aware error handling: `die`, `fail_cause`, `sandbox`, `unsandbox`, `catch_cause`, `tap_cause`.
- Runtime execution: `run_promise`, `run_promise_exit`, `run_now` for purely synchronous work, `run_fork`, callback runner.
- Fiber handles: `fork`, `fork_scoped`, `fork_daemon`, `await`, `join`, `interrupt`, `poll`, observer registration.
- Cancellation masks: `uninterruptible`, `uninterruptible_mask`, and interruptibility restoration.
- Deterministic clock integration for `delay`, `timeout`, retry/repeat schedules, and tests.
- Deferred/latch primitives for fiber coordination.
- Resource finalization under success, typed failure, defect, cancellation, and finalizer failure.

### Tier P1: Strong Feature Parity For Eta JS Users

- Effectful `Ref` and `Synchronized_ref`.
- `Queue`, `Pubsub`, `Semaphore`, `Pool`, and `Resource` stress parity.
- JS stream package with pure streams, queues/mailboxes, merge, bounded flat-map concurrency, and cancellation.
- Promise bridge: abortable promises, defect rejection, typed adapter errors, idempotent cancellation.
- Runtime-local and scoped context behavior.
- Node `run_main` style helper with signal handling and teardown.

### Tier P2: Observability And Operations

- Memory tracer/logger/meter tests.
- `Effect.named`, `with_span`, `with_log_span`, `annotate`, `log`, `log_info`, `log_error`, and `tap_error` integration.
- Runtime diagnostics for daemon failures and unhandled defects.
- Browser smoke tests for timers, microtasks, AbortController, Promise behavior, and public package import.
- Benchmarks and leak checks.

### Explicit Non-Goals

- No full effect-smol `Layer`/`Context`/application dependency-injection port in this series.
- No Schema, SQL, AI, FileSystem, Terminal, or Node platform package parity in this series.
- No Eio, native blocking, Cstruct, file-path, or native stream dependencies in `eta_js`.
- No npm package promise until a packaging plan is written and browser/Node smoke tests pass.

## Production Readiness Gates

Every phase must end with these gates unless the phase explicitly says otherwise:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @melange @test/js/js-tests-build'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js'
nix develop -c dune runtest --force
```

Additional gates added later:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js_stream'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_BROWSER_TESTS=true dune runtest test/js_browser'
```

Expected outcome for all gates: exit code `0`.

## Phase 0: Inventory, Test Runner, And CI Shape

### Task 0.1: Write A Parity Matrix Document

**Objective:** Create an explicit checklist so parity work is visible and reviewable.

**Files:**
- Create: `docs/eta_js/effect-smol-parity-matrix.md`

**Steps:**

1. Create directory `docs/eta_js/`.
2. Add a table with columns: `Area`, `Effect-smol reference`, `Eta native reference`, `Eta JS status`, `Target`, `Tests`.
3. Seed rows from these files:
   - `.reference/effect-smol/packages/effect/src/Effect.ts`
   - `.reference/effect-smol/packages/effect/src/Fiber.ts`
   - `.reference/effect-smol/packages/effect/src/Deferred.ts`
   - `.reference/effect-smol/packages/effect/src/Stream.ts`
   - `.reference/effect-smol/packages/effect/src/Queue.ts`
   - `.reference/effect-smol/packages/effect/src/PubSub.ts`
   - `.reference/effect-smol/packages/effect/src/Semaphore.ts`
   - `.reference/effect-smol/packages/effect/src/Pool.ts`
   - `.reference/effect-smol/packages/effect/src/Clock.ts`
   - `.reference/effect-smol/packages/effect/src/Tracer.ts`
4. Mark each row as one of `implemented`, `implemented-needs-tests`, `planned`, `deferred`, or `non-goal`.
5. Include a short note that effect-smol `Layer`/`Context` parity is a non-goal unless Eta's app-boundary policy changes.

**Verification:**

Run:

```bash
rg -n "Deferred|Fiber|Stream|Clock|Layer|non-goal" docs/eta_js/effect-smol-parity-matrix.md
```

Expected: rows exist for each named area.

### Task 0.2: Split JS Tests Into Named Files

**Objective:** Replace the monolithic JS test file with named test modules.

**Files:**
- Modify: `test/js/dune`
- Create: `test/js/test_pure.ml`
- Create: `test/js/test_runtime.ml`
- Create: `test/js/test_concurrency.ml`
- Create: `test/js/test_queue.ml`
- Create: `test/js/test_channel.ml`
- Create: `test/js/test_semaphore.ml`
- Create: `test/js/test_pubsub.ml`
- Create: `test/js/test_pool.ml`
- Create: `test/js/test_resource.ml`
- Create: `test/js/test_supervisor.ml`
- Create: `test/js/test_promise.ml`
- Create: `test/js/test_clock.ml`
- Modify: `test/js/run_js_tests.ml`

**Steps:**

1. Move shared assertion helpers from `run_js_tests.ml` into `test/js/test_support.ml`.
2. Add `test_support` to the `(modules ...)` list in `test/js/dune`.
3. Move one existing test group at a time into a named module.
4. In each new module, expose:

```ocaml
val tests : (string * (unit -> unit Js.Promise.t)) list
```

5. Keep `run_js_tests.ml` as the aggregator only.

**Verification:**

Run:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js'
```

Expected: same test behavior as before the split.

### Task 0.3: Replace Fire-And-Forget JS Tests With Awaited Test Runner

**Objective:** Ensure Node cannot exit before all asynchronous assertions run.

**Files:**
- Modify: `lib/js_test/eta_js_test.mli`
- Modify: `lib/js_test/eta_js_test.ml`
- Modify: `test/js/run_js_tests.ml`
- Modify: all `test/js/test_*.ml`

**Target API:**

```ocaml
type test = string * (unit -> unit Js.Promise.t)

val run_all : test list -> unit Js.Promise.t
val expect_ok : string -> (unit -> unit) -> unit Js.Promise.t
```

**Steps:**

1. Add `type test` to `Eta_js_test`.
2. Implement `run_all` by sequencing tests, not by ignoring promises.
3. Each test should return a promise that resolves only after all assertions in that test have run.
4. Update `run_js_tests.ml` to call `Eta_js_test.run_all all_tests`.
5. The Dune Node action may stay the same if the generated top-level promise keeps Node alive. If not, add `test/js/node_runner.mjs` that imports the generated module and awaits the exported promise.

**Verification:**

Temporarily add a test that fails inside a delayed promise. Run:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js'
```

Expected: command fails. Remove the temporary failing test and rerun; expected: pass.

### Task 0.4: Add A Stable JS Alias

**Objective:** Make JS verification easy in CI and for agents.

**Files:**
- Modify: `test/js/dune`
- Modify: root `dune` if needed

**Steps:**

1. Add alias `@js-runtest` or `@eta-js-runtest` that builds and runs Node tests when `ETA_JS_TESTS=true`.
2. Add alias `@eta-js-build` for `@melange @test/js/js-tests-build` if Dune supports the clean mapping locally.
3. Do not enable JS tests by default in native `dune runtest`; native switches may not have Melange.

**Verification:**

Run:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @eta-js-build'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @eta-js-runtest'
```

Expected: both pass.

## Phase 1: Deterministic Runtime Clock

### Task 1.1: Add Runtime Clock Capability

**Objective:** Make `Effect.delay`, timeout, retry, and repeat testable with a virtual runtime clock.

**Files:**
- Modify: `lib/js/runtime_core.mli`
- Modify: `lib/js/runtime_core.ml`
- Modify: `lib/js/runtime.mli`
- Modify: `lib/js/runtime.ml`
- Modify: `lib/js/effect_core.mli`
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect.mli`

**Target shape:**

```ocaml
type timer_cancel = unit -> unit

type clock = {
  now_ms : unit -> int;
  sleep : Duration.t -> (unit -> unit) -> timer_cancel;
}

val default_clock : unit -> clock

val create :
  ?clock:clock ->
  ?scheduler:Scheduler.t ->
  ...
  unit ->
  'err t
```

**Steps:**

1. Add `clock` to `Runtime_core.t`.
2. Add `clock` to `Effect_core.context`.
3. Implement `default_clock` using `Js_interop.date_now`, `set_timeout`, and `clear_timeout`.
4. Update `Runtime.context` to pass `runtime.clock`.
5. Update `Effect.sleep`/`delay` internals to use `context.clock.sleep` instead of direct `Js_interop.set_timeout`.
6. Keep cancellation idempotent.

**Verification:**

Update the existing JS delay test so it passes under a virtual clock without wall time.

### Task 1.2: Wire `eta_js_test.Test_clock` Into Runtime

**Objective:** Let tests create a runtime whose `Effect.delay` uses virtual time.

**Files:**
- Modify: `lib/js_test/test_clock.mli`
- Modify: `lib/js_test/test_clock.ml`
- Modify: `test/js/test_clock.ml`
- Modify: `test/js/test_runtime.ml`

**Target API:**

```ocaml
val clock : t -> Eta_js.Runtime_core.clock
val runtime : ?scheduler:Eta_js.Scheduler.t -> t -> 'err Eta_js.Runtime.t
```

**Steps:**

1. Store sleepers in `(deadline_ms, sequence)` order.
2. Expose `clock t`.
3. Expose `runtime t` as `Eta_js.Runtime.create ~clock:(clock t)`.
4. Update tests for `Effect.delay`, `timeout`, `retry`, and `repeat` to use `Test_clock.runtime`.
5. Remove tests that rely on `Duration.zero` just to avoid wall time when a virtual clock can prove the real behavior.

**Verification:**

Tests must prove:

- Two sleepers with the same deadline wake by insertion order.
- Later deadlines do not wake early.
- `Effect.timeout` cancels the body only after the virtual deadline.
- `retry` and `repeat` respect scheduled virtual delays.

### Task 1.3: Add Clock Regression Tests Against Native Semantics

**Objective:** Port native `eta_test` clock-style behavior into JS.

**Files:**
- Read: `test/test/test_eta_test.ml` or local clock tests under `test/test/`
- Modify: `test/js/test_clock.ml`

**Tests:**

1. `adjust wakes in deadline order`.
2. `adjust drains cascading sleeps`.
3. `set_time wakes due sleepers`.
4. `timeout does not complete before deadline`.

**Verification:**

Run JS tests. Expected: pass without using wall-clock sleeps.

## Phase 2: Public Fiber Handles And Forking

### Task 2.1: Separate Runtime Fiber Internals From Public Fiber API

**Objective:** Prevent production users from depending on mutable runtime internals.

**Files:**
- Create: `lib/js/runtime_fiber.ml`
- Create: `lib/js/runtime_fiber.mli`
- Modify: `lib/js/fiber.ml`
- Modify: `lib/js/fiber.mli`
- Modify: `lib/js/dune`
- Modify: internal imports in `lib/js/*.ml`

**Steps:**

1. Move the current implementation of `Fiber` into `Runtime_fiber`.
2. Keep `Runtime_fiber` private in `lib/js/dune` if Dune layout allows.
3. Replace internal references to `Fiber` with `Runtime_fiber`.
4. Rebuild before adding the new public API.

**Verification:**

Run the JS build. Expected: no public behavior change yet.

### Task 2.2: Add Public `Eta_js.Fiber` Handle Type

**Objective:** Match effect-smol's basic `Fiber.await`, `Fiber.join`, `Fiber.interrupt`, and `Fiber.poll` behavior.

**Files:**
- Modify: `lib/js/fiber.mli`
- Modify: `lib/js/fiber.ml`
- Modify: `lib/js/effect.mli`
- Modify: `lib/js/effect.ml`
- Test: `test/js/test_fiber.ml`
- Modify: `test/js/dune`

**Target API:**

```ocaml
type ('a, 'err) t

val id : ('a, 'err) t -> int
val await : ('a, 'err) t -> (('a, 'err Cause.t) result, 'outer_err) Effect.t
val join : ('a, 'err) t -> ('a, 'err) Effect.t
val interrupt : ('a, 'err) t -> (unit, 'outer_err) Effect.t
val poll : ('a, 'err) t -> ('a, 'err Cause.t) result option

val fork : ('a, 'err) Effect.t -> (('a, 'err) t, 'outer_err) Effect.t
val fork_scoped : ('a, 'err) Effect.t -> (('a, 'err) t, 'outer_err) Effect.t
val fork_daemon : (unit, 'err) Effect.t -> (unit, 'outer_err) Effect.t
```

**Steps:**

1. Create a public handle record that wraps a `Runtime_fiber.t` plus a typed result promise.
2. Implement `await` by waiting on that typed result promise.
3. Implement `join` by awaiting and re-raising typed failure cause.
4. Implement `interrupt` by cancelling and waiting for settlement.
5. Implement `poll` by inspecting settled state without suspension.
6. Add `Effect.fork`, `Effect.fork_scoped`, and `Effect.fork_daemon` as aliases or constructors.
7. Update `Eta_js` export if module names changed.

**Verification tests:**

- `fork` starts concurrently and `join` returns the value.
- `await` returns `Error cause` for child failure.
- `interrupt` runs child finalizer.
- `poll` is `None` before completion and `Some _` after completion.
- Parent scope cancels scoped child on return.
- Daemon participates in `Runtime.drain_promise`.

### Task 2.3: Port Native Supervisor Tests To Public Fiber Tests

**Objective:** Ensure supervisor and public fiber semantics agree.

**Files:**
- Read: `test/eta/test_eta_supervisor.ml`
- Modify: `test/js/test_fiber.ml`
- Modify: `test/js/test_supervisor.ml`

**Steps:**

1. Add a test where a supervisor child is also awaited through the public fiber path if the implementation shares handles.
2. Add a test where child finalizer failure is not swallowed by `Fiber.interrupt`.
3. Add nested fork/supervisor composition test.

**Verification:**

JS tests pass and native tests still pass.

## Phase 3: Cancellation Masks And Cause-Aware Effect Surface

### Task 3.1: Add Interruptibility State To JS Fibers

**Objective:** Support `uninterruptible` and `uninterruptible_mask`.

**Files:**
- Modify: `lib/js/runtime_fiber.mli`
- Modify: `lib/js/runtime_fiber.ml`
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/effect_core.mli`

**Rules:**

- A fiber can receive cancellation while uninterruptible, but it must defer interruption until the mask exits or a restored interruptible region checks cancellation.
- Finalizers must run in an uninterruptible region, unless explicitly restored.
- `Effect.check` must surface deferred interruption only when the current region is interruptible.

**Verification tests:**

Port the native tests from `test/eta/test_eta_effect_uninterruptible.ml` into `test/js/test_uninterruptible.ml`.

### Task 3.2: Add `Effect.uninterruptible`

**Objective:** Provide the basic cancellation mask.

**Files:**
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/effect_core.mli`
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect.mli`
- Create: `test/js/test_uninterruptible.ml`
- Modify: `test/js/dune`

**Target API:**

```ocaml
val uninterruptible : ('a, 'err) t -> ('a, 'err) t
```

**Tests:**

- Race does not cancel an uninterruptible loser until the loser reaches the end of the mask.
- Finalizer still runs on cancellation.
- Timeout inside uninterruptible region is deferred.

### Task 3.3: Add `Effect.uninterruptible_mask`

**Objective:** Allow selected regions inside a mask to restore interruptibility.

**Files:**
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect.mli`
- Modify: `test/js/test_uninterruptible.ml`

**Target API:**

```ocaml
type restore = { restore : 'a 'err. ('a, 'err) t -> ('a, 'err) t }

val uninterruptible_mask : (restore -> ('a, 'err) t) -> ('a, 'err) t
```

Use a different OCaml encoding if the rank-2 record shape does not compile cleanly under Melange, but keep the user-facing semantics explicit.

**Tests:**

- Restored region observes cancellation.
- Nested masks preserve the outer mask after the restored region exits.

### Task 3.4: Add Cause-Aware Constructors And Handlers

**Objective:** Move closer to effect-smol's `die`, `catchCause`, `sandbox`, and `matchCause` behavior.

**Files:**
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/effect_core.mli`
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect.mli`
- Modify: `lib/js/cause.mli`
- Modify: `lib/js/cause.ml`
- Test: `test/js/test_cause_effect.ml`

**Target API:**

```ocaml
val die : exn -> ('a, 'err) t
val fail_cause : 'err Cause.t -> ('a, 'err) t
val sandbox : ('a, 'err) t -> ('a, 'err Cause.t) t
val unsandbox : ('a, 'err Cause.t) t -> ('a, 'err) t
val catch_cause : ('err Cause.t -> ('a, 'err2) t) -> ('a, 'err) t -> ('a, 'err2) t
val tap_cause : ('err Cause.t -> unit) -> ('a, 'err) t -> ('a, 'err) t
val match_ : on_success:('a -> 'b) -> on_failure:('err -> 'b) -> ('a, 'err) t -> ('b, 'outer) t
val match_effect :
  on_success:('a -> ('b, 'err2) t) ->
  on_failure:('err -> ('b, 'err2) t) ->
  ('a, 'err) t ->
  ('b, 'err2) t
```

Use `match_` as the OCaml value name because `match` is a keyword.

**Tests:**

- `die` produces `Cause.Die`.
- `catch` does not catch defects.
- `catch_cause` catches typed failure, defect, interrupt, finalizer, and suppressed causes.
- `sandbox |> unsandbox` round-trips a typed failure and a defect.

## Phase 4: Deferred, Latch, Ref, And Synchronized Ref

### Task 4.1: Add `Deferred`

**Objective:** Provide effect-smol-style one-shot completion for multiple waiters.

**Files:**
- Create: `lib/js/deferred.mli`
- Create: `lib/js/deferred.ml`
- Modify: `lib/js/dune`
- Modify: `lib/js/eta_js.ml`
- Modify: `lib/js/eta_js.mli`
- Create: `test/js/test_deferred.ml`
- Modify: `test/js/dune`

**Target API:**

```ocaml
type ('a, 'err) t

val make : unit -> (('a, 'err) t, 'outer_err) Effect.t
val make_unsafe : unit -> ('a, 'err) t
val await : ('a, 'err) t -> ('a, 'err) Effect.t
val poll : ('a, 'err) t -> ('a, 'err Cause.t) result option
val done_ : ('a, 'err) t -> ('a, 'err) Exit.t -> (bool, 'outer_err) Effect.t
val succeed : ('a, 'err) t -> 'a -> (bool, 'outer_err) Effect.t
val fail : ('a, 'err) t -> 'err -> (bool, 'outer_err) Effect.t
val fail_cause : ('a, 'err) t -> 'err Cause.t -> (bool, 'outer_err) Effect.t
val interrupt : ('a, 'err) t -> (bool, 'outer_err) Effect.t
```

**Rules:**

- Completion is single-assignment.
- Multiple waiters all resume.
- Completing an already completed deferred returns `false`, not an exception.
- Awaiting an interrupted deferred raises an interrupt cause.

**Tests:**

- Await before succeed.
- Succeed before await.
- Many waiters wake in registration order where observable.
- Second completion returns `false`.
- Cancellation of one waiter does not remove other waiters.

### Task 4.2: Add `Latch`

**Objective:** Provide a small coordination primitive used by tests and higher-level runtime code.

**Files:**
- Create: `lib/js/latch.mli`
- Create: `lib/js/latch.ml`
- Modify: `lib/js/dune`
- Modify: `lib/js/eta_js.ml`
- Modify: `lib/js/eta_js.mli`
- Create: `test/js/test_latch.ml`
- Modify: `test/js/dune`

**Target API:**

```ocaml
type t

val make : unit -> (t, 'err) Effect.t
val make_unsafe : unit -> t
val await : t -> (unit, 'err) Effect.t
val release : t -> (bool, 'err) Effect.t
val is_released : t -> bool
```

**Tests:**

- Await blocks until release.
- Release wakes all waiters.
- Second release returns `false`.
- Cancelled waiter is removed.

### Task 4.3: Add Effectful `Ref`

**Objective:** Mirror effect-smol `Ref` for effect composition without exposing raw mutation as the only option.

**Files:**
- Create: `lib/js/ref.mli`
- Create: `lib/js/ref.ml`
- Modify: `lib/js/dune`
- Modify: `lib/js/eta_js.ml`
- Modify: `lib/js/eta_js.mli`
- Create: `test/js/test_ref.ml`

**Target API:**

```ocaml
type 'a t

val make : 'a -> ('a t, 'err) Effect.t
val get : 'a t -> ('a, 'err) Effect.t
val set : 'a t -> 'a -> (unit, 'err) Effect.t
val update : 'a t -> ('a -> 'a) -> (unit, 'err) Effect.t
val get_and_set : 'a t -> 'a -> ('a, 'err) Effect.t
val update_and_get : 'a t -> ('a -> 'a) -> ('a, 'err) Effect.t
val modify : 'a t -> ('a -> 'b * 'a) -> ('b, 'err) Effect.t
```

**Tests:**

- `modify` returns the derived value and stores the new state.
- Ref operations compose with retry and finalizers.

### Task 4.4: Add `Synchronized_ref`

**Objective:** Provide serialized effectful state updates.

**Files:**
- Create: `lib/js/synchronized_ref.mli`
- Create: `lib/js/synchronized_ref.ml`
- Modify: `lib/js/dune`
- Modify: `lib/js/eta_js.ml`
- Modify: `lib/js/eta_js.mli`
- Create: `test/js/test_synchronized_ref.ml`

**Target API:**

```ocaml
type 'a t

val make : 'a -> ('a t, 'err) Effect.t
val get : 'a t -> ('a, 'err) Effect.t
val update_effect : 'a t -> ('a -> ('a, 'err) Effect.t) -> (unit, 'err) Effect.t
val modify_effect : 'a t -> ('a -> ('b * 'a, 'err) Effect.t) -> ('b, 'err) Effect.t
```

**Rules:**

- Updates run one at a time.
- Failed update does not publish a partial value.
- Cancelled waiting update is removed.

**Tests:**

- Parallel updates serialize.
- Typed failure leaves old value.
- Cancellation removes waiter and lets later updates continue.

## Phase 5: Primitive Hardening And Stress Tests

### Task 5.1: Add Property-Style Stress Harness

**Objective:** Catch scheduler and cancellation bugs without adding heavyweight dependencies to `eta_js`.

**Files:**
- Create: `test/js/test_stress.ml`
- Modify: `test/js/dune`
- Modify: `lib/js_test/eta_js_test.mli`
- Modify: `lib/js_test/eta_js_test.ml`

**Steps:**

1. Add deterministic pseudo-random helper or reuse `Eta_js.Random`.
2. Add a loop helper:

```ocaml
val repeat : int -> (int -> unit Js.Promise.t) -> unit Js.Promise.t
```

3. Use small deterministic random workloads, not infinite fuzzing.

**Tests:**

- Queue no lost values under random send/recv/cancel.
- Channel capacity never goes negative or above capacity.
- Semaphore permits always sum to capacity plus held permits.
- Pool active count returns to zero after cancellations.
- PubSub retained depth never exceeds capacity.

### Task 5.2: Strengthen Queue Tests

**Objective:** Reach parity with native Queue edge cases.

**Files:**
- Read: `test/eta/test_eta_queue.ml`
- Modify: `test/js/test_queue.ml`

**Tests:**

- Clean close drains buffered values.
- Error close drains buffered values, then fails.
- Cancel blocked receiver removes waiter.
- Cancelled receiver does not consume a later sent value.
- Stats match operations.

### Task 5.3: Strengthen Channel Tests

**Objective:** Cover close, FIFO, cancellation, and overflow edge cases.

**Files:**
- Read: `test/eta/test_eta_channel.ml`
- Modify: `test/js/test_channel.ml`

**Tests:**

- FIFO send/recv.
- Sender cancellation does not pass a value.
- Receiver cancellation does not drop a delivered value unless committed.
- Close wakes blocked senders and receivers.
- Close drains buffer before reporting closed.

### Task 5.4: Strengthen Semaphore Tests

**Objective:** Match native permit-accounting guarantees.

**Files:**
- Read: native semaphore tests under `test/eta/`
- Modify: `test/js/test_semaphore.ml`

**Tests:**

- `try_acquire` does not barge queued waiters.
- Acquiring more than capacity fails clearly.
- Release over capacity fails clearly.
- Cancel after wakeup returns permits.
- FIFO wake order.

### Task 5.5: Strengthen PubSub Tests

**Objective:** Prove backpressure, retention, subscription cleanup, and close behavior.

**Files:**
- Read: native pubsub tests under `test/eta/`
- Modify: `test/js/test_pubsub.ml`

**Tests:**

- Multiple subscribers receive all retained values.
- Late subscriber receives only retained values.
- Backpressure publisher cancellation removes queued publisher.
- Subscription cancellation releases lagging retained entries.
- Close wakes blocked publishers and subscribers.

### Task 5.6: Strengthen Pool Tests

**Objective:** Make the JS pool credible under cancellation and shutdown.

**Files:**
- Read: native pool tests under `test/eta/`
- Modify: `test/js/test_pool.ml`
- Modify: `lib/js/pool.ml` only if tests expose bugs

**Tests:**

- Max size is respected under concurrent checkout.
- Pending checkout cancellation removes waiter.
- Shutdown wakes pending checkout.
- Shutdown waits for active resource release.
- Health failure closes unhealthy idle resource and opens replacement.
- Release finalizer failure is surfaced.
- Idle eviction does not leak active capacity.

## Phase 6: JS Stream Package

### Task 6.1: Add `eta_js_stream` Package Shell

**Objective:** Provide a JS stream package without depending on native `eta_stream`.

**Files:**
- Modify: `dune-project`
- Create generated: `eta_js_stream.opam`
- Create: `lib/js_stream/dune`
- Create: `lib/js_stream/eta_js_stream.mli`
- Create: `lib/js_stream/eta_js_stream.ml`
- Create: `test/js_stream/dune`
- Create: `test/js_stream/run_js_stream_tests.ml`

**Package stanza:**

```lisp
(package
 (name eta_js_stream)
 (synopsis "JavaScript streams for eta_js")
 (description "eta_js_stream provides pull-based streams for eta_js without Eio or Cstruct dependencies.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.21))
  (melange (>= 6.0.1))
  eta_js
  eta_js_test))
```

**Rules:**

- No dependency on `eta_stream`, `eta_eio`, `eio`, or `cstruct`.
- Keep package/library/module alignment: `eta_js_stream` -> `Eta_js_stream`.

**Verification:**

Run the generated opam build target and JS stream test target.

### Task 6.2: Implement Pure Stream Constructors And Sinks

**Objective:** Port the native stream pure surface first.

**Files:**
- Read: `lib/stream/eta_stream.mli`
- Read: `lib/stream/eta_stream.ml`
- Modify: `lib/js_stream/eta_js_stream.mli`
- Modify: `lib/js_stream/eta_js_stream.ml`
- Modify: `test/js_stream/run_js_stream_tests.ml`

**Target API:**

```ocaml
type +'a chunk = 'a list

module Stream : sig
  type ('a, 'err) t
  val empty : ('a, 'err) t
  val succeed : 'a -> ('a, 'err) t
  val from_chunk : 'a chunk -> ('a, 'err) t
  val from_iterable : 'a list -> ('a, 'err) t
  val range : start:int -> stop:int -> (int, 'err) t
  val from_effect : ('a, 'err) Eta_js.Effect.t -> ('a, 'err) t
  val fail : 'err -> ('a, 'err) t
  val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
  val map_effect : ('a -> ('b, 'err) Eta_js.Effect.t) -> ('a, 'err) t -> ('b, 'err) t
  val filter : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  val take : int -> ('a, 'err) t -> ('a, 'err) t
  val drop : int -> ('a, 'err) t -> ('a, 'err) t
  val scan : ('s -> 'a -> 's) -> 's -> ('a, 'err) t -> ('s, 'err) t
  val grouped : int -> ('a, 'err) t -> ('a list, 'err) t
  val concat : ('a, 'err) t -> ('a, 'err) t -> ('a, 'err) t
  val flat_map : ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t
end

module Sink : sig
  type ('in_, 'out, 'err) t
  val fold : ('out -> 'in_ -> 'out) -> 'out -> ('in_, 'out, 'err) t
  val fold_effect : ('out -> 'in_ -> ('out, 'err) Eta_js.Effect.t) -> 'out -> ('in_, 'out, 'err) t
  val collect_to_list : ('a, 'a list, 'err) t
  val count : ('a, int, 'err) t
  val drain : ('a, unit, 'err) t
end

val run : ('a, 'err) Stream.t -> ('a, 'b, 'err) Sink.t -> ('b, 'err) Eta_js.Effect.t
val run_collect : ('a, 'err) Stream.t -> ('a list, 'err) Eta_js.Effect.t
val run_drain : ('a, 'err) Stream.t -> (unit, 'err) Eta_js.Effect.t
```

**Tests:**

- Pure fusion: `range |> map |> filter |> take |> run_collect`.
- `grouped` rejects `n <= 0`.
- `take 0` is lazy and does not run `from_effect`.
- Downstream failure runs finalizers.

### Task 6.3: Add Stream Mailbox And Queue Sources

**Objective:** Provide producer/consumer adapters for JS streams.

**Files:**
- Create: `lib/js_stream/mailbox_internal.ml`
- Create: `lib/js_stream/mailbox_internal.mli`
- Modify: `lib/js_stream/eta_js_stream.ml`
- Modify: `lib/js_stream/eta_js_stream.mli`
- Modify: `test/js_stream/run_js_stream_tests.ml`

**Target API:**

```ocaml
module Mailbox : sig
  type 'a t
  type offer_result = Enqueued | Dropped | Closed
  val create : ?capacity:int -> unit -> 'a t
  val offer : 'a t -> 'a -> offer_result
  val close : 'a t -> unit
  val dropped : 'a t -> int
  val length : 'a t -> int
  val to_stream : 'a t -> ('a, 'err) Stream.t
  val to_batch_stream : max:int -> 'a t -> ('a list, 'err) Stream.t
end

val from_queue : ('a, 'err) Eta_js.Queue.t -> ('a, 'err) Stream.t
```

**Tests:**

- Mailbox drops when full.
- Mailbox close drains queued values then ends.
- Batch stream emits partial final batch.
- Queue clean close ends stream.
- Queue error close fails after draining buffered values.

### Task 6.4: Add Stream Merge And Bounded Flat Map

**Objective:** Implement the highest-risk stream concurrency operators.

**Files:**
- Modify: `lib/js_stream/eta_js_stream.ml`
- Modify: `lib/js_stream/eta_js_stream.mli`
- Modify: `test/js_stream/run_js_stream_tests.ml`

**Target API:**

```ocaml
val merge : ('a, 'err) Stream.t -> ('a, 'err) Stream.t -> ('a, 'err) Stream.t

val flat_map_par :
  max_concurrency:int ->
  ('a -> ('b, 'err) Stream.t) ->
  ('a, 'err) Stream.t ->
  ('b, 'err) Stream.t
```

**Tests:**

- `merge` interleaves values from both sides.
- Downstream `take` cancels both upstream producers.
- Upstream failure fails the merged stream and cancels the other side.
- `flat_map_par` respects max concurrency.
- Inner failure fails stream and cancels remaining inners.

## Phase 7: Observability And Runtime Diagnostics

### Task 7.1: Add Effect Observability Frames

**Objective:** Wire runtime logger/tracer/meter capabilities into effect execution.

**Files:**
- Modify: `lib/js/effect_core.ml`
- Modify: `lib/js/effect_core.mli`
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect.mli`
- Modify: `lib/js/capabilities.mli`
- Modify: `lib/js/capabilities.ml`
- Create: `test/js/test_observability.ml`

**Target API:**

```ocaml
val named : string -> ('a, 'err) t -> ('a, 'err) t
val annotate : string -> string -> ('a, 'err) t -> ('a, 'err) t
val annotate_all : (string * string) list -> ('a, 'err) t -> ('a, 'err) t
val suppress_observability : ('a, 'err) t -> ('a, 'err) t
```

**Tests:**

- Named span records start/end.
- Typed failure records failure status.
- Defect records diagnostic exception.
- Child fibers inherit parent span and annotations.
- Suppression disables nested logging/tracing.

### Task 7.2: Add Logging Combinators

**Objective:** Match effect-smol's practical logging surface while using Eta capabilities.

**Files:**
- Modify: `lib/js/effect.ml`
- Modify: `lib/js/effect.mli`
- Modify: `test/js/test_observability.ml`

**Target API:**

```ocaml
val log : string -> (unit, 'err) t
val log_level : Log_level.t -> string -> (unit, 'err) t
val log_debug : string -> (unit, 'err) t
val log_info : string -> (unit, 'err) t
val log_warning : string -> (unit, 'err) t
val log_error : string -> (unit, 'err) t
```

**Tests:**

- Logger receives records in order.
- Active span ids are included when a tracer is active.
- Logging with no logger is a no-op, not a failure.

### Task 7.3: Add Runtime Daemon Failure Diagnostics

**Objective:** Make background failures observable and testable.

**Files:**
- Modify: `lib/js/runtime_core.mli`
- Modify: `lib/js/runtime_core.ml`
- Modify: `lib/js/runtime.mli`
- Modify: `lib/js/runtime.ml`
- Modify: `test/js/test_runtime.ml`

**Target API:**

```ocaml
val daemon_failures : 'err Runtime.t -> Obj.t Cause.t list
val clear_daemon_failures : 'err Runtime.t -> unit
```

Use a typed-erased cause list because daemon failures can outlive the caller's typed error channel.

**Tests:**

- Failed daemon records a cause.
- `Runtime.drain_promise` waits for finite daemon completion.
- Clearing diagnostics removes old failures.

## Phase 8: Browser And Node Platform Verification

### Task 8.1: Add Browser Smoke Test Target

**Objective:** Verify that core runtime assumptions hold in a browser-like JS environment.

**Files:**
- Create: `test/js_browser/dune`
- Create: `test/js_browser/run_browser_tests.ml`
- Create: `test/js_browser/browser_runner.mjs` or equivalent if needed

**Rules:**

- Do not add browser dependencies to root `eta`.
- Keep browser tests opt-in with `ETA_JS_BROWSER_TESTS=true`.
- Test browser primitives only: `queueMicrotask`, timers, Promise, AbortController, public import surface.

**Verification:**

Run:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_BROWSER_TESTS=true dune runtest test/js_browser'
```

Expected: pass in the selected browser test runner.

### Task 8.2: Add Node `run_main`

**Objective:** Provide a practical production runner for Node programs.

**Files:**
- Create: `lib/js_node/dune`
- Create: `lib/js_node/eta_js_node.mli`
- Create: `lib/js_node/eta_js_node.ml`
- Modify: `dune-project`
- Create generated: `eta_js_node.opam`
- Create: `test/js_node/dune`
- Create: `test/js_node/run_js_node_tests.ml`

**Target API:**

```ocaml
val run_main :
  ?runtime:'err Eta_js.Runtime.t ->
  ?on_exit:(int -> unit) ->
  (unit, 'err) Eta_js.Effect.t ->
  unit
```

**Rules:**

- This belongs in optional package `eta_js_node`, not `eta_js`.
- Handle `SIGINT` and `SIGTERM` by interrupting the root fiber.
- Use `Runtime.drain_promise` before final exit callback.
- Do not call `process.exit` directly in tests; inject `on_exit`.

**Tests:**

- Success exits `0`.
- Typed failure exits non-zero.
- Interrupt exits with signal-style code.
- Daemon drain runs before exit.

## Phase 9: Benchmarks, Leak Checks, And Release Documentation

### Task 9.1: Add JS Runtime Benchmarks

**Objective:** Track runtime overhead and regressions.

**Files:**
- Create: `bench/js/dune`
- Create: `bench/js/bench_eta_js.ml`
- Create: `bench/js/run.sh`

**Benchmarks:**

- Deep bind, 100k and 1M.
- `Effect.all` with many pure children.
- `Effect.all` with many async children.
- Queue send/recv throughput.
- Semaphore acquire/release throughput.
- Stream pure map/filter/take once `eta_js_stream` exists.

**Verification:**

Run:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); bash bench/js/run.sh --quick'
```

Expected: prints stable timing table and exits `0`.

### Task 9.2: Add Leak-Oriented Stress Tests

**Objective:** Catch waiter, child, and finalizer retention bugs.

**Files:**
- Modify: `test/js/test_stress.ml`

**Tests:**

- After repeated timeout of blocked queue receives, receiver count returns to zero.
- After repeated timeout of semaphore acquires, waiter count returns to zero.
- After repeated pool cancellation, active count returns to zero.
- After supervisor scope exits, live child count returns to zero.
- After deferred waiter cancellation, waiter count returns to zero. Add debug stats only if needed and keep them private/test-only.

**Verification:**

Run JS tests with high iteration count locally once, then keep CI count modest.

### Task 9.3: Write Production Readiness Document

**Objective:** Make status and remaining risk explicit.

**Files:**
- Create: `docs/eta_js/production-readiness.md`

**Content:**

- Supported runtimes: Node version range, browser assumptions.
- Unsupported surfaces.
- Public API stability statement.
- Cancellation guarantees.
- Resource/finalizer guarantees.
- Testing matrix and commands.
- Known limitations.
- Release checklist.

**Verification:**

Run:

```bash
rg -n "Supported|Unsupported|Cancellation|Resource|Testing|Known limitations|Release checklist" docs/eta_js/production-readiness.md
```

Expected: all sections exist.

### Task 9.4: Add API Documentation For `eta_js`

**Objective:** Give users enough context to use the JS runtime safely.

**Files:**
- Create: `lib/js/README.md` or `docs/eta_js/README.md`
- Modify: `eta_js.opam` description only through `dune-project` if needed

**Content:**

- Minimal example using `Runtime.run_promise`.
- Timeout/cancellation example.
- Queue or Deferred example.
- Resource finalizer example.
- Explanation that synchronous callbacks can block the JS event loop.
- Explanation that `Runtime.run_now` returns `None` for suspension.

**Verification:**

Run:

```bash
rg -n "run_promise|timeout|Deferred|Resource|run_now|event loop" docs/eta_js README.md lib/js/README.md
```

Expected: relevant docs exist.

## Phase 10: Final Stabilization And Release Gate

### Task 10.1: Audit Public API Surface

**Objective:** Remove accidental exports before declaring any stability.

**Files:**
- Read: `lib/js/eta_js.mli`
- Read: every `lib/js/*.mli`
- Modify: public `.mli` files as needed

**Steps:**

1. Identify internal modules currently exported accidentally.
2. Move internals to `private_modules` in `lib/js/dune` where possible.
3. Remove public functions that expose mutable runtime internals.
4. Update tests to use public APIs only.

**Verification:**

Run:

```bash
rg -n "Runtime_|unsafe|mutable|internal" lib/js/*.mli lib/js/eta_js.mli
```

Expected: only deliberate public unsafe/internal names remain and are documented.

### Task 10.2: Run Full Gate Matrix

**Objective:** Prove the current branch is ready for review.

**Commands:**

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune build @melange @test/js/js-tests-build'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_TESTS=true dune runtest test/js_stream'
nix develop -c dune runtest --force
```

If browser and Node optional packages exist:

```bash
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_BROWSER_TESTS=true dune runtest test/js_browser'
nix develop .#mainline -c bash -lc 'eval $(opam env --switch=eta-js-5.4.1 --set-switch); ETA_JS_NODE_TESTS=true dune runtest test/js_node'
```

Expected: all pass.

### Task 10.3: Update Parity Matrix And Production Document

**Objective:** Ensure docs match the implementation before handoff.

**Files:**
- Modify: `docs/eta_js/effect-smol-parity-matrix.md`
- Modify: `docs/eta_js/production-readiness.md`

**Steps:**

1. Mark completed rows as `implemented`.
2. Mark unimplemented rows as `planned`, `deferred`, or `non-goal`.
3. Add exact test commands and last run date.
4. Do not claim production readiness unless all production gates pass and known limitations are acceptable.

**Verification:**

Review docs manually and run:

```bash
rg -n "implemented-needs-tests|TODO|unknown" docs/eta_js
```

Expected: any remaining matches are deliberate and explained.

## Suggested Commit Sequence

Use focused commits. Do not batch unrelated phases.

1. `docs(js): add effect-smol parity matrix`
2. `test(js): split node test suite`
3. `test(js): await all async tests`
4. `feat(js): inject runtime clock`
5. `feat(js): add public fiber handles`
6. `feat(js): add cancellation masks`
7. `feat(js): add cause-aware effect handlers`
8. `feat(js): add deferred and latch`
9. `feat(js): add ref primitives`
10. `test(js): add primitive stress suite`
11. `feat(js-stream): add package shell`
12. `feat(js-stream): add pure streams and sinks`
13. `feat(js-stream): add mailbox and queue streams`
14. `feat(js-stream): add merge and flat_map_par`
15. `feat(js): wire observability`
16. `feat(js-node): add node run_main`
17. `bench(js): add runtime benchmarks`
18. `docs(js): add production readiness guide`

## Handoff Checklist

Before another agent starts implementation, they should confirm:

- `git status --short` and whether `eta_js` prototype files are committed or untracked.
- `js-runtime-implementation-plan.md` acceptance commands still pass.
- This plan file exists at `docs/plans/2026-06-08-eta-js-production-readiness-and-effect-smol-parity.md`.
- They will use the mainline JS switch, not OxCaml, for Melange work.
- They will keep `js-runtime-proposal.md` untouched unless explicitly assigned.


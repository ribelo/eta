# Thermo-Nuclear Code Quality Review — Eta OCaml Library

**Scope:** `packages/eta/` (published library), `packages/eta-test/` (test helpers), `dune-project`, `README.md`
**Excluded:** `scratch/` (research experiments, explicitly out of scope per `AGENTS.md`)

---

## Executive Summary

Eta is a well-motivated, carefully-researched effect library with strong
boundaries and good test coverage. However, the core interpreter and effect
surface have accumulated structural weight that makes the codebase harder to
maintain and extend than it needs to be. The most serious issue is that
`runtime.ml` is **1,039 lines** — it sits exactly on the 1k-line cliff and
bundles interpretation, concurrency orchestration, observability
instrumentation, supervisor semantics, and retry/repeat loops into a single
file. This is a structural regression waiting to happen: any new effect
constructor or runtime feature will push it over.

There are also several missed "code judo" opportunities: duplicated tracing
logic, duplicated AST/view GADT declarations, duplicated `Cause`/`Cause.Portable`
implementations, and a `Supervisor` module that adds almost no value while
scattering supervisor concepts across three files.

The library is **not approved** at the thermo-nuclear bar without addressing
the structural decomposition of `runtime.ml` and the duplicated abstraction
surfaces below.

---

## P0 — Structural Regressions & File Size

### 1. `runtime.ml` is 1,039 lines and must be decomposed

**Finding:** `packages/eta/runtime.ml` is the second-largest file in the library
and the most important. It contains:

- Exception key machinery (`Typed_fail`, `Raised_cause`)
- Core interpreter loop (`interpret`)
- Span instrumentation (`interpret_named`, `instrument_leaf`)
- Concurrency primitives (`par_collect`, `race_first`, `par_collect_settled`)
- Supervisor scope interpreter (`interpret_supervisor_scope`)
- Daemon fiber spawning (`daemon_effect`, `fork_internal`)
- Retry/repeat loops (`repeat_eff`, `retry_eff`)
- Finalizer orchestration (`run_finalizers`, `with_finalizers`)
- Timeout logic (`has_timeout`, `only_timeout_or_interrupt`, etc.)

**Why this is a problem:**
- The file is already over the healthy size boundary. Adding island batching,
  new observability signals, or stream constructors will make it worse.
- The mix of concerns means reviewers cannot reason about the interpreter
  without also holding the concurrency model, observability model, and
  supervisor model in their head simultaneously.
- The deeply nested `and`-bound helper functions share implicit parameters
  (`~runtime`, `~fail_key`, `~finalizers`) but there is no record or
  environment type to bundle them, so every call site is noisy.

**Code-judo move:**

Extract **four** focused internal modules from `runtime.ml`:

1. **`Runtime_interpret.ml`** — The `interpret` loop itself, plus
   `Typed_fail`/`raise_cause`/`cause_of_exn`. Keep this under 400 lines.
2. **`Runtime_concurrency.ml`** — `par_collect`, `race_first`,
   `par_collect_settled`, `fork_internal`, `daemon_effect`. These are the
   Eio-fiber orchestration helpers.
3. **`Runtime_instrument.ml`** — `interpret_named`, `instrument_leaf`, and the
   shared sampling/parent-context logic (see P1 issue 4 below). This module
   owns the tracer fiber-key lookups and span lifecycle.
4. **`Runtime_supervisor.ml`** — `interpret_supervisor_scope`. Currently this
   logic lives in `runtime.ml` while `runtime_supervisor.ml` (existing) only
   holds trivial atomic wrappers. Merge the real supervisor interpretation
   into `Runtime_supervisor` and delete the thin wrapper file.

The `runtime.ml` file should then contain only `create`, `run`, `run_exn`,
`drain`, and the `type 'err t` record definition — roughly 200 lines.

**Impact:** Each extracted module becomes independently scannable. The
interpreter loop no longer needs to know how `Par` is collected; it just calls
`Runtime_concurrency.par_collect`. The tracing logic is in one place, so
sampling bugfixes touch one file.

---

### 2. `effect_ast.ml` / `effect_view.ml` — triplicated GADT constructors

**Finding:** Every effect constructor is declared in:
1. `effect_ast.ml` (the canonical AST)
2. `effect_view.ml` (the runtime view, bit-identical, `%identity` cast)
3. `effect.mli` (public API type is abstract, but `Private.view` re-exports them)

Adding a new effect constructor requires editing **three** files and keeping
them in sync. The comment in `effect.ml` explains the performance rationale
(~3 minor words per `Bind` step saved), but the maintenance tax is real and
ongoing.

**Code-judo move:**

Consider whether the performance win is still necessary. The comment references
an old implementation that reallocated an isomorphic GADT block. But OCaml 5.2
with `@@ unboxed` or a single `external view : ('a, 'err) t -> ('a, 'err) view = "%identity"` might allow the runtime to simply
**include** the AST module and cast the abstract type, eliminating `effect_view.ml`
entirely.

If the cast truly requires a separate type definition for layout coincidence,
then at minimum generate `effect_view.ml` from `effect_ast.ml` via a small
PPX or `sed` rule in the build, and add a CI check that they stay in sync.
Manually keeping three copies of a 50-constructor GADT is a design smell.

**Alternative:** If the compiler requires the separate definition, add an
`[@ocaml.warning "..."]`-free `include` with a build-time `diff` check in the
`dune` file so the duplication is mechanical, not human-maintained.

---

## P1 — Missed Opportunities for Dramatic Simplification

### 3. `interpret_named` and `instrument_leaf` share ~40 lines of copy-pasted sampling logic

**Finding:** Both functions duplicate:

- `parent_id` lookup from `active_span_key`
- `ambient_context` lookup from `trace_context_key`
- `parent_sampled` resolution (with the same `Option.value` fallback chain)
- `external_parent` resolution
- `Sampler.sample` call with the same `~trace_id:""` and `~attrs:[]`
- The `if not sampled then ...` branch
- `started_ms`, `span_id`, `finish`, `emit_exception_event` patterns

**Code-judo move:**

Extract a single helper:

```ocaml
val with_span :
  runtime:_ t ->
  kind:Capabilities.span_kind ->
  name:string ->
  attrs:(string * string) list ->
  (unit -> 'a) ->
  'a
```

This helper resolves sampling, opens the span, installs fiber bindings, runs
the body, catches exceptions, emits the exception event, ends the span, and
re-raises. Both `interpret_named` and `instrument_leaf` collapse to thin
wrappers around `with_span`.

**Impact:** ~60 lines deleted from `runtime.ml`, one place to fix sampling
bugs, and the two functions no longer risk diverging when someone adds
`trace_state` propagation or changes the sampling heuristic.

---

### 4. `Cause` and `Cause.Portable` are near-duplicates

**Finding:** `Cause` defines:
- `type 'err t` with `Fail | Die | Interrupt | Sequential | Concurrent | Suppressed`
- `equal` (recursive, ~20 lines)
- `pp` (recursive, ~30 lines)

`Cause.Portable` defines:
- `type ('err : value mod portable) t` with the exact same shape
- `of_cause` (recursive, ~15 lines)
- `equal` (recursive, ~20 lines, identical structure)
- `pp` (recursive, ~30 lines, identical structure)

The only material difference is that `Die` carries `exn * raw_backtrace option`
in the main type and `string * string option` in the portable type.

**Code-judo move:**

Parameterize the cause tree over the die payload:

```ocaml
type ('err, 'die) tree =
  | Fail of 'err
  | Die of 'die
  | Interrupt of interrupt_id option
  | Sequential of ('err, 'die) tree list
  | Concurrent of ('err, 'die) tree list
  | Suppressed of { primary : ('err, 'die) tree; finalizer : ('err, 'die) tree }

type 'err t = ('err, die) tree

module Portable = struct
  type 'err t = ('err, portable_die) tree
  ...
end
```

Then write **one** generic `equal_tree` and `pp_tree` that work for any `'die`,
and instantiate them. This deletes ~70 lines of duplication and guarantees that
future cause constructors (e.g., `Timeout`) appear in both domains automatically.

---

### 5. `Supervisor.ml` is a trivial pass-through that scatters semantics

**Finding:** `Supervisor.ml` is 24 lines. It defines `Scope` as a set of aliases
to `Effect.supervisor_pure`, `Effect.supervisor_lift`, etc. The actual
supervisor record type lives in `Effect_ast`. The interpretation lives in
`Runtime`. The thin runtime wrapper for atomic operations lives in
`runtime_supervisor.ml`.

So supervisor concepts are spread across **four** files, and `Supervisor.ml`
adds no behavior.

**Code-judo move:**

Either:
- **Elevate `Supervisor` to own the scope DSL.** Move the `supervisor_scope`
  type and its constructors out of `Effect_ast` and into `Supervisor`. The
  `Effect` module can re-export them if needed for the public API, but the
  canonical home should be `Supervisor`.
- **Or delete `Supervisor.ml` entirely** and move its `scoped` helper into
  `Effect` directly. The `Supervisor` namespace is not buying enough clarity
  to justify a file that is just aliases.

If the first path is chosen, `runtime_supervisor.ml` should also be folded
into `Supervisor` as an internal `Runtime_interop` submodule.

---

### 6. `Pool.acquire_entry` is deeply nested and hard to scan

**Finding:** `Pool.acquire_entry` defines ~8 nested continuations
(`after_health`, `after_open`, `use_entry`, `try_reserve`, etc.) inside a
single recursive function. While the effect interpreter makes this
stack-safe, the cognitive load is high.

**Code-judo move:**

Flatten the state machine. `acquire_entry` is really a state machine over:

```
Reserve -> (Health_check | Open_new | Wait | Shutdown)
Health_check -> (Use | Reject)
Open_new -> (Health_check | Mark_failed)
```

Define an explicit `type acquisition_state` and a transition function
`next_state : t -> acquisition_state -> (acquisition_state, 'err) Effect.t`.
This turns the nested closures into a table-driven flow that is easier to
unit-test and reason about.

---

## P2 — Spaghetti / Branching Complexity

### 7. `runtime.ml` pattern match on `EV.view eff` is 300+ lines

**Finding:** The main `interpret` match is enormous. Each branch is small, but
the reader must scroll through 40+ cases to find the one they care about.

**Why this is spaghetti growth:** New effect constructors are inserted as new
branches in an already busy flow. There is no grouping (e.g., concurrency
cases together, observability cases together).

**Preferred remedy:** After decomposing `runtime.ml` (P0 issue 1), the
`interpret` function should be reduced to ~20 cases. Within that, group
cases with comments:

```ocaml
(* --- terminal leaves --- *)
| Pure | Fail | Sync | Island _ | Blocking _ -> ...
(* --- sequential combinators --- *)
| Bind | Map | Catch | Tap_error | Concat -> ...
(* --- concurrency --- *)
| Par | All | All_settled | Race | For_each_par -> ...
(* --- time --- *)
| Delay | Timeout | Timeout_as | Repeat | Retry -> ...
(* --- resource / scope --- *)
| Acquire_release | Scoped | Supervisor_scoped -> ...
(* --- observability --- *)
| Named | Annotate | Link_span | With_context -> ...
```

This is not a refactor for its own sake; it is a prerequisite for keeping
the interpreter readable after decomposition.

---

### 8. `Channel.send` / `recv` embed `Effect.bind` chains for cancellation cleanup

**Finding:** `Channel.send_sync` and `recv_sync` return raw results, then the
public `send` and `recv` wrap them in `Effect.sync` followed by
`Effect.bind` to translate results into effects. The `Semaphore.acquire`
does the same thing, building an `Effect.scoped` + `Effect.acquire_release`
chain around a promise wait.

This is not wrong, but it means the Channel and Semaphore APIs are
constructing effect ASTs to handle local Eio promise cancellation. The
result is that a simple "send a value" operation expands into a multi-node
effect tree.

**Preferred remedy:** For same-domain primitives that are *leaves* (they do
not compose sub-effects), consider exposing them as single `Sync` nodes that
catch `Eio.Cancel.Cancelled` internally and translate to `Effect.fail
`Closed``. This keeps the AST smaller and the runtime interpreter's job
simpler. If tracing is needed, wrap with `named` at the call site, not inside
the primitive.

---

## P3 — Boundary / Abstraction / Type-Contract Problems

### 9. `Effect.mli` exports too many concepts in one surface

**Finding:** `Effect.mli` is 629 lines and exports:
- Core monadic combinators (`pure`, `bind`, `map`, `tap`)
- Error handling (`catch`, `tap_error`, `retry`)
- Concurrency (`race`, `par`, `all`, `for_each_par`)
- Time (`delay`, `timeout`, `repeat`)
- Resource (`acquire_release`, `scoped`)
- Supervisor scope constructors (`supervisor_pure`, `supervisor_lift`, ...)
- Island / Blocking submodules
- Observability (`named`, `annotate`, `link_span`, `log`, `metric_update`)
- Private runtime hooks

This is not a "thin" abstraction. It is the entire DSL surface in one file.

**Preferred remedy:** Consider whether the public API can use submodules to
organize these without splitting the implementation file. For example:

```ocaml
module Effect : sig
  type ('a, 'err) t
  val pure : 'a -> ('a, 'err) t
  val bind : ...
  ...

  module Island : sig ... end
  module Blocking : sig ... end
  module Supervisor : sig ... end
  module Observability : sig ... end
end
```

The existing submodules (`Island`, `Blocking`) are already there, but the
supervisor scope constructors and observability primitives are flat. Grouping
them would make the `.mli` easier to navigate.

---

### 10. `Blocking_runtime` uses a global hashtable for worker identity

**Finding:** `Worker_context` uses a global `Mutex.t` and `(int, int)
Hashtbl.t` to track which OS threads are currently inside blocking workers.
The `check_not_worker` function reads this global state to prevent nested
`Effect.blocking` calls.

This works, but it is a hidden global. The `Blocking_runtime` module is
private, so the global does not leak, but it makes the module harder to test
in parallel and introduces a lock contention point on every blocking submit
and finish.

**Preferred remedy:** Store the "in worker" flag in **thread-local storage**
if available, or pass a token through the callback closure. Since this is
OCaml systhreads, thread-local storage is not native, but the global mutex
is a smell. At minimum, document why a global is necessary and measure the
contention if blocking throughput becomes a concern.

---

## P4 — Modularity & Abstraction Issues

### 11. `runtime_observability.ml` mixes tracing, logging, metrics, and die context

**Finding:** This 208-line module owns:
- Fiber keys for active span, trace context, sampling, and die context
- Die context helpers (`with_die_span_name`, `with_die_annotation`)
- Span status rendering from causes
- Exception event attribute trees
- Daemon failure emission (logging + tracing)
- Blocking event emission (tracing + metrics)

It is used by `runtime.ml` and `effect.ml` (via `Blocking_runtime`).

**Preferred remedy:** Split into:
- `Runtime_die_context.ml` — fiber keys and annotation helpers
- `Runtime_trace_emit.ml` — span status, exception events, daemon/blocking
  emission

This makes it clearer which runtime subsystems touch which observability
signals.

---

### 12. `effect.ml` `collect_names` is a brittle manual traversal

**Finding:** `collect_names` pattern-matches on every constructor to collect
static names. The comment admits it is incomplete (skips continuation nodes).
If a new constructor is added and `collect_names` is not updated, it is
silently skipped.

**Preferred remedy:** If a generic fold/iter over the effect AST is ever
added, `collect_names` should be implemented as a 5-line fold visitor. If
not, add an `[@ocaml.warning "..."]` or a PPX check that forces the
function to be updated when the type changes. At minimum, put a comment on
the AST type saying "add constructor to collect_names".

---

## P5 — Legibility & Maintainability

### 13. `Blocking_runtime.submit` has a `try ... with Exit -> raise Exit` anti-pattern

**Finding:**
```ocaml
(try
   match reserve_slot ... with ...
 with Exit -> raise Exit);
```

This catch-and-re-raise is unnecessary. `Exit` is an exception like any other;
if the intent is to avoid catching it, do not wrap the body in `try`.

**Preferred remedy:** Remove the `try/with Exit` wrapper. If `reserve_slot`
can raise `Exit` and the caller wants it to propagate, just let it propagate.

---

### 14. `race_first` uses `Obj.repr` / `Obj.obj` for existential packing

**Finding:** The comment explains why (`Race_won` cannot carry the existential
success type). This is correct OCaml, but it is a sharp edge. The `winner`
ref is set inside the forked fiber and read after `Race_won` is caught.

**Preferred remedy:** Add a small `Existential_box` helper module that hides
the `Obj` operations behind a typed API:

```ocaml
module Existential_box : sig
  type t
  val pack : 'a -> t
  val unpack : t -> 'a  (* unsafe, documented *)
end = struct
  type t = Obj.t
  let pack x = Obj.repr x
  let unpack x = Obj.obj x
end
```

This does not remove the `Obj` usage but makes the unsafe boundary explicit
and grep-able.

---

### 15. `island_runtime.ml` `split_batch_items` is a manual `List.split_at`

**Finding:**
```ocaml
let rec split_batch_items n acc items = ...
```

This is exactly `List.split_at` from the standard library (or `Base`), but
hand-rolled.

**Preferred remedy:** Use `List.split_at` or add a small internal
`List_helpers` module. The current implementation is not wrong, but it is
noise.

---

## P6 — File-Size and Decomposition Concerns

| File | Lines | Verdict |
|------|-------|---------|
| `runtime.ml` | 1,039 | **Over threshold. Decompose immediately.** |
| `effect.mli` | 629 | Large but acceptable for a core DSL surface. Consider submodule grouping. |
| `pool.ml` | 489 | Dense but focused. Acceptable after `acquire_entry` flattening. |
| `blocking_runtime.ml` | 360 | Acceptable. Could split `Worker_context` into its own file. |
| `channel.ml` | 351 | Acceptable. The mutable state machine is complex but self-contained. |
| `test/run.ml` | 430 | Mechanical registration. Not a quality issue, but tedious. |

---

## Recommended Priority Order

1. **Decompose `runtime.ml`** into `Runtime_interpret`, `Runtime_concurrency`,
   `Runtime_instrument`, and merge supervisor interpretation into
   `Runtime_supervisor`. This is the highest-impact change.
2. **Extract shared tracing helper** (`with_span`) to delete the duplicated
   sampling logic between `interpret_named` and `instrument_leaf`.
3. **Parameterize `Cause`** over the die payload to eliminate `Cause.Portable`
   duplication.
4. **Decide on `effect_view.ml`** — either delete it via a safer cast, or
   generate it mechanically from `effect_ast.ml`.
5. **Flatten `Pool.acquire_entry`** into an explicit state machine.
6. **Consolidate or delete `Supervisor.ml`** — it should either own the scope
   DSL or not exist as a separate file.
7. **Split `runtime_observability.ml`** into die-context and trace-emit modules.

---

## Approval Bar

The codebase does **not** meet the thermo-nuclear approval bar in its current
state because:

- `runtime.ml` is at the 1k-line boundary with no decomposition plan.
- There are clear code-judo moves (shared tracing helper, parameterized
  `Cause`, `effect_view` elimination) that would delete significant
  duplication but are not yet applied.
- Supervisor semantics are scattered across four files.
- The interpreter pattern match is a single 300+ line block that mixes
  terminal leaves, concurrency, time, resources, and observability.

None of these are behavioral bugs. The code works. But the structural debt
is real, and it will compound with every new effect constructor or runtime
feature. The recommended changes above preserve behavior while making the
implementation dramatically simpler.

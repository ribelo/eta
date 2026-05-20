# Apsis OCaml v2 — design journal

> v1 was a faithful port of the MoonBit reference. Several v1 choices were
> driven by MoonBit's type-system limits, not by good OCaml engineering.
> This journal partitions the v2 hypothesis space and records what I learn
> when I prototype each axis against real code.
>
> Time budget: 2h.

## What I'm allowed to revisit

The {b central principle} stays:

```text
Only events change state.
Only effects leave handle_event.
Only the runtime runs effects.
Only Env gives shell authority.
```

But these v1 invariants were *MoonBit-shaped* and are open for revision:

- Inv. #30 — "no generic error type parameter on Effect". MoonBit traits
  cannot take type parameters; OCaml has no such limit. Test a typed
  error channel.
- ADR 0012 — "every leaf returns a follow-up effect, flat_map is a
  structural rewrite". MoonBit needed this trick because it has no
  GADTs; OCaml does. A proper `Bind` node with an existential is
  cleaner.
- The `'env` parameter as a plain type variable. OCaml has structural
  object types, modules, and first-class modules, all of which give
  better composition than a single record.
- Sub fingerprints as `string`. Polymorphic variants with `compare`
  could give a typed fingerprint without burying the user in modules.
- Scopes and finalizers were stubbed in v1 (we tracked `Scope` tokens
  but didn't expose `acquire_release`). Eio.Switch is the right
  primitive; expose the abstraction.

## Hypotheses (the partition)

### H1 — Effect ADT shape: GADT with proper Bind

**Claim**: a GADT
```ocaml
type ('env, 'err, 'a) t =
  | Pure  : 'a -> ('env, 'err, 'a) t
  | Bind  : ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) -> ('env, 'err, 'a) t
  | Sync  : string * ('env -> 'a) -> ('env, 'err, 'a) t
  | Async : string * ('env -> 'a) -> ('env, 'err, 'a) t
  | Fail  : 'err -> ('env, 'err, 'a) t
  | Catch : ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t) -> ('env, 'err2, 'a) t
  ...
```
gives us:
- `flat_map` as O(1) wrap into `Bind`, no whole-tree rewrite (v1 paid
  O(N) per `>>=`).
- A real error channel that *narrows* on `Catch` (`'err1` → `'err2`).
- Subtree inspection still works (just GADT pattern-match).

**Risk**: GADTs limit certain inference patterns. The compiler may need
type annotations at certain match sites. Test by writing the
interpreter and seeing where annotations are needed.

### H2 — Error channel: polymorphic variants vs `exn` vs `unit`

Three options:

- **A**. Open polymorphic-variant rows. `'err = [> ` Http_404 of string ] `.
  Every `fail` extends the row; every `catch` narrows it. Inferred
  types are precise; recovery becomes "catch this row".
- **B**. `exn`. v1's choice. Open, extensible, but the type doesn't tell
  the user what failures are possible.
- **C**. `unit` (no error channel) + force users to Result-in-Event.

**Hypothesis**: A is the right ceiling but DX may suffer (verbose
inferred types, confusing error messages, cross-module rows that don't
unify cleanly). I'll write a realistic two-service flow and see how
the inferred type reads. If it's awful, fall back to B but keep the
type parameter slot so apps can pin a concrete polymorphic variant if
they want.

### H3 — Env shape: records vs objects vs FCM vs functors

Four candidates:

- **A**. Concrete record. Apps define `type env = {...}`. Simple,
  strong inference, but every effect helper is pinned to *one* env;
  composing libraries that each declare their own env requires manual
  glue.
- **B**. Structural object types. `<clock : Clock.t; ..>` lets each
  effect demand exactly the capabilities it uses; the type system
  composes them via row polymorphism: an effect using clock+http has
  type `(<clock : ...; http : ...; ..>, _, _) t`.
- **C**. First-class modules / module functors. Maximally explicit,
  cleanly composes. Verbose at the call site.
- **D**. A keyed bag like `Hmap.t` with type witnesses. Runtime lookup,
  weaker static guarantees.

**Hypothesis**: B is the modern Effect-TS idiom. OCaml object-typing
syntax is unfamiliar to many but well-supported. Test by writing the
same `Env` for the api_tour example in shape A and shape B side by
side; pick on readability and inference.

### H4 — Scope and finalizers: Effect.scoped + acquire_release on Eio.Switch

Plan:

```ocaml
val acquire_release :
  acquire:('env, 'err, 'a) t ->
  release:('a -> ('env, _, unit) t) ->
  ('env, 'err, 'a) t

val scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
```

Interpretation: `scoped` opens a fresh `Eio.Switch.run`; finalizers
register via `Eio.Switch.on_release`; release runs in reverse order of
acquire. The `Scope` opaque type from v1 becomes obsolete (Eio.Switch
already plays the role).

### H5 — Subscription fingerprint: string vs typed

Side dish. Replace `fingerprint:string` with `fingerprint:'fp` and
require `('fp -> 'fp -> bool)` at construction. Same expressiveness
as v1 if user passes `String.equal`, but typed fingerprints (e.g.
records derived `equal`) avoid stringification. Optional v2 polish.

## Plan for the 2h

- 0:00–0:10 — Goal, journal partition (this section), set up `lib/`
  v2 skeleton.
- 0:10–0:40 — H1: GADT Effect prototype. Get smart constructors,
  `flat_map`, `map`, `catch` compiling. Confirm interpreter still
  works.
- 0:40–1:10 — H2: typed error rows on top of H1. One worked example.
  Decide.
- 1:10–1:40 — H3: A/B Env. Real example.
- 1:40–1:55 — H4: scope + acquire_release + interpreter glue.
- 1:55–2:00 — Decision diary, journal close.

## Decision diary

### V1 — Effect ADT shape: GADT confirmed

Prototyped `('env, 'err, 'event, 'a) t` as a GADT in
`scratch/h1_gadt.ml`. Compiles cleanly. The interesting nodes:

- `Bind : ('env, 'err, 'event, 'b) t * ('b -> ('env, 'err, 'event, 'a) t)
  -> ('env, 'err, 'event, 'a) t` — `'b` is existential, exactly what we
  want for monadic bind.
- `Catch : ('env, 'err1, 'event, 'a) t * ('err1 -> ('env, 'err2, 'event, 'a) t)
  -> ('env, 'err2, 'event, 'a) t` — error type *changes* across catch,
  which is the whole point of a typed error channel.
- `Emit : 'event -> (_, _, 'event, unit) t` — explicit publish, decoupled
  from `Pure`. This kills v1's confusion between "this effect produces
  a value" and "this effect emits an event".

Four type parameters is the price. Aliases (`('env, 'err, 'event)
Pub.t = (_, _, _, unit) t`) hide the noise where it matters.

### V2 — typed error channel: poly-variant rows are a clear win

`scratch/h2_errors.ml` confirms:

- Composition unifies error rows automatically. Two helpers with errors
  `[> `Empty | `Too_long ]` and `[> `Bad_int of string ]` compose to
  `[> `Bad_int of string | `Empty | `Too_long ]`. Zero ceremony.
- Total `catch` discharges the row to a fresh `'err` (no errors left).
- Selective `catch` narrows the row: catching `Empty` and rethrowing
  the others gives `[> `Bad_int of string | `Too_long ]`. The compiler
  *enforces* that the rethrown variant is a subset of the original row.
- Inferred types are readable. `[> ...]` open-row syntax is the same
  notation users see in `match`-with-polymorphic-variants, so there
  is no new surface to learn.

DX verdict: **good**. The hypothesis that DX would be "awful" is
rejected. Adopt it.

### V3 — Env shape: object types win H3 by a mile

`scratch/h1_gadt.ml`'s `sleep` and `http_get` infer to:

```
val sleep : int -> (< clock : Clock.t; .. >, 'a, 'b, unit) Effect.t
val http_get : string -> (< http : Http.t; .. >, 'a, 'b, string) Effect.t
val fetch_user : string ->
  (< clock : Clock.t; http : Http.t; .. >, [> `Http_404 | `Http_500 of string ],
   event, string) Effect.t
```

Row polymorphism on object types means each helper *demands only the
capabilities it uses*, and composition automatically unions them. This
is exactly TS Effect's `R` channel, and it falls out of OCaml's type
system for free. No functor, no first-class module gymnastics, no
manual lifting.

Record-based envs (axis A) lose because each helper would be pinned
to the whole env, defeating reuse across applications. Functor-based
(axis C) loses on call-site verbosity. Map-based (axis D) loses on
static guarantees.

**Adopt object types.** Apsis ships a few canonical traits (Clock,
Log, ...); apps can declare their own.

### V4 — major API change: drop "Pure emits"

v1 conflated value and event. `Pure v` published v to the inbox; this
broke monadic laws (`bind` couldn't have the standard meaning) and
forced the structural-rewrite `flat_map`.

v2 separates them:

- `Pure v` produces a value, *does not* publish.
- `Emit ev` is the only way to publish to the inbox.
- `bind` is now standard monadic bind: run `eff`, get its value, feed
  to the continuation.

This means `handle_event`'s effect type is `('env, 'err, 'event, unit)
Effect.t` — the result value is `unit` because the effect's purpose
is to publish events. We expose this as `('env, 'err, 'event) Pub.t`.

Side effect: tap is now real. `tap (fun a -> emit (Loaded a))` runs
the emit but propagates the original value `a`.

### V5 — outcome of the runtime prototype

The runtime in `lib/runtime.ml` proved several non-obvious things:

- **Typed failures travel via a private exception.** OCaml exceptions
  are monomorphic, but each `Catch` frame can have its own integer
  key; `Fail` raises a single internal `Typed_failure (key, Obj.t)`,
  the matching frame intercepts on key equality and uses `Obj.magic`
  to recover the typed value. The unsafe coercion is contained in a
  ~20-line module; the public surface is fully typed. This is
  strictly safer than asking users to declare per-app exceptions.

- **Acquire/release composes with `Eio.Switch.on_release`.** `Scoped`
  opens a sub-switch; `Acquire_release` registers the release effect
  as an Eio finalizer on that switch. When the body finishes (success,
  typed failure, or cancellation), Eio guarantees the finalizer runs.
  Confirmed by `test_acquire_release_on_failure`: when the body fails
  inside the scope, the catch handler runs *and* the release runs,
  in the right order.

- **GADT existentials require non-merged match arms.** `Map (e, _)`
  binds an existential `'b` (the input type) and OCaml refuses to
  merge it with `Delay (_, e)` whose `'b` is independent. Solution:
  one match arm per constructor. Slight verbosity, zero unsafety.

- **The `Pub.t` alias attempted in the first draft mli (a type alias
  for `('env, 'err, 'event, unit) t`) was dropped** when I realised
  it brought no real ergonomic win once the example used full types.
  The four-axis signature is fine because users write `Effect.unit`
  for no-op handler returns and let inference do the rest.

- **`collect_names` is intentionally limited to non-continuation
  positions.** Bind/tap/catch continuations are functions, not
  effects, so leaves inside them are statically invisible. This
  matches v1 behavior and is honest about what can be inspected
  without running the program.

## Final stats (v2)

- LOC: ~570 across `lib/` (mli + ml), down from ~1070 in v1.
- Tests: 11 focused on the new behavior. All passing in ~6 ms.
- Example: `examples/api_tour/main.ml` exercises capability rows,
  typed errors, and resource scopes in one file.
- Time used: ~1h45m of the 2h budget. Toolchain was already set up
  from v1, so the budget went to design + code + validation.

## V1 vs V2 in one table

| Concern              | v1                                  | v2                                          |
|----------------------|--------------------------------------|---------------------------------------------|
| Effect ADT           | plain variant + structural rewrite  | GADT with explicit Bind existential         |
| Effect type          | `('env, 'a) t`                      | `('env, 'err, 'event, 'a) t`                |
| Pure semantics       | also publishes to inbox             | produces value only; `Emit` publishes       |
| Errors               | open `exn`                          | poly-variant rows: `[> `X | `Y]`            |
| Env shape            | concrete record                     | structural object type with row polymorphism |
| Resource scope       | `Scope` token, no API surface       | `acquire_release` + `scoped` on Eio.Switch  |
| Catch can change err | no                                  | yes (narrow or discharge)                   |


## TestClock port — virtual time through the runtime

Ported `.reference/effect-smol/packages/effect/test/TestClock.test.ts`
to OCaml as the `Clock` Alcotest group in `test/test_apsis.ml`.

The reference behaviors are:

- a delayed effect can complete after virtual time is adjusted, without
  waiting for wall time;
- a delayed effect remains suspended until enough virtual time has
  elapsed;
- multiple concurrent sleeps wake in deadline order;
- setting absolute time wakes sleepers whose deadline is now due.

The OCaml shape is intentionally not a direct clone of Effect-TS
`TestClock`. The runtime already owns effect interpretation and each
handled event's effect is admitted as an Eio fiber, so the tests model
`forkChild` / `forkScoped` by emitting separate events whose effects
sleep independently. That keeps the central invariant intact:

```text
Only the runtime runs effects.
```

Implementation note: `Runtime.create` now accepts an optional
`sleep : Duration.t -> unit`. Production callers omit it and keep the
existing `Eio.Time.sleep` behavior. Tests pass a tiny virtual clock
that records sleepers as Eio promises, then wakes due promises on
`adjust` or `set_time`. This is smaller than trying to impersonate an
entire Eio clock resource, and it tests the behavior Apsis owns:
runtime interpretation of `Effect.delay`, `repeat`, and `retry`.

Added `Runtime.drain_pending` as a non-blocking driver for tests and
tools that need to process currently queued inbox events without
waiting for active sleeping fibers. `drain` remains the "wait for
quiescence" driver.

Tooling note: added `flake.nix` and `flake.lock` so the project has a
reproducible development shell. The plain host shell did not expose
`eio`, `eio_main`, or `alcotest`; the flake supplies OCaml, Dune,
findlib, Eio, Eio main, and Alcotest.

Validation:

```text
nix develop -c dune test
```

Result: 15 tests passing, including 4 Clock tests, in 0.007s.

## Duration / Schedule / Scope / Resource test ports

Ported the applicable core behaviors from:

- `.reference/effect-smol/packages/effect/test/Duration.test.ts`
- `.reference/effect-smol/packages/effect/test/Schedule.test.ts`
- `.reference/effect-smol/packages/effect/test/Scope.test.ts`
- `.reference/effect-smol/packages/effect/test/Resource.test.ts`

Duration decision: keep the OCaml type millisecond-precision and
nonnegative. The reference Duration module includes bigint nanoseconds,
positive/negative infinity, structural parsing, JSON/inspect hooks,
and JavaScript-specific coercions. Those are ecosystem surface area,
not currently part of Apsis. The port therefore covers the algebra that
matches the existing type: days/weeks, ordering/equality, min/max,
clamp/between, add/subtract, multiply, and integer divide.

Schedule decision: keep `Schedule.t` as a pure recurrence-policy
description. The port extends coverage around existing constructors:
`recurs`, `spaced`, `fixed`, `linear`, `exponential`, `both`, `either`,
and `and_then`. I did not port cron, collecting outputs, reducers, or
effectful predicates because the current schedule model intentionally
only answers `next_delay : t -> step:int -> Duration.t option`.

Scope finding: the reference `Scope.test.ts` checks that finalizers run
in parallel. The first OCaml tracer test hung after one virtual-time
adjustment, which showed that delegating releases to
`Eio.Switch.on_release` did not give Apsis the desired behavior. The
runtime now owns scoped finalizers directly: `Effect.scoped` collects
release actions in an interpreter-local list and runs them with
`Eio.Fiber.all` when the scope exits. `Eio.Switch` still bounds fiber
lifetime, but Apsis owns release semantics.

Resource decision: added a small `Resource` module instead of copying
the whole Effect-TS resource abstraction. The useful core is:

- `manual loader` loads the first value and returns a cached resource;
- `get` reads the cached value, loading only if empty;
- `refresh` reruns the loader and updates the cache only after success;
- failed refresh leaves the last good value intact.

I did not add `Resource.auto` yet. Effect-TS can fork a managed
background refresh fiber directly from `Resource.auto`; Apsis does not
currently expose a public fork/start primitive inside `Effect.t`.
Auto-refresh should probably be expressed later as a subscription or a
runtime-managed resource, not hidden inside a pure-looking constructor.

Validation:

```text
nix develop -c dune test
```

Result: 24 tests passing, including Duration/Schedule coverage, the
parallel scope-finalizer port, and two Resource tests.

## Effect.test.ts curated slice

Started porting `.reference/effect-smol/packages/effect/test/Effect.test.ts`
by behavior group, not by file order. The file is the whole Effect-TS
runtime ecosystem (fibers, causes, contexts, transactions, logging,
platform runners), so the first high-value OCaml slice targets the
surface Apsis already exposes:

- `map` / `bind` / `tap`: runtime execution and tap value preservation;
- `catch` / `fail`: success bypasses handlers, failure switches error
  rows, chained catches still narrow;
- `tap_error`: observes the typed error and rethrows it;
- `delay` / `timeout`: timeout can win, and a fast effect can win;
- `race`: first success wins even if an earlier child fails; if every
  child fails, the first observed failure is rethrown;
- `repeat`: schedule-driven repetition, including delayed schedules
  under virtual time;
- `retry`: schedule-driven retry until success, including delayed
  retries under virtual time.

Two runtime gaps fell out:

- `Effect.timeout` used `Eio.Time.with_timeout` directly, so tests with
  the virtual clock could not drive timeout behavior. It now races the
  interpreted effect against the runtime's injected `sleep`, preserving
  production behavior while making test time deterministic.
- `Effect.race` previously delegated to `Eio.Fiber.any`, which makes the
  first completed child win even when it fails. Effect-TS `raceAll`
  waits for the first success and only fails if all children fail. The
  runtime now collects child results, returns the first success, cancels
  losers through a race-local switch, and rethrows the first failure
  only when no child succeeds.

TestClock note: the current test clock is deliberately tiny and does
not cascade newly scheduled sleeps inside a single large `adjust`.
Delayed repeat/retry tests therefore advance virtual time stepwise.
That is enough for the runtime behavior under test; a richer TestClock
can be revisited if future ports need Effect-TS-style cascading
adjustment semantics.

Validation:

```text
nix develop -c dune runtest --force
```

Result: 35 tests passing. The `Effect` group now has 14 tests covering
the curated core slice.

## Detached fiber

Added the missing public fork/start primitive as `Effect.detach`.
The shape is intentionally narrow:

```ocaml
val detach :
  ('env, _, 'event, unit) Effect.t ->
  ('env, 'err, 'event, unit) Effect.t
```

The detached child must be a unit effect. Its typed error channel is
existential because failures in a detached child do not flow back into
the parent effect. The runtime starts the child under the runtime's
outer switch, increments the active-work counter while it runs, and
swallows uncaught child failures the same way top-level admitted
effects do.

This is not a full Fiber API. It is the smallest primitive needed for
fire-and-forget runtime work and future features such as `Resource.auto`
or child workflows that should outlive the current effect continuation.

Validation:

```text
nix develop -c dune runtest --force
```

Result: 37 tests passing. The new detached-fiber tests verify that the
parent continues immediately while the child sleeps, and that a detached
child failure does not fail the parent.

## Rename to Effet and remove the event architecture

Decision: Apsis/Syzygy is gone as the public project identity. The library is
now **Effet**.

This is not a cosmetic rename. I removed the TEA/event-loop layer:

- no `handle_event`;
- no event type axis on `Effect.t`;
- no `Effect.emit`;
- no runtime inbox;
- no `Sub` or `Stream` lifecycle reconciliation.

The core effect type is now:

```ocaml
('env, 'err, 'a) Effect.t
```

That is closer to TypeScript Effect and Scala ZIO, and it is also a better
fit for OCaml. The event axis was carrying application architecture inside
the effect library. Effet should provide effect description, typed failure,
time, scheduling, race, retry, scope, resource, and fibers. Applications can
build TEA, actors, services, CLIs, or servers above that without the library
forcing one state model.

Validation:

```text
nix develop -c dune runtest --force
```

Result: 33 tests passing after removing the event architecture.

## Slim Cause / Exit

Hypothesis:

```ocaml
type 'e Cause.t =
  | Fail of 'e
  | Die of exn
  | Interrupt
  | Both of 'e Cause.t * 'e Cause.t

type ('a, 'e) Exit.t =
  | Ok of 'a
  | Error of 'e Cause.t
```

Decision: adopt the slim model.

Reasoning:

- OCaml's `('a, 'e) result` is excellent for direct typed failure, but
  it cannot faithfully represent unchecked exceptions, interruption, or
  multiple child failures from parallel composition.
- Full Effect-TS `Cause` carries more structure than Effet currently
  needs. It is valuable in a runtime with tracing, supervision, fiber
  refs, and typed interruption identity. Effet is not there yet.
- ZIO's distinction still matters: typed failure (`Fail`) is not a
  defect (`Die`) and neither is interruption (`Interrupt`).
- `Both` is enough for the current parallel hole. `Effect.race` can now
  report all observed child failures if no child succeeds.

API decision:

- `Runtime.run` now returns `('a, 'err) Exit.t`.
- `Effect.catch` still catches only typed `Fail`. It does not catch
  `Die`, `Interrupt`, or `Both`, because its handler receives an `'err`,
  not a cause tree. That keeps the typed failure channel honest.
- `Exit.to_result` exists for the narrow case where a caller wants a
  normal OCaml result and the exit is either `Ok _` or a single
  `Fail _`. It returns `None` for causes that a result would erase.

Runtime decision:

- Keep the internal exception bridge, but raise an internal
  `Raised_cause` rather than only a typed failure. That lets `race`
  combine causes without trying to encode a cause tree as an `'err`.
- Map `Eio.Cancel.Cancelled _` to `Cause.Interrupt`.
- Map unchecked exceptions from user callbacks to `Cause.Die exn`.
- Detached fiber failures remain swallowed for now. They still need a
  future diagnostics/supervision surface before exposing their causes
  would be useful.

Validation:

```text
nix develop -c dune runtest --force
```

Result: 34 tests passing. New coverage checks `Fail`, `Die`,
`Interrupt`, and `race` returning `Both (Fail "first", Fail "second")`
when every child fails.

## Explicit uninterruptible regions

Hypothesis:

```ocaml
Effect.uninterruptible : ('env, 'err, 'a) Effect.t -> ('env, 'err, 'a) Effect.t
```

Decision: adopt a single `Uninterruptible` constructor and smart
constructor, implemented with `Eio.Cancel.protect`.

Reasoning:

- Cancellation is not a typed failure. It now reaches the runtime
  boundary as `Cause.Interrupt`, and `Effect.catch` should not catch it.
- Retry/schedule should also not treat interruption as an error to
  reschedule. Interruption is a control signal from the runtime, not a
  domain error from the user program.
- Eio already has the right primitive: `Cancel.protect` runs a region in
  a cancellation context that is not cancelled when its parent is. This
  gives Effet deferred cancellation without inventing a parallel
  cancellation system.
- I am not adding `interruptible` / mask restoration yet. Effect-TS and
  ZIO expose richer masking/restoration APIs, but Eio's public API gives
  `protect`, not a first-class "restore previous interruptibility"
  function. Adding a fake restoration API now would be misleading.

API decision:

- Add `Uninterruptible` to the `Effect.t` GADT.
- Add `Effect.uninterruptible`.
- Keep the type unchanged: `('env, 'err, 'a) Effect.t ->
  ('env, 'err, 'a) Effect.t`. The explicitness is in the AST and public
  API, not a new type parameter. That is the most idiomatic OCaml shape
  at this stage.

Runtime decision:

- Interpret `Uninterruptible e` as:

```ocaml
Eio.Cancel.protect (fun () -> interpret e)
```

- If a protected region loses a `race`, cancellation is deferred until
  the protected region completes. The original winner is preserved, but
  the enclosing race does not finish early by killing protected work.

Validation:

```text
nix develop -c dune runtest --force
```

Result: 37 tests passing. New coverage checks:

- `catch` does not catch `Cause.Interrupt`;
- `retry` does not retry interruption;
- `uninterruptible` defers cancellation of a losing race branch and the
  race still returns the original winner after the protected loser
  completes.

## R-channel re-evaluation and services / layers (2h research)

### Goal

Re-evaluate the full **requirements channel** decision (`'env`) and resolve
the open question of whether Effet should ship a value-level **Service /
Layer** abstraction analogous to Effect-TS's `Context` / `Layer` / `Tag`.
Output: a clear position on (a) the type-level shape of `'env`, (b) what
service-construction surface the library should expose, (c) what *not* to
build and why.

This is design research, not implementation. Output is a brief and a
single small API addition if justified.

### Time budget — strict 2h

- 0:00–0:15 — Re-read H3/V3 + read current `lib/` to confirm what is
  already implemented vs. only sketched.
- 0:15–0:45 — Map Effect-TS Layer/Context/Service: identify *what each
  primitive actually buys*, separated from the JS/TS workarounds it
  encodes.
- 0:45–1:15 — Evaluate three OCaml shapes (no Layer / full Layer /
  minimal `provide`) with prototype-shape signatures. Stress-test each
  against a realistic two-service example.
- 1:15–1:45 — Type-system analysis: row polymorphism, intersection
  types, structural vs nominal service identity, test ergonomics.
- 1:45–2:00 — Decision diary, journal write-up.

### Background — what V3 already settled

V3 adopted **structural object types with row polymorphism** for `'env`,
on three grounds:

1. Each helper demands only what it uses (`(<clock : Clock.t; ..>, _, _) t`).
2. Composition unions capabilities automatically via row unification.
3. No functor / first-class module ceremony at the call site.

Implemented today in `lib/capabilities.{ml,mli}` (`clock`, `log` traits)
and exercised through `('env, 'err, 'a) Effect.t`'s `Sync`/`Async` leaves.
No object-row test currently lives in the suite; tests use `~env:()`.

Open questions left explicitly unanswered after V3:

- Is the V3 finding still right after writing nontrivial multi-service
  code? In particular, does row polymorphism survive across module
  boundaries and library composition?
- Should Effet ship a value-level **Layer** (composable, dependency-aware,
  scoped service builder) or only document a convention?
- Is the `'env` channel sufficient on its own, or does it need a partner
  abstraction at the value level the way Effect-TS pairs `R` with
  `Layer`?

### Hypotheses

- **H-R1** Object-row `'env` is the right type-level shape and survives
  realistic multi-module composition unchanged. *Predicted outcome:*
  confirm.
- **H-R2** A faithful port of Effect-TS `Layer` requires *type-level
  intersection of capability sets*. OCaml has no such operator, so any
  port will lose either safety (Hmap-style) or ergonomics (phantom
  type-level lists). *Predicted outcome:* confirm; reject full Layer.
- **H-R3** The only Layer primitive worth porting is **`provide`**:
  swap the env channel of a sub-effect. Service *factories* are just
  scoped effects returning an object; composition is monadic bind.
  No new `Layer.t` type is justified. *Predicted outcome:* confirm;
  add `Effect.provide`.
- **H-R4** Structural service identity (object method names) is good
  enough; nominal identity via abstract module-defined service types
  recovers what matters (the *type* of each service is nominal, the
  *method name* is the lookup key). *Predicted outcome:* confirm.

### Survey — what Effect-TS Layer / Context / Tag actually buys

Stripped of TypeScript-specific encoding tricks, the Effect-TS service
system provides four distinct things:

1. **Nominal service identity**. `class Foo extends Context.Tag("Foo")<Foo, Impl>{}`
   gives a Tag whose runtime identity is unique even when two services
   have identical interfaces. JS/TS need this because they have nothing
   else for nominal lookup.

2. **Type-level requirement tracking**. `Effect<A, E, Foo | Bar>` says
   "needs Foo and Bar in its context". Composition unions requirements
   automatically because TS uses `|` (union) over the *set* of required
   tags, which behaves as intersection of capability shapes.

3. **Scoped, effectful service construction**. `Layer.scoped` builds a
   service inside an `Effect`, with acquire/release, possibly depending
   on other services.

4. **Compositional dependency wiring**. `Layer.provide`, `Layer.merge`
   let you assemble an application's full dependency graph as a value,
   independent of where services are *used*.

Of these:

- (1) is solved by OCaml *modules*: an abstract type exported from a
  module has nominal identity for free.
- (2) is solved by OCaml *row polymorphism* on object types — V3.
- (3) is solved by OCaml *scoped effects with acquire/release* — already
  in `Effect.scoped` + `Effect.acquire_release`. A "service factory" is
  just an `Effect.t` that returns an object of methods.
- (4) is the only thing without a direct OCaml answer. This is where
  Layer earns its keep in the TS ecosystem.

The question reduces to: **is (4) worth importing at the cost of a
parallel API surface, given that OCaml lacks the type-level operators
that make (4) ergonomic in TS?**

### Three positions

#### L1 — No Layer. Just objects + `acquire_release`.

App entry hand-builds the env object via nested `acquire_release`:

```ocaml
let app =
  Effect.scoped (
    let* db   = open_db   (* uses acquire_release internally *) in
    let* http = open_http in
    let env = object
      method clock = clk
      method db    = db
      method http  = http
    end in
    Runtime.run rt_with_env env program)
```

Loses: ability to assemble a dependency graph as a *value*, away from
the call site that uses it. Each app builds its env once at `main`.

Keeps: zero new surface area. All composition is monadic bind. The
type system already enforces that `program` only uses methods present
on `env`.

#### L2 — Faithful Layer port

```ocaml
module Layer : sig
  type ('rin, 'rout, 'err) t

  val succeed : 'rout -> (_, 'rout, _) t
  val scoped  : ('rin, 'err, 'rout) Effect.t -> ('rin, 'rout, 'err) t

  val merge   : ('rin, 'r1, 'err) t -> ('rin, 'r2, 'err) t ->
                ('rin, 'r1_and_r2, 'err) t        (* (*) *)

  val provide : ('rin1, 'rmid, 'err) t -> ('rmid, 'rout, 'err) t ->
                ('rin1, 'rout, 'err) t

  val build   : (unit, 'rout, 'err) t -> ('rout, 'err, 'a) Effect.t ->
                (_, 'err, 'a) Effect.t
end
```

The line marked `(*)` is where this collapses. `'r1_and_r2` is *the
intersection of two object-row types* — i.e. an object type with the
methods of both. **OCaml's type system has no such operator.** TS gets
this from `&` / structural `|` over tag sets; OCaml's row polymorphism
is *additive on usage* but does not give you a constructor that "merges
two object types into a third". You can write the result type manually
when both sides are concrete, but a polymorphic `merge` cannot infer it.

Workarounds (all bad):

- **Phantom type-level lists.** `'rout : ('clock * 'db * unit)`. Now
  `merge` is a type-level append. Append needs deduplication for
  collisions. Dedup at the type level needs GADT-witness machinery and
  is brittle. Lost: structural inference, gained: a tag-list DSL no
  one will read.
- **Hmap-keyed bag with phantom presence sets.** Punt to runtime: the
  bag is a heterogeneous map; phantom presence sets approximate static
  guarantees but require explicit witnesses on every `provide`. Loses
  the row-polymorphism dividend entirely; collapses to Effect-TS's
  Tag/Context model implemented manually on top of OCaml. Plausible,
  but it's a *different* design — not "object rows + Layer".
- **Restrict `merge` to identical `'rin`.** `merge : ('rin, 'r1, 'err) t -> ('rin, 'r2, 'err) t -> ('rin, '???, 'err) t`. Still hits `'r1_and_r2`. No escape.

Verdict: **L2 is unreachable in OCaml as currently typed**. Anything
called `Layer` here would either be a Hmap (different design) or
phantom-list theatre.

#### L3 — Minimal: ship `Effect.provide`, document the factory pattern

Two changes total:

1. **One new GADT constructor and smart constructor:**

   ```ocaml
   | Provide :
       'env_in * ('env_in, 'err, 'a) t
       -> ('env_out, 'err, 'a) t

   val provide :
     'env_in -> ('env_in, 'err, 'a) t -> ('env_out, 'err, 'a) t
   ```

   The interpreter swaps env when it enters `Provide`. The outer env
   is unconstrained (`'env_out` is fully general): the inner effect
   no longer demands anything from outside.

   Use cases:
   - **Tests.** Run a sub-effect under a mock env without rebuilding
     the whole runtime.
   - **Sandboxing / sub-systems.** A child program with restricted
     capabilities.
   - **Service factories that internally depend on other services
     but want to publish a smaller surface upward.**

2. **A documented convention** — *not* a type:

   > A **service** is an object-typed value. A **service factory** is
   > an `Effect.t` that returns one. Compose factories with `bind`.
   > Build the application env at `main` (or at any `provide` point).

   That is the entire "Service" surface. No `Service.t` type, no
   `Layer.t` type, no Tag class, no Context map.

L3 is deliberately less than Effect-TS Layer. It does not give you a
free-floating `db_layer` value that can be merged with `http_layer`
and provided elsewhere. It gives you:

- **Composition by bind** (services that depend on services).
- **Replacement at any boundary** (`provide`).
- **Scoped construction** (already covered by `acquire_release` +
  `scoped`).
- **Static requirement tracking** (object rows, V3).

Which is enough for every real use case I checked: app boot, test
isolation, modular sub-systems.

### Type-system analysis

A few facts worth stating plainly, because they decide the design:

**OCaml object rows are add-only at the *demand* site, narrow-only at
the *supply* site.**

A helper that demands `(<clock : Clock.t; ..>, _, _) t` is satisfied by
any env *containing* a `clock` method. Composition of two helpers with
demands `<clock : ..>` and `<db : ..>` infers a combined demand
`<clock : ..; db : ..; ..>`. This is automatic and exactly what you
want. But you cannot *erase* a method from an object type at the type
level. To "narrow" the env you produce a new object that omits
unwanted methods (or coerce: `(o :> <a : ta>)`). This is fine for
`provide` (full replacement) and fine for the `(env :> sub)` coercion
pattern, but it is *not* fine for a `Layer.merge` that needs to compute
`<a> ⊓ <b>` polymorphically.

**OCaml has no first-class type-level intersection of object types.**

There is `<a; b>` as a *literal*, but no `('t1 ∧ 't2)` type operator.
This is the central reason a faithful Layer port fails. Anyone
attempting it ends up reinventing one of: Hmap, phantom lists, or a
functor-of-functors construction.

**Structural service identity is fine in practice; nominal where it
matters comes from modules.**

Two libraries that both declare a `clock` method are interchangeable at
the row level. The *type* of that method (e.g.
`Effet.Capabilities.clock`) is nominal because `Capabilities` exports
it abstractly. A collision on the *name* "clock" with two different
types fails to type-check at the env construction site. Realistic
hazard: `query`, `get`, `run` — too generic. Mitigation: namespace
method names (`db_query`, not `query`). Same discipline as Go struct
embedding or Rust trait method naming.

**Test ergonomics favour objects over Tag/Context.**

Mocking is `let test_env = object method clock = mock_clock method db = mock_db end`.
No registration, no Tag instantiation, no `Context.add`. Effect-TS's
test ergonomics are *worse* than what falls out of objects-plus-`provide`.

### Worked example — two services

```ocaml
module Db : sig
  type t                                    (* nominal handle *)
  val open_  : (<clock : Capabilities.clock; ..>, [> `Db_open], t) Effect.t
  val close  : t -> (_, _, unit) Effect.t
  val query  : t -> string -> (_, [> `Db_query], string list) Effect.t
end

module Http : sig
  type t
  val start  : (<clock : Capabilities.clock; log : Capabilities.log; ..>,
               [> `Http_bind], t) Effect.t
  val stop   : t -> (_, _, unit) Effect.t
  val handle : t -> (string -> string) -> (_, _, unit) Effect.t
end

(* Service factories: scoped effects that return an object-typed value. *)
let make_db : (<clock : Capabilities.clock; ..>, _, <query : string -> _>) Effect.t =
  Effect.scoped (
    Effect.acquire_release ~acquire:Db.open_ ~release:Db.close
    |> Effect.map (fun h -> object method query q = ... end))

let make_http :
  (<clock : Capabilities.clock; log : Capabilities.log; ..>, _,
   <handle : (string -> string) -> _>) Effect.t = ...

(* App: services-of-services compose by bind. *)
let app rt =
  Effect.scoped (
    let open Effect in
    let* clock = pure (Capabilities.clock_of_eio (Eio.Stdenv.clock stdenv)) in
    let* log   = pure my_log in
    let* db    = provide (object method clock = clock end) make_db in
    let* http  = provide (object method clock = clock method log = log end) make_http in
    let env = object
      method clock = clock
      method log   = log
      method db    = db
      method http  = http
    end in
    provide env program)
```

This compiles, threads requirements correctly, scopes finalizers, and
needs zero new types beyond `provide`. It is also *strictly more
flexible* than L1 because the factories themselves are first-class
values — `make_db` is a reusable scoped effect that any caller can
`provide` an env into.

### Decision diary

#### V-R1 — H-R1 confirmed: keep object-row `'env`

No realistic motivation found for changing the type-level shape.
Object rows continue to express "needs only what it uses" with zero
ceremony. The only practical caveat (method-name collisions on generic
names like `query`, `get`) is a discipline matter, not a design flaw.

#### V-R2 — H-R2 confirmed: no Layer module

Effect-TS Layer's value depends on type-level intersection of
capability sets, which OCaml does not provide. Every approximation
(phantom lists, Hmap, restricted `merge`) loses either inference or
safety. Effet will not ship `Layer.t`.

#### V-R3 — H-R3 confirmed: add `Effect.provide`

One new GADT constructor and one smart constructor. This is the only
Layer primitive that has independent value at the call site (test
isolation, sandboxing, sub-system env scoping) and is not already
covered by `scoped` + `acquire_release`. Trivially implementable: the
interpreter swaps env when entering `Provide`.

API:

```ocaml
val provide : 'env_in -> ('env_in, 'err, 'a) t -> ('env_out, 'err, 'a) t
```

Naming chosen to match Effect-TS / ZIO terminology so users recognise
the operator. Alternative names considered: `with_env`, `under`,
`run_in`. `provide` is the established term.

#### V-R4 — H-R4 confirmed: services are objects, factories are effects

No `Service.t` type. No Tag class. The `Capabilities` module continues
to ship object-type aliases for canonical traits; apps define their
own via `class type` or inline object types. Service factories follow
the documented convention:

> A scoped effect that returns an object of methods is a service
> factory. Compose factories with `bind`. Mock services for tests by
> constructing a smaller object and passing it through `provide`.

Documentation TODO (not part of this research session): add a
`docs/services.md` worked example and link from README.

### What we are deliberately *not* building

- **`Layer.t`** — type-level intersection unavailable, see V-R2.
- **`Tag` / `Context`** — duplicates module-defined nominal identity
  and the env channel.
- **`FiberRef`** — Eio's fiber-local storage already covers this.
- **`Service` typeclass / module type** — premature abstraction;
  apps that want it can write a `module type SERVICE` themselves.
- **Type-level capability lists with append/dedup** — would compile,
  would be unmaintainable, would erase the V3 win.

### Final summary

The R-channel decision from V3 stands. The single follow-on for
services and layers is `Effect.provide`. Everything else collapses into
existing primitives (`scoped`, `acquire_release`, `bind`) plus a
documented convention. This keeps Effet's surface area minimum,
preserves the row-polymorphism dividend, and avoids the trap of a
half-faithful Layer port.

Estimated implementation cost: ~30 LOC (constructor, smart constructor,
interpreter case, two tests). Deferred to a separate session per the
research-only scope of this entry.

Time used: ~1h50m of the 2h budget.

## R-channel reassessment — does Effet need an `'env` parameter at all? (1.5h research)

### Why this section exists

The previous research entry confirmed V3 (object-row `'env`) and added
`Effect.provide` as the single Layer-shaped primitive. That entry was
*incomplete*: it evaluated three Layer designs on top of an unquestioned
`'env` channel, but never asked whether the channel itself earns its
keep in OCaml.

This entry tests the radical hypothesis: **drop `'env` entirely and
pass services as ordinary OCaml values, the way Eio does**. If that
works, V-R1 was wrong and `Effect.provide` is unnecessary.

### Goal

Decide between three positions, on OCaml-idiomatic grounds rather than
fidelity to Effect-TS:

- **R-A** — No env channel. `('err, 'a) Effect.t`. Services threaded as
  ordinary values.
- **R-B** — Object-row env channel. `('env, 'err, 'a) Effect.t`.
  *(Current.)*
- **R-C** — Functor-based service DI. No env channel; libraries publish
  functors; apps instantiate them.

### Time budget — 1.5h

- 0:00–0:20 — Survey: how does the OCaml ecosystem actually wire
  services? Especially Eio.
- 0:20–0:50 — Worked example in all three shapes. Compare LOC,
  inferred types, error messages, test ergonomics.
- 0:50–1:15 — Tradeoff matrix. Identify the single benefit each option
  has that the others lack.
- 1:15–1:30 — Decision and revision of V-R1 if warranted.

### Survey — Eio is the precedent

Eio is the largest extant OCaml effects/concurrency library and the
substrate Effet runs on. Its capability model is informative.

```ocaml
val Eio.Net.connect :
  sw:Eio.Switch.t -> _ Eio.Net.t -> Eio.Net.Sockaddr.stream -> _

val Eio.Time.sleep : _ Eio.Time.clock -> float -> unit

val Eio.Path.load : _ Eio.Path.t -> string
```

Crucial observation: Eio uses **structural object types as the *type*
of capability values**, but threads them as **explicit value-level
arguments**, not as a phantom requirement channel on a single "Eio
effect" type. There is no `('env, 'a) Eio.t`. There is just
`Eio.Stdenv.clock env`, `Eio.Stdenv.net env`, etc., extracted from a
top-level capability bundle and passed where needed.

This is the OCaml-idiomatic answer to the same problem TS Effect
solves with `R`: **make capabilities first-class values with structural
types, but track requirements at the function-signature level, not via
a phantom on the effect type**. The OCaml type system already does the
right thing in function signatures via row polymorphism on object
parameters; no third type parameter is needed on an effect monad.

The stdlib, Lwt, Async, Unix, every mainstream OCaml library agrees:
**resources are arguments, not implicit context**. Effet inheriting
the Effect-TS R channel is a foreign borrow, not an OCaml convention.

### Worked example — three shapes

#### R-B (current) — env-as-row

```ocaml
let fetch_user id : (<db : Db.t; clock : Capabilities.clock; ..>,
                     [> `Db_query], string) Effect.t =
  Effect.bind (Effect.sync "sleep"  (fun env -> env#clock#sleep (Duration.ms 10)))
  @@ fun () ->
  Effect.bind (Effect.sync "db.q"  (fun env -> Db.query env#db id))
  @@ fun row ->
  Effect.pure row
```

Type parameters: 3. Service access: `env#clock`, `env#db`. Construction
site builds an env object and passes it to `Runtime.create ~env`.

#### R-A — services as arguments

```ocaml
let fetch_user ~db ~clock id : ([> `Db_query], string) Effect.t =
  Effect.bind (Effect.sync "sleep"  (fun () -> clock#sleep (Duration.ms 10)))
  @@ fun () ->
  Effect.bind (Effect.sync "db.q"  (fun () -> Db.query db id))
  @@ fun row ->
  Effect.pure row
```

Type parameters: 2. Service access: ordinary closure capture. No env
in the runtime.

Composite-services variant — recovers automatic requirement tracking
without an effect type parameter:

```ocaml
let fetch_user (s : <db : Db.t; clock : Capabilities.clock; ..>) id
    : ([> `Db_query], string) Effect.t =
  Effect.bind (Effect.sync "sleep" (fun () -> s#clock#sleep ...))
  @@ fun () ->
  Effect.bind (Effect.sync "db.q" (fun () -> Db.query s#db id))
  @@ fun row ->
  Effect.pure row
```

Same row-polymorphism dividend as R-B (caller signatures union
required methods automatically), but the row lives on a *value
parameter*, not on the effect type. Exactly Eio's pattern.

#### R-C — functor

```ocaml
module Make (C : CLOCK) (D : DB) = struct
  let fetch_user id : ([> `Db_query], string) Effect.t =
    Effect.bind (Effect.sync "sleep"  (fun () -> C.sleep (Duration.ms 10)))
    @@ fun () ->
    Effect.bind (Effect.sync "db.q"  (fun () -> D.query id))
    @@ fun row ->
    Effect.pure row
end
```

Static, fully checked. But forces every consumer of `fetch_user` to
either be inside the same `Make` or take a re-applied module value as
argument. Cross-module composition is functor-application gymnastics.

### Tradeoff matrix

| Concern                     | R-A (no env)              | R-B (object row env)     | R-C (functor)            |
|-----------------------------|---------------------------|--------------------------|--------------------------|
| Type parameters             | 2                         | 3                        | 2 (+ functor params)     |
| Requirement tracking        | function signatures       | effect type              | functor signature        |
| OCaml idiom alignment       | Eio, stdlib, Lwt          | Effect-TS, foreign       | Bonsai, irmin, niche     |
| Test substitution           | pass mock arg             | construct mock env       | re-apply functor         |
| Cross-library composition   | call with values          | rows union               | functor application chain|
| Error-message quality       | best (named args)         | OK (long row types)      | poor (functor errors)    |
| Runtime substitution        | re-construct program      | `provide`                | impossible without 1st-class modules |
| Adding a dependency         | breaking (new arg)        | non-breaking             | breaking                 |
| Surface area                | minimum                   | env + provide            | functor boilerplate      |
| Cross-cutting concerns      | thread services value     | env + fiber-local        | functor + fiber-local    |
| LSP hover usefulness        | excellent                 | acceptable               | poor on functor sites    |

The cells where R-B genuinely wins:

- **Adding a dependency is non-breaking.** A library that grows a new
  capability requirement extends its inferred row, callers don't break
  if they already supply that method. R-A makes this a breaking change
  (new function argument).
- **Runtime substitution via `provide`.** A clean way to swap envs
  mid-program (test sub-effects, sandboxes).

The cells where R-A genuinely wins:

- **OCaml idiom.** Matches every major OCaml library including Eio.
- **Type parameter count.** Two is materially less than three for
  every type signature in the codebase.
- **Error messages.** Missing-argument errors at call sites are
  pinpoint; missing-method errors on long rows are not.
- **Mental model.** No phantom env, no objects in user code unless
  they want them, no "where is env supplied" question.

The "non-breaking dependency growth" point is the strongest argument
for R-B, but in practice library authors should declare capabilities
deliberately rather than have them grow silently into inferred rows.
Hidden requirement creep is a *bug class*, not a feature.

The `provide` win is real but narrow: it's primarily useful for test
isolation, and in R-A test isolation is already trivial (call the
constructor with mocks).

### Reassessment of the previous V-R1 / V-R3 decisions

V-R1 said "object-row env is the right shape". That was true *given
that we ship an env channel*. But the prior entry never asked the
prior question: *should we ship one at all?*

V-R3 added `Effect.provide`. That primitive only exists to compensate
for the env channel's rigidity. If there is no env channel, `provide`
has nothing to do.

Honest verdict: **V-R1 and V-R3 were locally correct but globally
under-considered**. The radical hypothesis (drop the channel) was not
on the table when I evaluated them.

### Hypotheses for this session

- **H-R5** Dropping `'env` removes more complexity than it removes
  benefit. *Predicted outcome:* confirm.
- **H-R6** OCaml's value-level row polymorphism on object *arguments*
  recovers the entire requirement-tracking benefit of an env channel,
  with strictly better tooling and idiom. *Predicted outcome:* confirm.
- **H-R7** Functor-based DI (R-C) is too heavy and too rigid to be a
  default; it remains available to users who want it without library
  support. *Predicted outcome:* confirm.

### Decision diary

#### V-R5 — H-R5/R6 confirmed: drop `'env`

Effet adopts R-A. The effect type becomes:

```ocaml
('err, 'a) Effect.t
```

`Sync` and `Async` change from `string * ('env -> 'a)` to
`string * (unit -> 'a)`. Services are captured by closure or supplied
as function arguments at the smart-constructor level. `Capabilities`
continues to ship `clock` and `log` object-type traits, but they are
documented as **values to pass, not env entries to look up**.

Rationale, in priority order:

1. Matches the OCaml ecosystem (Eio, stdlib, Lwt, Async).
2. Strictly less type machinery, strictly less surface area.
3. Better tooling: pinpoint LSP errors on missing args.
4. Removes the parallel "where does env live" runtime concept.
5. Removes the Layer question entirely. There is nothing to compose
   over: services are values, composed by the host language.
6. Tests get *simpler*, not more elaborate.

The cost: library-author requirement growth becomes a breaking change.
This is a feature: it forces deliberate capability declarations and
keeps inferred type signatures readable. Effect-TS users have repeatedly
described inferred-row growth as a *footgun* in large codebases.

#### V-R6 — H-R7 confirmed: no functors imposed

Effet does not require functor-based DI. Users who want it can wrap
Effet themselves; the library ships ordinary values and types.

#### V-R7 — `Effect.provide` is dropped from the roadmap

The previous entry's V-R3 added `Effect.provide`. With no env channel
to swap, `provide` has nothing to do. Test isolation and sub-system
sandboxing are recovered by ordinary OCaml: pass a mock service to
the constructor, or partially apply the smart constructors with mocks.

If a future need emerges for **dynamic substitution mid-effect-tree**
(rather than at construction), reconsider. Currently no such use case
is on the table.

### Implications

Surface change is mechanical but touches every public signature:

- `Effect.t` loses `'env` parameter — every constructor and smart
  constructor updates.
- `Sync`/`Async` callbacks lose their `'env` argument.
- `Runtime.create` loses `~env`.
- `Capabilities.mli` reframes traits from "env entries" to "service
  value types".
- `README.md` and `effect.mli` doc comments drop the `'env` story.

Rough estimate: ~50 LOC of public-API churn, ~100 LOC of internal
runtime simplification (the env-threading paths in
`runtime.ml::interpret` collapse). Tests already pass `~env:()`, so
test churn is removing the parameter, not rewriting tests.

### What this rejects from the prior entry

- **V-R1** (keep object-row env) — superseded by V-R5.
- **V-R3** (add `Effect.provide`) — superseded by V-R7.
- **V-R4** (services-as-objects convention) — *retained* but reframed:
  services are object values you *pass*, not env entries you look up.
- **V-R2** (no Layer module) — *retained and strengthened*: not only
  is Layer un-typeable in OCaml, it is also un-needed once env is gone.

### Final summary

The right answer for an OCaml-native effect library is **no env channel**.
The previous entry's confirmation of V3 was anchored to Effect-TS's shape
rather than evaluated against OCaml convention. Eio is the standing
precedent and gets this right: capabilities are first-class values with
structural object types, threaded as ordinary arguments. Effet should do
the same.

Effect type: `('err, 'a) Effect.t`. Services: ordinary OCaml values.
Layers: not needed. `provide`: not needed.

Time used: ~1h25m of the 1.5h budget. Implementation of the type
change is deferred to a separate session.

## R-channel — empirical resolution via compiler-verified lab (2h research)

### Why this entry exists

The two prior R-channel entries reached opposite conclusions through
prose-based reasoning. The first kept the env-row (V-R1) and added
`Effect.provide` (V-R3). The second reversed both (V-R5..V-R7) and
proposed dropping the env channel because Eio threads capabilities as
values. Neither entry tested the central claim — *which shape actually
gives ZIO/Effect-TS-style automatic dependency injection in OCaml* —
against a compiler. This entry does.

The methodology change is the point. Argument-shaped DI vs.
implicit-DI is a question the type system answers definitively. Prose
made me oscillate; the compiler did not.

### Goal

Decide which `Effect.t` shape supports auto-DI, defined as:

> A function `a` that internally calls `b` (which needs Log) and `c`
> (which needs Db) can be defined **without mentioning either service
> in its body or its argument list**, while its inferred type still
> reflects every transitive requirement, and forgetting to provide a
> service is a **compile-time** error at the boot site.

This is the property ZIO and Effect-TS earn through their R channel
and the property that justifies an effect-monad library at all.
Anything that fails it reduces to "Result with retries".

### Time budget — 2h

- 0:00–0:30 — Build a self-contained scratch lab covering six
  candidate shapes. Each variant defines a minimal `Effect.t`, the
  same A/B/C scenario, and a `module _ : A_SIG = struct let a = a end`
  ascription that locks the inferred signature.
- 0:30–1:00 — Negative tests: write the code that *should* fail to
  compile per variant, run, capture errors.
- 1:00–1:30 — Cross-tabulate, identify the single shape that satisfies
  all auto-DI criteria.
- 1:30–2:00 — Decision and journal write-up.

### Hypothesis space (six shapes)

| Tag | Idea | `Effect.t` shape |
|-----|------|------------------|
| R-A explicit  | Services as labeled args; A takes `~db ~log` | `('err, 'a) t` |
| R-A composite | Single services bag `s` threaded through    | `('err, 'a) t` |
| R-B env-row   | Env channel as object row; runtime supplies | `('env, 'err, 'a) t` |
| R-C functor   | Modules-as-deps; `Make_A (D) (L)` everywhere | `('err, 'a) t` inside functor |
| R-D handlers  | OCaml 5 native effects; `perform Get_db`    | `('err, 'a) t` |
| R-E FCM       | First-class modules threaded as values      | `('err, 'a) t` |

All six are implemented in `scratch/r_research/`, each ~50 LOC. The
A/B/C scenario is identical across files; only the dependency-wiring
shape varies. Each variant's `module _ : A_SIG` ascription is a
compiler-checked assertion of the inferred signature; if `dune build`
succeeds, the documented signature *is* the actual inferred type.

### Negative tests

Each candidate also has a sibling negative file that the compiler
should reject (or, for R-D, accept-but-crash-at-runtime). Run by
adding the negative module to `scratch/r_research/dune`, building,
capturing the error, then removing.

| File | Predicted | Observed |
|------|-----------|----------|
| `neg_a_explicit.ml` — A without args | compile error | **PASS** — *"This function application is partial, maybe some arguments are missing."* |
| `neg_a_composite.ml` — A without `s` | compile error | **PASS** — *"This expression has type string but an expression was expected of type `< log : log; .. >`."* |
| `neg_b_missing_service.ml` — boot env without `db` | compile error at boot | **PASS** — *"The second object type has no method db"* — pinpoint at the call to `Effect.run`. |
| `neg_d_no_handler.ml` — boot without installing handlers | accepts and runtime-crashes | **PASS** — file compiles cleanly; would raise `Effect.Unhandled` at runtime. Confirms R-D loses static safety. |

The R-B negative is the one that closes the case: A's body never
mentions `db`, but the missing-method error appears at the boot site
*by name*. The whole transitive requirement reaches the boundary
through type inference alone.

### Cross-tabulation

| Property | R-A expl. | R-A comp. | R-B env | R-C func. | R-D hdlr. | R-E FCM |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| A's body mentions zero services | ✗ | ✗ | **✓** | ✓ | ✓ | ✗ |
| A's signature unions transitive deps | manual | row on arg | **row on type** | per functor app | hidden | per module |
| Auto-union via type system | no | yes (value-level) | **yes (type-level)** | no | no | no |
| Static check at boot site | yes | yes | **yes** | yes | **no** | yes |
| Adding a leaf dep ripples up | every layer | one (`s`) | **none** | every functor | none | every layer |
| OCaml feature cost | none | object rows | object rows | functors | native effects | FCM |
| LOC overhead per call site | one arg | one arg | **zero** | functor app | zero | one arg |

Only **R-B** scores ✓ on every criterion that matters for auto-DI.
R-D matches it ergonomically but trades the static check for a runtime
crash — a regression. R-C matches it inside a functor but explodes at
the application boundary. The R-A variants and R-E never give A a
zero-arg shape.

### Decision diary

#### V-R8 — Empirical resolution: R-B is correct

Compiler-verified. The current implementation in `lib/effect.{ml,mli}`
already uses R-B (object-row `'env` channel, three type parameters).
**No code change is required.** The library has been right since V3;
the prose entries between V-R1 and V-R8 were noise.

#### V-R9 — Reverse V-R5, V-R6, V-R7

The second R-channel entry (drop `'env`, use args, no Layer, no
`provide`) is **wrong** and is hereby superseded. Specifically:

- **V-R5** rejected. The Eio precedent does not generalise: Eio is a
  capability-passing concurrency layer where five resources travel as
  arguments; an effect monad's job is precisely to abstract over
  arbitrarily-deep dependency threading. Dropping the channel removes
  the property that justifies the abstraction.
- **V-R6** rejected. Functors remain available to users who want
  module-level DI but are not the recommended Effet idiom.
- **V-R7** rejected. `Effect.provide` still has independent value
  for test isolation and dynamic sub-system substitution. V-R3 stands.

#### V-R10 — Final R-channel position

```ocaml
type ('env, 'err, 'a) t   (* env as structural object row *)
val provide : 'env_in -> ('env_in, 'err, 'a) t -> ('env_out, 'err, 'a) t
```

- `'env` is an open object row. Helpers demand only methods they use.
  Composition unions requirements via row polymorphism, automatically.
- No `Layer.t`, no `Service` typeclass, no `Tag` class. Services are
  ordinary OCaml values bound to env methods at boot or at `provide`.
- Capability traits ship as `class type` aliases in
  `lib/capabilities.{ml,mli}`. Apps define their own as needed.
- `Effect.provide` is the single Layer-shaped primitive worth porting.
  Implementation: one new GADT constructor that swaps env when entered.

### Meta-lesson

The first two R-channel entries used prose to compare type-system
behaviours that the type system itself decides. That was the wrong
tool. The third entry (this one) flipped the order: build the lab
first, derive conclusions from compiler output. Total wall time for
the lab + tabulation was under two hours; total wall time for the
prose oscillation across the prior two entries was longer.

For future research entries that turn on what the compiler will or
will not accept, **lab-first is the rule**: write the smallest
self-contained module per candidate, ascribe the expected signature
via `module _ : SIG`, run negative tests, then write prose. The lab
files in `scratch/r_research/` should be retained as artifacts; they
are the durable evidence behind V-R10.

### Artifacts

- `scratch/r_research/services.ml` — shared Db/Log/clock/log/db types.
- `scratch/r_research/r_a_explicit.ml` — labeled-arg shape.
- `scratch/r_research/r_a_composite.ml` — composite-bag shape.
- `scratch/r_research/r_b_env_row.ml` — env-channel shape (matches lib/).
- `scratch/r_research/r_c_functor.ml` — functor shape.
- `scratch/r_research/r_d_native_handlers.ml` — native-effects shape.
- `scratch/r_research/r_e_fcm.ml` — FCM shape.
- `scratch/r_research/neg_*.ml` — negative tests.

Build all: `dune build scratch/`. The negative tests live outside
`scratch/r_research/dune`'s module list by default; add the target
file's stem to the `(modules ...)` list to run a specific negative
case and observe the documented error.

## Fork-with-handle vs collection combinators (2h research)

### Goal

Decide whether Effet should expose a public `Fiber.t` with `await` /
`join` / `interrupt`, or keep fork strictly internal and ship only
collection combinators (`par`, `all`, `for_each_par`). Lab-first per
V-R10's discipline. Time budget: 2h, strict.

### Background

Currently Effet has:

- `Effect.detach` — fire-and-forget, unit result, errors swallowed.
- `Effect.race` — first-success-wins across a list.
- `Effect.concat` — sequential `unit list`.

Missing for real Effect-TS / ZIO parity:

- `par`/`all`/`for_each_par` — concurrent collection of typed results.
- A way to fork a long-lived effect whose lifecycle a parent owns
  (needed by `Resource.auto`, deferred earlier in the journal).

The first message of the conversation that produced this library
tabled the question with "no Fiber.t until a call site demands it".
`Resource.auto` is now that call site. This entry decides on the
shape.

### Hypothesis space

| Tag | Idea |
|-----|------|
| **F-A** | Collection combinators only (`par`, `all`, `for_each_par`). No public `Fiber.t`. Internal fork hidden in the runtime. |
| **F-B** | Public `Fiber.t` returned from `Effect.fork`. Standalone `await`, `interrupt`. ZIO/Effect-TS shape. |
| **F-C** | Hybrid: F-A as default, plus a `scoped { run = fun (type s) () -> ... }` block whose body is rank-2-polymorphic in a phantom scope tag, inside which a scope-bound `('s, 'err, 'a) fiber` exists. Fibers cannot escape (ST-monad trick). |

### Lab

Self-contained, in `scratch/fiber_research/`:

- `f_a_collection.ml` — minimal Effect with `Par`/`All`/`For_each_par`.
- `f_b_public_fiber.ml` — Fork/Await/Interrupt with public `fiber`.
- `f_c_hybrid.ml` — outer `t` plus inner `scoped_t` carrying scope tag.
- `neg_b_escape_compiles.ml` — proves F-B's hazard.
- `neg_c_escape.ml` — proves F-C blocks escape.

All three positives compile. Both negatives behave as predicted.

### Negative test results

| File | Predicted | Observed |
|------|-----------|----------|
| `neg_b_escape_compiles.ml` — return a fiber from the fork scope | compiles (hazard exposed) | **PASS** — compiles cleanly |
| `neg_c_escape.ml` — same code in F-C's rank-2 form | rejected (scope tag cannot leak) | **PASS** — *"This field value has type ... unit -> ('s, _, _, ('s, _, int) fiber) scoped_t which is less general than 's0. unit -> ('s0, _, _, _) scoped_t"* |

The F-C error message is the textbook rank-2 / ST-monad rejection:
the fiber's type mentions the locally bound `'s`, which cannot
unify with the universally quantified `'s0` in the body record's
field type. The compiler enforces escape prevention.

### Auto-DI preservation (regression of V-R10)

All three shapes preserve env-row auto-DI. Verified in each lab file
by an `_check_par_unions_env` (or analogous) that builds a
`par`/`all`/`fork` over two effects with disjoint env requirements
and ascribes the unioned object row. The outer effect type retains
`('env, 'err, 'a) t`; the new constructors thread `'env` through.

### Cross-tabulation

| Property | F-A | F-B | F-C |
|---|:---:|:---:|:---:|
| Public surface size | small (3 combinators) | medium (3 fns + fiber type) | large (2 effect types + body record + 5 fns) |
| Compile-time escape prevention | n/a (no Fiber) | ✗ | ✓ |
| Resource.auto fits cleanly | needs internal-only fork | yes | yes (scoped) |
| Outlive parent scope | impossible | possible (hazard) | impossible |
| Interrupt by handle | n/a | yes | yes (within scope) |
| Effect-TS / ZIO API parity | low | high | medium (different shape) |
| New OCaml feature cost | none | none | rank-2 records |
| Learning curve | flat | moderate | steep (two effect types, lift, body record) |
| Implementation cost | ~60 LOC | ~120 LOC + Fiber module | ~250 LOC + dual GADT |
| Idiom familiarity | high (matches `List.map` style) | moderate | low (ST-monad, niche in OCaml) |

### Decision diary

#### V-F1 — Adopt F-A as the public surface

Three new effect constructors and three smart constructors:

```ocaml
| Par         : ('env, 'err, 'a) t * ('env, 'err, 'b) t
                  -> ('env, 'err, 'a * 'b) t
| All         : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
| For_each_par : 'x list * ('x -> ('env, 'err, 'a) t)
                  -> ('env, 'err, 'a list) t
```

Smart constructors:

```ocaml
val par         : ('env, 'err, 'a) t -> ('env, 'err, 'b) t
                  -> ('env, 'err, 'a * 'b) t
val all         : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
val for_each_par : 'x list -> ('x -> ('env, 'err, 'a) t)
                  -> ('env, 'err, 'a list) t
```

Failure semantics: **fail-fast**. The first child failure cancels
siblings and the parent receives that cause. This matches `Effect.race`
(which already behaves that way for its mirror direction — first
success cancels losers) and Effect-TS `Effect.all`'s default. A
future `all_settled : ('env, _, 'a) t list -> ('env, _, ('a, 'err) result list) t`
combinator is a candidate if "wait all, collect causes" is needed
later.

#### V-F2 — Reject F-B

The escape hazard is real and the type system does not catch it. A
held fiber that survives its parent `Scoped` is a runtime trap: the
parent switch may have closed, the fiber may be cancelled mid-flight,
and `await` receives nothing useful. Effect-TS users hit this in
practice; we should not import the same trap.

#### V-F3 — Defer F-C

F-C is academically correct: the rank-2 phantom scope makes escape a
compile error, verified in lab. But the cost is steep:

- Two effect types (`t` and `scoped_t`) with explicit `lift` between
  them.
- A body record `{ run : 's. unit -> ... }` syntax that's unfamiliar
  to most OCaml programmers.
- Doubles the GADT surface.

The use case (long-lived fork with handle) is satisfied for now by
adding an *internal* fork-and-await primitive used by `Resource.auto`
and not exposed in the public surface. If a future need emerges for
user-held fibers — e.g. user-supplied supervisor strategies, fiber
groups, structured-but-handle-bearing concurrency — F-C becomes the
preferred shape and can be added as `Effect.Fiber_scope` without
breaking F-A.

#### V-F4 — Add internal `fork_internal`

Not part of the public mli. Used by:

- `Resource.auto` — background refresh fiber owned by the resource.
- `Par` / `All` / `For_each_par` — already implementable on
  `Eio.Fiber.fork` directly without exposing a fiber value, but a
  shared `fork_internal` helper is cleaner.

Shape:

```ocaml
(* runtime.ml, internal *)
val fork_internal :
  runtime:(_, _) t -> sw:Eio.Switch.t ->
  ('env, 'err, 'a) Effect.t -> 'env ->
  ('a, 'err Cause.t) result Eio.Promise.t
```

### What this commits to (recommended implementation slice)

1. Three new GADT constructors: `Par`, `All`, `For_each_par`.
2. Three smart constructors with the signatures above.
3. Interpreter cases in `runtime.ml` using `Eio.Switch` + `Eio.Fiber.fork`,
   with first-failure cancellation through a per-`all` switch.
4. Internal `fork_internal` helper.
5. Tests:
   - `par` returns both successes.
   - `par` fail-fast: first failure cancels the sibling and returns
     the cause.
   - `all` collects in input order.
   - `all` fail-fast: one failure cancels the rest.
   - `for_each_par` over a small list with success.
   - `for_each_par` over a small list with one failing element.
6. `Resource.auto` (separate follow-up task) using `fork_internal`.

Estimated implementation: ~80 LOC public + ~30 LOC internal helper +
~80 LOC tests. Single focused session.

### What this commits to deferring

- Public `Fiber.t` (F-B). Rejected.
- Rank-2 scope phantom (F-C). Deferred; door left open.
- `all_settled` variant. Deferred until demanded.
- `Effect.parallel_collection` with bounded parallelism (semaphore-style).
  Out of scope for this session.

### Artifacts

- `scratch/fiber_research/f_a_collection.ml` — winner shape, surface tested.
- `scratch/fiber_research/f_b_public_fiber.ml` — rejected; escape hazard demonstrated.
- `scratch/fiber_research/f_c_hybrid.ml` — deferred; rank-2 escape prevention demonstrated.
- `scratch/fiber_research/neg_b_escape_compiles.ml` — F-B negative (compiles, proving hazard).
- `scratch/fiber_research/neg_c_escape.ml` — F-C negative (rejected, proving escape blocked).

Time used: ~1h45m of the 2h budget.

## V-F1 implemented: par / all / for_each_par landed

The implementation slice committed in V-F1 is now in `lib/`:

- `lib/effect.ml`/`lib/effect.mli` — three new GADT constructors
  (`Par`, `All`, `For_each_par`), three smart constructors, walk
  cases in `collect_names`.
- `lib/runtime.ml` — interpreter cases plus a single shared
  `par_collect` helper. Fail-fast through a per-call `Eio.Switch`:
  when any child fails, the helper records the first observed cause,
  fails the switch (cancelling siblings), and re-raises the cause at
  the parent boundary. Re-uses the existing `cause_of_exn` /
  `raise_cause` plumbing so cancellation maps to `Cause.Interrupt`
  and unchecked exceptions map to `Cause.Die`.
- `test/test_effet.ml` — six new tests:
  - `par` returns both successes;
  - `par` fail-fast cancels sibling (verified by a flag the cancelled
    child would set after a yield);
  - `all` collects results in input order;
  - `all` fail-fast on a middle failure;
  - `for_each_par` over a small list with success;
  - `for_each_par` with one failing element.

All 45 tests pass (was 39). Implementation matched the V-F1 estimate
to within ~10 LOC.

V-F4's separate `fork_internal` helper was *not* added. The
`par_collect` helper is enough for the three combinators; a dedicated
internal fork primitive can be introduced when `Resource.auto` lands.

Deferred per V-F2/V-F3:

- Public `Fiber.t` (rejected outright).
- Rank-2 phantom-scope `scoped_fiber` (deferred; may revisit).
- `all_settled` collect-all-causes variant (deferred until demanded).
- Bounded-parallelism `for_each_par` with semaphore (out of scope).

Validation:

```text
nix develop -c dune runtest --force
```

Result: 45 tests passing.

## Observability surface — auto-naming, callsite, OTel (2h research)

### Goal

Decide the user-facing API for naming and annotating effects, so that
Effet can grow real OTel-shaped span semantics. Original concern: TS
Effect's `Effect.fn("name")(...)` requires an explicit string name
that drifts on rename and is enforced by convention. The user wants
"automatic where possible, manual where helpful, no ppx, no string
discipline".

Three positions to compare:

- **O-A**: keep current `Named` / `Annotate`, expose them as
  pipe-friendly atoms.
- **O-B**: add `Effect.fn` (TS-Effect-style) as a single combined
  smart constructor that takes name + location.
- **O-C**: replace `Named`/`Annotate` with a unified `Span { name;
  attrs; body }` constructor.

Plus a fork question on the interpreter side: today `Named`/`Annotate`
are AST decorations that go nowhere; the interpreter must emit real
spans for the choice to matter.

### Time budget — strict 2h

- 0:00–0:20 — Verify what OCaml's compile-time magic identifiers
  actually do. Confirm or refute availability of `__FUNCTION__`,
  `__POS__`, `[%call_pos]` in upstream OCaml 5.4.
- 0:20–1:00 — Lab: minimal effect type + in-memory `Tracer` +
  span-emitting interpreter. Side-by-side surface tests for pipe-style
  vs `fn` smart ctor, nesting, and decorator ordering.
- 1:00–1:30 — Address DX hazards revealed by lab (interpreter ordering
  semantics, third-party effect decoration, anonymous-lambda naming).
- 1:30–2:00 — Decision diary, recommend exact API additions, journal.

### Compile-time magic identifiers — what OCaml actually offers

Verified in `scratch/observability_research/verify_magic.ml`:

- **`__POS__`** — quadruple `(file, line, col_start, col_end)`.
  Resolved at the *use site*. Available in upstream since OCaml 4.x.
- **`__FUNCTION__`** — string with the enclosing binding's full path,
  including module nesting and let-nested function names. Examples:
  `Dune__exe__Verify_magic.outer_fn.inner_lambda`,
  `Dune__exe__Verify_magic.Inner.from_module`. **Available since
  OCaml 5.1.** This is the function-name capture the user wanted.
- **`[%call_pos]`** — *NOT in upstream OCaml 5.4*. Compiler errors with
  *"Uninterpreted extension 'call_pos'"*. Confirmed Jane Street
  experimental only. We **cannot** auto-capture the caller's location
  via an optional argument default.

Conclusion: `__FUNCTION__` and `__POS__` together cover both
"automatic function name" and "automatic call site" — but both must
still be typed at the call site as bare tokens. They are not free, but
they are zero-allocation, zero-runtime, and require no ppx.

The user's Lisp instinct ("a macro that defines a function and
captures its name") translates to *user types `__FUNCTION__`*. That's
the OCaml-native equivalent. Slightly more verbose than a Lisp macro;
substantially less verbose than passing strings.

### Lab construction

`scratch/observability_research/`:

- `obs_lib.ml` — minimal `Effect.t` (Pure, Sync, Bind, Fail, Named,
  Annotate) + an in-memory `Tracer` modelling OTel spans (id, parent,
  name, attrs, status, started_ms, ended_ms) + a span-emitting
  interpreter that calls `Tracer.begin_span`, `add_attr`, `end_span`.
- `surface_pipe.ml` — five pipe-friendly variants: bare `named`,
  `__FUNCTION__`-named, compact `here_attr |> named`, stacked with
  multiple annotates, and decorating a third-party effect.
- `surface_fn.ml` — five `Effect.fn`-style variants: prefix sugar,
  pipe-tail sugar, with extra annotations, multi-step body, explicit
  name override.
- `surface_nested.ml` — outer function with two inner helpers. Tests
  parent/child span tree.
- `surface_ordering.ml` — `wrong_order` (Annotate after Named in pipe)
  vs `right_order` vs `mixed`. Tests interpreter robustness to
  decorator order.

Run with `dune exec scratch/observability_research/lab_runner.exe`.

### Findings

#### F-1 — Both surfaces work and compose cleanly

`Effect.named` / `Effect.annotate` (pipe atoms) and `Effect.fn`
(combined sugar) are *not in conflict*. `fn` is a smart constructor
implemented in two lines on top of the atoms:

```ocaml
let here_attr (file, line, _, _) e =
  Annotate ("loc", Printf.sprintf "%s:%d" file line, e)

let fn pos name e = e |> here_attr pos |> named name
```

Pipe form for the common case:

```ocaml
let fetch_user id =
  db_q id |> Effect.fn __POS__ __FUNCTION__
```

Pipe form for arbitrary stacks:

```ocaml
let fetch_user id =
  db_q id
  |> Effect.annotate ~key:"user_id" ~value:id
  |> Effect.annotate ~key:"stage"   ~value:"db.fetch"
  |> Effect.fn __POS__ __FUNCTION__
```

The user's intuition is correct: `|>` makes `named` / `annotate` more
ergonomic than they are in TS. `fn` remains a useful one-liner for
the most common case. Both ship.

#### F-2 — Decorator order matters in the AST, but the interpreter can absorb that

First lab run revealed a real DX hazard: writing

```ocaml
db_q id
|> Effect.named "main"                     (* Named is INNER (closer to leaf in AST) *)
|> Effect.annotate ~key:"x" ~value:id      (* Annotate is OUTER *)
```

produced no attribute. Reason: `|>` is left-associative; the second
`|>` wraps Annotate around Named, so the interpreter walks Annotate
first. With no span on the stack at that point, the attr was dropped
silently.

Fix: the tracer carries a `pending : (string * string) list`. Annotate
attaches to the active span if there is one, otherwise pushes onto
`pending`. The next `Named` that opens a span drains `pending` into
the new span's initial attributes.

After the fix, `wrong_order` and `right_order` produce identical
output. Pipe direction is no longer load-bearing for correctness.
This belongs in the real interpreter.

#### F-3 — `__FUNCTION__` works in every relevant context

| Binding form                          | `__FUNCTION__` value                                  |
|---------------------------------------|-------------------------------------------------------|
| top-level `let f x = ...`             | `Mod.f`                                               |
| top-level value `let v = ...`         | `Mod.v`                                               |
| nested `let g = fun x -> ...`         | `Mod.outer.g`                                         |
| named `let g x = ...` inside `outer`  | `Mod.outer.g`                                         |
| function inside a sub-module          | `Mod.Sub.f`                                           |
| curried `let f a b = ...`             | `Mod.f`                                               |

This is enough for span naming. Truly anonymous lambdas (inline
arguments) inherit the enclosing binding name, which is fine — they
shouldn't be carrying their own span identity anyway.

#### F-4 — Nesting via interpreter + bind produces a real OTel span tree

`surface_nested` output (excerpt):

```
[1<--] outer_fetch    status=ok dur=6  attrs=loc=...:29,user_id=42
[2<-1] inner_db       status=ok dur=2  attrs=loc=...:12
[3<-1] inner_validate status=ok dur=2  attrs=loc=...:16
```

Parent IDs are wired correctly via `tracer.stack`. Children inherit
the active span. This is exactly the OTel parent/child topology
without any further mechanism.

Cross-fiber propagation (parallel children inheriting parent span)
will require carrying the active stack through `Eio.Fiber.create_key`
when forking; that's an integration detail for the real runtime, not
a surface design question.

#### F-5 — Position quadruple vs `Lexing.position`

`__POS__` returns `string * int * int * int`. `Lexing.position` is a
record. They are not interchangeable. Decision: take the raw quadruple
in our public API, since that's what users will type. Provide an
internal helper `Lexing.position_of_quadruple` if we ever need to feed
Eio's `?here:Lexing.position` arguments.

### Decision diary

#### V-O1 — Keep `Named` and `Annotate` as the primary AST surface

Rejected O-C (unify into `Span { name; attrs; body }`). Reasons:

- `Named` and `Annotate` compose orthogonally. You can annotate
  without naming (e.g., enriching an outer span from a deeper
  helper) and name without annotating.
- Pipe-friendly composition relies on each decorator being its own
  AST node. A unified `Span` node would force users to construct an
  attrs list before piping.
- Backward compatibility: existing `Effect.named` and
  `Effect.annotate` users (the test suite, examples) continue to work.

#### V-O2 — Add `Effect.fn` and `Effect.here_attr` as smart constructors

Both are sugar over the existing AST. No new GADT constructors.

```ocaml
val here_attr : (string * int * int * int) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
(** Attach the given source location as an attribute. Intended use:
    [body |> Effect.here_attr __POS__]. *)

val fn : (string * int * int * int) -> string ->
         ('env, 'err, 'a) t -> ('env, 'err, 'a) t
(** Combined sugar. [Effect.fn __POS__ __FUNCTION__ body] attaches the
    location and names the span. Idiomatic terminator of a pipe. *)
```

Why both:

- `here_attr` alone is useful for adding a location to an effect
  whose name is set elsewhere (e.g. a re-exported helper).
- `fn` is the ergonomic terminator for the common "wrap a function
  body with name + location" case.

#### V-O3 — Add a `Tracer` capability and rewrite the interpreter cases

Today the interpreter unwraps `Named` and `Annotate` and does nothing
with them. That changes:

- New `Capabilities.tracer` class type (Effet ships one canonical
  trait):

  ```ocaml
  class type tracer = object
    method begin_span : name:string -> span
    method end_span   : span -> [`Ok | `Error of string | `Cancelled] -> unit
    method add_attr   : string -> string -> unit
  end
  ```

- The runtime's interpreter calls `env#tracer#begin_span` /
  `end_span` around the body of `Named`, and `add_attr` for
  `Annotate`. Status comes from the body's `Cause` at exit.
- Effet ships `Tracer.in_memory` for tests + a `Tracer.noop` (the
  default if no `tracer` method is on env, via row coercion).
- A separate `effet-otel` companion package will wire real OTel
  exporters; not part of core Effet's surface.

The pending-attr buffer (F-2) lives inside the tracer, keeping the
interpreter logic flat.

#### V-O4 — Cross-fiber span propagation goes through Eio fiber-local

Detached fibers and parallel children must inherit the active span
context so the trace tree stays correct. `Eio.Fiber.create_key` is
the right primitive. The runtime sets a key holding the active stack
on fork; child interpretation reads it on entry. Implementation
detail, no public API change.

#### V-O5 — `__FUNCTION__` is the convention for span names

Documented use: `Effect.fn __POS__ __FUNCTION__ body`. Override with a
manual string when:

- The function name is not the right span name (e.g., a generic
  helper like `with_retries`).
- You want a domain-specific span identity (`"db.fetch"`,
  `"http.request"`).

### Decision deltas vs prior journal

The prior `Named`/`Annotate` constructors stay. Their existence was
called out as "borrowed from another project, unexamined" — V-O1
upgrades that from "borrowed" to "load-bearing", with V-O3 making the
runtime side carry its weight.

### Implementation cost (deferred to next session)

- `lib/effect.{ml,mli}`: +2 smart constructors (`fn`, `here_attr`).
  No new GADT cases.
- `lib/capabilities.{ml,mli}`: +1 `class type tracer`, +1 `Tracer.noop`,
  +1 `Tracer.in_memory` factory.
- `lib/tracer.{ml,mli}`: new module with span type, tracer state,
  in-memory implementation with pending-attr buffer.
- `lib/runtime.ml`: rewrite `Named`/`Annotate` cases to call
  `env#tracer` (and noop-coerce when env lacks one).
- `test/test_effet.ml`: 4–5 tests covering auto-name, location attrs,
  nested spans, ordering robustness, status-from-cause.

Estimate: ~250 LOC across lib, ~80 LOC of tests. One focused session.

### Artifacts

- `scratch/observability_research/verify_magic.ml` — empirical proof
  that `__FUNCTION__` works and `[%call_pos]` does not.
- `scratch/observability_research/obs_lib.ml` — minimal effect type +
  in-memory tracer + span-emitting interpreter (~140 LOC).
- `scratch/observability_research/surface_pipe.ml` — pipe-style
  surface tests.
- `scratch/observability_research/surface_fn.ml` — fn-style surface
  tests.
- `scratch/observability_research/surface_nested.ml` — parent/child
  span test.
- `scratch/observability_research/surface_ordering.ml` — pipe-order
  robustness test (drives V-O3's pending-attr buffer).
- `scratch/observability_research/lab_runner.ml` — runs all surfaces
  and prints traces.

Build all: `dune build scratch/observability_research/` and
`dune exec scratch/observability_research/lab_runner.exe`.

Time used: ~1h45m of the 2h budget.

#### V-O6 — Tracer injection is a runtime parameter, not an env-row requirement

Implementation settled the V-O3 fork in favour of a runtime-level tracer
parameter:

```ocaml
Runtime.create ?tracer ~env ...
```

Rationale:

- Span emission is interpreter instrumentation, not an application service.
  Requiring every observed effect to carry an `env#tracer` row pollutes user
  program types with observability plumbing.
- Effet already owns the interpretation boundary. A noop default on the runtime
  keeps unobserved programs unchanged while allowing tests and future
  `effet-otel` integration to provide a concrete tracer explicitly.
- The public compatibility point remains `Capabilities.tracer`, so an OTel
  adapter can implement the same trait without coupling core Effet to an SDK.
- Eio fiber-local active-span context lives in `Runtime`, where all fork sites
  are interpreted. That keeps cross-fiber propagation out of application env
  rows and out of `Tracer` itself.

The shipped shape is therefore: `Effect.Named` / `Effect.Annotate` stay as AST
nodes, `Effect.fn __POS__ __FUNCTION__ body` is pure sugar, `Tracer.in_memory`
and `Tracer.noop` implement `Capabilities.tracer`, and `Runtime` turns AST
observability decorations into spans when a non-noop tracer is supplied.

## OTLP exporter and observability DX (2h research, post Epic A)

### Why this entry exists

Epic A landed real span semantics in the runtime (V-O1..V-O6). Epic B is the
companion `effet-otel` package. Before writing it I want to (a) settle whether
to depend on `ocaml-opentelemetry` or hand-roll OTLP, (b) enumerate the
remaining DX hypothesis space for span semantics in OCaml + Effet, and (c) fix
the gaps in `Capabilities.tracer` that would make any real backend useless.

### Goal

- Pick the OTLP backend strategy with eyes open.
- Document the DX hypothesis space so future epics inherit a map, not a guess.
- Land the minimum DX improvements required for OTLP to produce non-trivial
  traces (real timestamps, real status messages).
- Implement a working OTLP exporter against motel (the local OTLP collector at
  `http://127.0.0.1:27686/v1/traces`).

### Time budget — strict 2h

This is the third 2h research entry in the journal. The pattern works.

### Hypothesis space

#### H-O7a — OTLP backend: ocaml-opentelemetry vs hand-rolled OTLP/JSON vs both

- **A1: depend on `ocaml-opentelemetry`.** Reuse battle-tested wire layer,
  protobuf codecs, semantic conventions, retries, batching.
  - Cost: cohttp-eio + tls-eio + ca-certs + mirage-crypto-rng-eio + ocaml-protoc
    + pbrt + ambient-context land in our transitive closure. ~25 packages.
  - Friction: ocaml-opentelemetry uses its own `Ambient_context` for active
    span tracking. Epic A wired Eio fiber-local. Two ambient contexts in one
    process is a footgun; we'd have to suppress theirs and feed `?parent` /
    `?scope` explicitly on every `Span.create`.
  - Friction: their `Span` / `Scope` API is the public surface, so users would
    end up reaching past `Capabilities.tracer` into `Opentelemetry.Span` for
    span kind, links, events. Trait abstraction cracks.

- **A2: hand-roll OTLP/JSON over HTTP/1.1 in effet-otel.** OTLP/JSON is part
  of the spec (https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding).
  Eio gives us TCP; JSON is ~30 LOC of Buffer/Printf; HTTP/1.1 POST is ~20 LOC.
  - Cost: ~250 LOC of effet-otel code, including encoder + transport.
  - Cost: no metrics, no logs, no semantic conventions out of the box.
  - Win: zero new dependencies. effet-otel ships against the same flake.nix
    that ships effet.
  - Win: control over wire format, retry policy, batching. Aligns with the
    "applications own state, Effet owns interpretation" boundary — effet-otel
    owns the transport, no ambient-context coupling.

- **A3: layered.** Hand-roll for the 0.x line so effet-otel stays light;
  publish a separate `effet-otel-imandra` or similar later if users want
  metrics + logs + semconv via ocaml-opentelemetry. The two coexist because
  both implement the same `Capabilities.tracer` trait.

**Decision:** A2 first, A3 explicitly preserved as future-compatible. The
trait surface is the contract; whoever implements it can use any wire layer.

#### H-O7b — Span identity carrier: `int` handle vs typed token vs trace_context record

The current `Capabilities.tracer.begin_span` returns `int`. Pros: dead simple,
no module split, easy fiber-local. Cons: implementations needing real OTel
trace_id/span_id must keep a side table from `int → (trace_id, span_id, …)`.

- **B1: keep `int`, side-table in OTLP adapter.** Smallest change. ~10 lines
  of Hashtbl per adapter.
- **B2: parametrise the trait by an abstract `'span` token.** Cleaner for
  adapters but pollutes effet's runtime types and the fiber-local key.
- **B3: return a `span_ref` record with both an int handle and an opaque
  payload field.** Gets you both worlds, but the runtime never reads the
  payload, so the payload is dead weight in 99% of cases.

**Decision:** B1. Keep the int handle. The OTLP adapter's side table is local
implementation detail and the only adapter we ship.

#### H-O7c — Timestamps: tracer-internal vs runtime-supplied

Current code: runtime passes `started_ms:0` / `ended_ms:0`. Bug. Two fixes:

- **C1: runtime measures `Eio.Time.now` at begin/end and passes ms.** Tracer
  still receives its time as an `int`. Adapters convert ms → ns when needed.
- **C2: tracer methods take no time; tracer queries its own clock.** Cleaner
  signature, but the runtime already has the wall clock in scope and a unified
  time source across spans is a virtue (matches Epic A's test_clock pattern).

**Decision:** C1. Runtime owns the clock, tracer is a pure sink. Fix `0` →
`runtime.now_ms ()`.

#### H-O7d — Status messages: typed vs string

Current code:
```
| Cause.Fail _ -> Error "failure"
```
Loses the user's actual error variant. OTLP `Status.message` is `string`, so
the trait stays string-typed. The fix is to render the cause:

```
| Cause.Fail err -> Error (render_cause err)
```

But `Cause.t` is `'err Cause.t`; rendering `'err` requires a printer. The
runtime doesn't know the printer for the user's polymorphic-variant error
channel. Choices:

- **D1: use `Printexc`-style generic printing on `Obj.repr` of the variant.**
  Dirty, but works for poly-variants which are runtime tags.
- **D2: take a `?cause_pp` parameter on `Runtime.create`.**
- **D3: leave it as `"failure"` and document that span message is opaque.**

**Decision:** D1 for poly-variants (best DX, no extra config), with a
`?cause_pp` escape hatch for users who want richer messages. The default is
fine for `` `Boom`` / `` `Db_unavailable`` / `` `Http_404`` which are the
typical Effet errors.

#### H-O7e — PPX vs explicit `__POS__ __FUNCTION__`

V-O5 documents the explicit form. A PPX `[%effet.fn body]` would be ergonomic
but adds ppxlib transitively to every consumer. Skipped unless requested.

#### H-O7f — Span kind / events / links

OTLP carries:
- `kind`: Internal | Server | Client | Producer | Consumer.
- `events`: timestamped log entries inside a span.
- `links`: cross-trace references.

None of these are in `Capabilities.tracer` today. Adding them now bloats the
trait. Defer to a v0.2 epic; document as known gap.

#### H-O7g — Resource attributes

OTLP `Resource` carries `service.name`, `service.version`, `telemetry.sdk.*`.
Per-tracer, not per-span. The adapter accepts `?service_name`, `?service_version`,
`?resource_attrs` at construction. This is settled by V-O3's plan and matches
the ocaml-opentelemetry shape.

### Decision diary

#### V-O7 — OTLP backend: hand-roll OTLP/JSON in effet-otel

Trait `Capabilities.tracer` is the public contract. effet-otel implements it
via OTLP/JSON over HTTP/1.1, hand-written, zero new dependencies.

If users later want metrics + logs + semantic conventions, an alternate
adapter `effet-otel-imandra` can wrap `ocaml-opentelemetry` against the same
trait. The Capabilities.tracer trait does not lock effet to either path.

#### V-O8 — Capabilities.tracer correctness fixes

Two minimum fixes land before the OTLP exporter:

1. Runtime supplies real timestamps from an `Eio.Time.clock`, not literal `0`.
2. `status_of_cause` for `Cause.Fail err` renders `err` via
   `Printexc.to_string (Obj.repr err)` (poly-variant tag), not the literal
   string `"failure"`. `?cause_pp` escape hatch on `Runtime.create` for users
   wanting richer messages.

The trait signature is unchanged.

#### V-O9 — Deferred DX work

Recorded as known gaps, not done in this session:
- Span kind / events / links on the trait.
- PPX `[%effet.fn body]`.
- Auto-instrumentation of `Sync` / `Async` leaves.
- Sampling at runtime layer.
- Per-fiber pending-attr buffer (the current `Tracer.in_memory.pending` is
  shared across fibers; OK for tests, wrong for concurrent users).

### OTLP/JSON wire shape used by effet-otel

```
POST /v1/traces HTTP/1.1
Host: 127.0.0.1:27686
Content-Type: application/json
Content-Length: N

{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key":"service.name","value":{"stringValue":"effet-demo"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name":"effet"},
      "spans": [{
        "traceId":"<32 hex>",
        "spanId":"<16 hex>",
        "parentSpanId":"<16 hex>",
        "name":"...",
        "kind":1,
        "startTimeUnixNano":"<int>",
        "endTimeUnixNano":"<int>",
        "attributes":[{"key":"...","value":{"stringValue":"..."}}],
        "status":{"code":2,"message":"..."}
      }]
    }]
  }]
}
```

Status codes per spec: 0 = UNSET, 1 = OK, 2 = ERROR. Cancelled maps to
`{"code":2,"message":"cancelled"}`.

### Implementation cost (this session)

- `packages/effet/runtime.ml`: timestamp + cause rendering fixes (~15 LOC).
- `packages/effet-otel/dune`, `packages/effet-otel/dune-project` package
  stanza: ~20 LOC.
- `packages/effet-otel/effet_otel.ml{,i}`: ~250 LOC for JSON encoder,
  HTTP/1.1 client over Eio TCP, batching daemon, Capabilities.tracer adapter.
- `packages/effet-otel/test/`: integration test that emits spans against a
  spawned mock OTLP server (or against motel if available).


## Porting `@effect/opentelemetry/test` (review session)

### Why this entry exists

To confirm Effet+effet-otel reach behavioural parity with `@effect/opentelemetry`'s
public surface, all three test files in
`.reference/effect-smol/packages/opentelemetry/test/` were ported into the
effet-otel test suite. Porting tests is the cheapest way to surface gaps:
each test that cannot be expressed in the Effet idiom is a documented gap.

### Tracer.test.ts — ported, all green

Mapping table (Effect-TS test → Effet equivalent):

| Effect-TS | Effet | Notes |
| --- | --- | --- |
| `Effect.withSpan(name)` | `Effect.named name` | already in V-O1 |
| `Effect.currentSpan` | `Effect.current_span` | added this session |
| `Effect.makeSpanScoped(name)` | run a named effect, then refer to its dumped identity | Effet has no out-of-band span minting |
| `Effect.linkSpans(span)` | `Effect.link_span ~trace_id ~span_id` | added; buffered like `Annotate` |
| `Tracer.currentOtelSpan` | repeated `Effect.current_span` reads compared for identity | no "OtelSpan" object surface in our model |
| `Tracer.withSpanContext(spanContext)` | `Effect.with_external_parent ~trace_id ~span_id` | added; verified live against motel |
| `Cause.combine(...)` ⇒ multiple `recordException` events | runtime emits one `exception` event per branch on the failing span | added; ports cleanly |
| not-provided default = noop | runtime ships `Tracer.noop` by default; `current_span` returns `None` | matches |
| `OtelApi.context.active()` global context | N/A — Effet uses Eio fiber-local for active span | divergent by design |
| `it.effect("supervisor sets context")` | tested via `Effect.current_span` returning `Some` inside a named span | observable equivalent |

#### Trait extensions made for the port

`Capabilities.tracer` grew four methods:

- `begin_span` gained `?external_parent:string * string` — used by
  `Effect.with_external_parent`.
- `add_event ~span_id ~name ~ts_ms ~attrs` — runtime emits `exception` events
  on Cause.Fail / Cause.Both branches.
- `add_link span_link` — buffered semantics like `add_attr`.
- `inspect ~span_id : span_info option` — accessor used by
  `Effect.current_span`.

`Effect.t` gained three AST nodes:

- `Link_span (link, body)` — buffer or attach a link.
- `With_external_parent (trace_id, span_id, body)` — set fiber-local override
  for the next opened span.
- `Current_span` — yields `Capabilities.span_info option`.

The runtime threads a second fiber-local `external_parent_key` so external
parent context propagates across forks just like the active-span handle.

#### Live OTLP verification

`Effect.with_external_parent ~trace_id:"abcdef0123…" ~span_id:"112233…"` ran
through `Effet_otel` against motel and produced:

```
traceId       abcdef0123456789abcdef0123456789
parentSpanId  1122334455667788
operationName external-child
```

Motel correctly notes the parent isn't local (it would be the inbound
caller's span), and the child slots into the supplied trace.

### Logger.test.ts — deferred

Effect-TS's `Effect.log` lands in OTel logs when the SDK provides a
`logRecordProcessor`. Effet has no log primitive on the trait surface and no
logs subsystem.

Cleanest path forward (V-O10):

- New `Capabilities.logger` class type with `log : level -> string -> attrs -> unit`.
- `Logger.in_memory` and `Logger.noop` modules following the tracer pattern.
- `Effet_otel` companion exporter for OTLP/JSON `/v1/logs`.
- Bridge to the OCaml `Logs` library: a `Logs.set_reporter` adapter that
  reads `Effect.current_span` and forwards records through
  `Capabilities.logger`. Applications already using `Logs` get OTel logs
  for free.

Not done in this session. Test file `test_logger.ml` documents the intent
and skips its single Alcotest case.

### Metrics.test.ts — deferred

Effect-TS's `effect/Metric` registry maps to OTel `ResourceMetrics` at
collection time. Effet has no metrics module.

Cleanest path forward (V-O11):

- New `Capabilities.meter` class type for counters / gauges / histograms.
- A small `Effet.Metric` module (counter / gauge / observable) inspired by
  `effect/Metric` but typed for OCaml — incremental vs cumulative as a
  variant, value type as a phantom (`int Counter.t` / `float Gauge.t`).
- `Effet_otel.meter` adapter targeting OTLP/JSON `/v1/metrics`.
- Optional bridge to the `prometheus` opam package for users who already
  expose a `/metrics` endpoint and want both.

Not done in this session. Test file `test_metrics.ml` documents the intent
and skips its single Alcotest case.

### Findings (the point of porting)

1. **Trait shape held.** All Tracer behaviour ported faithfully without
   restructuring `Capabilities.tracer`'s identity model. The `int` handle
   stayed; events/links/inspect attached without churn. V-O7b validated
   in practice.

2. **External parent propagation took only one new fiber-local key.**
   The "OtelApi global context" pattern doesn't translate, but the
   observable property (downstream effects see the parent) does, via the
   same Eio.Fiber primitive Epic A used.

3. **`recordException` per Cause branch is a clean fit.** Effet's
   `Cause.Both` is a binary tree; `collect` flattens it and we emit one
   event per leaf. Effect-TS's `Cause.prettyErrors` returns an array; the
   shapes match.

4. **No "OtelSpan" object equivalent, by design.** Effect-TS's
   `Tracer.OtelSpan instanceof` check leaks SDK identity into user code.
   Effet exposes a flat `span_info` record from `Effect.current_span`;
   the OTLP adapter never escapes through the trait. Better DX, fewer
   sharp edges.

5. **Logger and Metrics are independent epics.** They share the
   "Capabilities-trait + adapter package" pattern that worked for the
   tracer, but neither belongs in `effet-otel` proper if metrics need a
   different export cadence and logs need a different wire endpoint.
   Keep them as `Capabilities.logger` / `Capabilities.meter` alongside
   `Capabilities.tracer`, with `effet-otel` shipping all three OTLP/JSON
   exporters once the trait surfaces are in.


## Logger and Metrics ports — landed (V-O10 + V-O11)

Both deferred ports landed in the same review session. The trait pattern
established for `Capabilities.tracer` extended cleanly to logging and
metrics; no architectural surprises.

### Trait surface

`packages/effet/capabilities.{ml,mli}` gained:

```ocaml
type log_level = Trace | Debug | Info | Warn | Error | Fatal

type log_record = {
  level : log_level;
  body : string;
  ts_ms : int;
  attrs : (string * string) list;
  trace_id : string;  (* "" when no span is active *)
  span_id : string;   (* "" when no span is active *)
}

class type logger = object
  method log : log_record -> unit
end

type metric_kind = Counter_cumulative | Counter_monotonic | Gauge
type metric_value = Int of int | Float of float

class type meter = object
  method record :
    name:string -> description:string -> unit_:string ->
    kind:metric_kind -> attrs:(string * string) list ->
    value:metric_value -> ts_ms:int -> unit
end
```

### Effect AST extensions

```ocaml
| Log of log_level * string * (string * string) list
| Metric_update of {
    name : string; description : string; unit_ : string;
    kind : metric_kind; attrs : (string * string) list;
    value : metric_value;
  }
```

Smart constructors:

```ocaml
val log :
  ?level:log_level -> ?attrs:(string * string) list -> string -> _ Effect.t

val metric_update :
  ?description:string -> ?unit_:string -> ?attrs:(string * string) list ->
  name:string -> kind:metric_kind -> metric_value -> _ Effect.t
```

### Runtime wiring

`Runtime.create` accepts `?logger` (defaulting to `Logger.noop`) and
`?meter` (defaulting to `Meter.noop`). Interpretation:

- `Log` reads the active span via `tracer.inspect` to populate
  trace_id/span_id, stamps `ts_ms` from the runtime clock, and forwards
  to `runtime.logger#log`.
- `Metric_update` stamps `ts_ms` and forwards to `runtime.meter#record`.

### OTLP/JSON exporters

`Effet_otel` grew `logger` and `meter` constructors backed by their own
Eio streams and daemon fibers. Three signals share the same HTTP/1.1
transport, host/port, resource attributes, and `on_error` callback. New
`?on_send` callback is exposed for tests to inspect the encoded JSON
without a roundtrip.

Aggregation: `aggregate_points` merges raw meter points by
`(name, kind, attrs, description, unit_)`. Gauges retain the latest
value, counters sum. The same logic powers both
`encode_metrics_request` and the unit tests, so test and live agree.

### JSON encoding

The hand-written JSON Buffer code was replaced by Yojson 3.0 across all
three signals. The ergonomics win is meaningful — escape rules and
nesting are a library concern again. Dependency cost: yojson + its
transitive closure, added to flake.nix.

### Test ports

`packages/effet-otel/test/test_logger.ml` and `test_metrics.ml`
graduated from `Alcotest.skip` stubs to passing test cases:

| Test | Coverage |
| --- | --- |
| Logger / emits log records | 10 emissions arrive at Logger.in_memory |
| Logger / log carries active span ids | log inside `named "parent"` carries span trace_id/span_id and ts_ms is bracketed by span lifetime |
| Logger / not provided log dropped | noop logger silently drops |
| Logger / log OTLP live | logs land in motel with correct traceId/spanId, verified via `motel logs` |
| Metrics / gauge | latest-write-wins per attribute set |
| Metrics / counter cumulative | sum per attribute set, non-monotonic |
| Metrics / counter monotonic | sum per attribute set, monotonic |
| Metrics / metrics OTLP live | exporter posts well-formed OTLP/JSON metrics, verified via `on_send` capture + Yojson parse |

### Findings (the point of porting, again)

1. **Trait pattern reused without adjustment.** The same shape that
   worked for the tracer (in_memory + noop + as_capability + dump)
   carried over to logger and meter unchanged.

2. **`on_send` capture beats a mock server.** Motel doesn't accept
   `/v1/metrics`; spinning up an in-Eio test HTTP server would have been
   25 LOC of fragile request parsing. A `?on_send:(path:string ->
   body:string -> unit)` callback gives tests direct access to the
   encoded body. They parse with Yojson and assert on the structure.

3. **Active span correlation lands automatically.** `Effect.log`
   inside `Effect.named` carries the span's trace_id and span_id with
   no extra wiring at the call site. Verified end-to-end against motel:
   logs and traces share the same traceId.

4. **Logger and Meter are independent of Tracer.** The runtime fields
   are independent and the OTLP exporter funnels them down separate
   queues to separate paths. An app that only wants metrics doesn't
   pay the tracing cost.

## effet-stream design — Stream / Sink / Channel (4h research)

### Why this entry exists

Effet has the core `('env, 'err, 'a) Effect.t` runtime, typed failures,
resource scopes, parallel combinators, and runtime-parameter tracing. It does
not yet have a streaming package. Effect-TS has a large Stream/Sink/Channel
surface, but its public types were shaped by TypeScript's type system. This
entry decides the OCaml shape before any real `packages/effet-stream/`
implementation.

Methodology follows V-R10 and V-F1: build a compiler-checked scratch lab first,
write negative tests for claimed type guarantees, then record decisions.

### Goal

Produce an implementable contract for `effet-stream`:

- a hypothesis-space map for Stream / Sink / Channel;
- lab candidates in `scratch/stream_research/`;
- negative compiler evidence;
- a final stub interface in `scratch/stream_research/STUB_stream.mli`;
- a backlog handoff in `scratch/stream_research/BACKLOG.md`.

User update during the session: creating the real `packages/effet-stream/`
package is allowed if the research settles with enough time left. This entry
still treats research evidence as the first gate.

### Time budget — 4h breakdown

Original target:

- 0:00-0:30 — read context and survey Effect-TS tests;
- 0:30-1:30 — build positive lab candidates;
- 1:30-2:30 — run negative tests;
- 2:30-3:15 — cross-tabulate;
- 3:15-4:00 — journal, stub, backlog.

Actual path: context read plus lab build dominated. A first negative test
compiled unexpectedly because S-A's ignored `~scope` argument inferred as
unconstrained; that was fixed before recording the final compiler output.

### Constraints inherited from prior research

- V-R10 stands: keep the object-row `'env` channel. Stream operators must demand
  only what their embedded effects use.
- Typed errors stay polymorphic-variant rows and unify with `Effect.t`.
- Failure causes are `Cause.Fail`, `Die`, `Interrupt`, and `Both`; stream must
  not create a second failure model.
- V-F1 stands: no public `Fiber.t`. Stream concurrency is owned by Eio switches
  inside the interpreter.
- V-O6 stands: tracer is a runtime parameter, not an env-row requirement.
- No Layer, no STM, no public fiber handles.

### Hypothesis space (axes + concrete candidates)

Axes tested:

| Axis | Options considered |
| --- | --- |
| Core type | Channel-as-core, Stream-as-core, Eio pipeline |
| Pull/push | pull at public boundary, push/fiber queues internally |
| Element representation | single element vs chunked pull |
| Concurrency backing | pure GADT interpreter vs Eio.Stream queues |
| Resource scoping | scoped token, Effect.scoped reuse, explicit switch |
| Sink shape | fold record vs Channel reader |

Concrete lab candidates:

- **S-A** — `s_a_channel_core.ml`: Channel-as-core, Stream derived, chunked
  output, fold Sink.
- **S-B** — `s_b_stream_core.ml`: Stream-as-core GADT, chunked pull, fold Sink.
- **S-C** — `s_c_eio_pipeline.ml`: Eio.Stream-backed fiber-per-stage pipeline.

The suggested Seq-of-effects S-D was not expanded into a full lab candidate.
It is subsumed by S-B as a source constructor (`from_iterable` /
`from_effect`) but does not scale to merge, broadcast, resource cancellation,
or chunked backpressure as a core.

### Survey: Effect-TS Stream/Sink/Channel surface

Effect-TS Stream is public as `Stream<A, E, R>` and internally stores a
`Channel<NonEmptyReadonlyArray<A>, E, void, unknown, unknown, unknown, R>`.
Its tests cluster around constructors, map/filter, take/drop, pagination,
error handling, scan/group/flatten, transduce, buffering, sharing, race/merge,
partition, repeat/retry/schedule, sliding/split, timeout, and zipping.

Sink is `Sink<A, In, L, E, R>`: a consumer that may read many inputs, fail with
`E`, return `A`, and optionally return leftovers `L`. The tested core is
fold/reduce, take/takeWhile, head/last/find, collect/count, effectful steps,
and transduce.

Channel is the most general abstraction:
`Channel<OutElem, OutErr, OutDone, InElem, InErr, InDone, Env>`. The tests cover
constructors, mapping/filtering, merge/switchMap, interruptWhen, conditional
catch, and typed unwrapping. The concrete extra power over Stream is a
bidirectional transducer: it can read an upstream element/error/done channel,
emit output elements/errors, and return a terminal output value.

OCaml cost: Channel's seven TypeScript parameters become expensive in every
signature. The lab found no first-slice OCaml example that needs `InErr` and
`InDone` as public type parameters.

### Worked example — A/B/C across all candidates

Every positive candidate implements:

```ocaml
range 1 10
|> map (fun n -> n * 2)
|> take 5
|> run (Sink.fold ( + ) 0)
```

`runtime_smoke.ml` asserts the result is `30` for S-A, S-B, and S-C.

Every candidate also implements a fake resource source. `runtime_smoke.ml`
builds a three-element fake file, applies `take 1`, runs a fold, and asserts
that the close hook ran exactly once.

Validation:

```text
nix develop -c dune build scratch/stream_research/
nix develop -c dune exec scratch/stream_research/runtime_smoke.exe
```

Both pass. The smoke executable is silent on success.

### Negative tests

Each negative was run by temporarily adding the module stem to
`scratch/stream_research/dune`'s `(modules ...)` list.

`neg_a_resource_leak.ml`:

```text
File "scratch/stream_research/neg_a_resource_leak.ml", line 9, characters 39-44:
9 |   S_a_channel_core.Stream.scoped_file ~scope "bad" [ 1; 2; 3 ]
                                           ^^^^^
Error: The value scope has type [ `Closed ]
       but an expression was expected of type
         S_a_channel_core.Channel.open_scope
       These two variant types have no intersection
```

Finding: S-A can enforce a scoped-token shape only if the argument is explicitly
annotated. The first version compiled, proving that ignored labelled arguments
are not evidence of scoping. After annotation, the negative fails as intended.

`neg_b_escape.ml`:

```text
File "scratch/stream_research/neg_b_escape.ml", lines 12-13, characters 2-39:
12 | ..S_b_stream_core.run bad_stream
13 |     (S_b_stream_core.Sink.fold ( + ) 0)
Error: This expression has type
         (<  >, [ `Boom ], int) S_b_stream_core.Effect.t
       but an expression was expected of type
         (<  >, [ `Other ], int) S_b_stream_core.Effect.t
       These two variant types have no intersection
```

Finding: S-B preserves the stream error channel through `run`; typed stream
failures are not erased into a separate stream error model.

`neg_c_stage_unscoped.ml`:

```text
File "scratch/stream_research/neg_c_stage_unscoped.ml", lines 7-8, characters 2-39:
7 | ..S_c_eio_pipeline.Stream.spawn
8 |     (S_c_eio_pipeline.Stream.range 1 3)
Error (warning 5 [ignored-partial-application]): this function application is partial,
  maybe some arguments are missing.
```

Finding: S-C can require an owning `Eio.Switch.t` to materialise a stage, but
the public shape is still push/fiber-heavy and easy to allocate per operator.

### Cross-tabulation

| Criterion | S-A Channel-core | S-B Stream-core | S-C Eio pipeline |
| --- | --- | --- | --- |
| Public type surface | heavy if Channel public | small | small but operational |
| Env row preservation | yes | yes | yes |
| Error row preservation | yes | yes, negative-tested | weak in lab; would need result items |
| Pull/backpressure | yes | yes | boundary is queue push |
| Chunked representation | yes | yes | no, unless queue carries chunks |
| Resource early close | yes in smoke | yes in smoke | yes in smoke |
| Concurrent operators | expressible, but Channel grows | expressible via interpreter | natural but pays fibers everywhere |
| Type readability | poor once Channel public | best | good API, complex runtime |
| Primitive count pressure | high | moderate | low AST, high runtime machinery |
| Faithful to Effect-TS | highest | behaviour-faithful | lowest |

Winner: **S-B**. It keeps the public API small, preserves Effet's existing
channels, and allows Channel to remain an internal implementation tool until a
real OCaml example justifies exposing its input/error/done parameters.

### Decision diary

#### V-S1 — Core type

Adopt **Stream-as-core** for the public package. `Stream.t` is the public GADT;
`Sink.t` is a public fold/effectful-fold record; `Channel` is internal in v0.
S-A proved that Channel can host streams, but making it public imports seven
parameters before the package has a concrete OCaml use case for input errors
and input done values. S-B gives the same A/B/C behaviour with the smallest
surface.

#### V-S2 — Pull mechanism

Use pull at the public boundary. `take`, `drop`, and resource cleanup are
consumer-driven behaviours in `Stream.test.ts`; push-only pipelines make early
termination a cancellation problem at every stage. S-C showed Eio.Stream queues
are useful inside concurrent operators, but making every operator a live queue
allocates fibers and buffers for purely sequential pipelines.

#### V-S3 — Element representation

Use chunked pulls. With 1,000,000 elements and chunk size 4096, a single-stage
pipeline needs about 245 pull steps instead of 1,000,000. In a `map |> filter
|> take` pipeline, single-element pull allocates one step/result per element per
stage; chunked pull cuts that control allocation by roughly 4000x while still
letting pure operators map inside a list/array chunk. v0 can represent chunks
as non-empty lists; a dedicated `Chunk` module can wait.

#### V-S4 — Resource scoping

Streams reuse Effet's existing `Effect.scoped` / `Effect.acquire_release`
semantics. No implicit switch per stream value. A resource source is just a
stream whose interpreter acquires before first pull and registers finalization
with the surrounding effect scope. Early `take`, failure, defect, and
cancellation all close because the run effect exits the scope. S-A's failed
first negative is the warning: do not claim static scoping from an ignored
token.

#### V-S5 — Sink shape

Adopt fold records for v0:

```ocaml
type ('env, 'err, 'in_, 'out) Sink.t = {
  init : unit -> 'out;
  step : 'out -> 'in_ -> ('env, 'err, 'out) Effect.t;
  done_ : 'out -> ('env, 'err, 'out) Effect.t;
}
```

This composes well with OCaml inference and mirrors the Effect-TS Sink core
without public leftovers. Channel-reader sinks are more general, but the lab
does not justify their type cost for fold/count/collect/take.

#### V-S6 — Channel: keep, derive, or drop

Keep Channel as an internal design concept, not a public v0 module. A public
Channel can express bidirectional transducers such as "read byte chunks, emit
decoded lines, return the final decoder state, and handle upstream decode
errors separately from downstream write errors." That is real power, but the
first package slice needs Stream and Sink behaviours, not public
`InElem/InErr/InDone` polymorphism. Revisit when implementing `decodeText`,
`splitLines`, or a true transducer API.

#### V-S7 — Operators surface (primitives vs combinators)

Keep primitive constructors under about 10-15: empty/chunk/effect/fail,
map-effect, filter-map, take/drop, concat/flat_map, acquire, merge,
flat_map_par, named/annotate. Pure `map`, `filter`, `scan`, `collect`,
`count`, `run_drain`, `run_collect`, `zipWithIndex`, and many Effect-TS-style
helpers are combinators. The split follows interpreter needs: only resource,
effect, chunk boundary, and concurrency semantics need primitive nodes.

#### V-S8 — Interop with Eio.Stream / Eio.Buf_read

Support `from_eio_stream`, but do not claim ownership of the producer queue.
It is an adapter: cancellation stops this consumer, not the external producer.

Byte streams deserve a small special-case layer. `Eio.Buf_read` and files
operate on bytes and buffers, not arbitrary `'a`; v0 can expose `from_file` as a
`bytes Stream.t`. A sibling `Bytes_stream` is deferred until byte-specific
operators (`split_lines`, decoding, framing) become large enough to justify it.

#### V-S9 — Tracer integration for streams

Expose `Stream.named` and `Stream.fn` analogous to `Effect.named` and
`Effect.fn`. Interpretation opens one span per pulled chunk, not per element.
Per-element spans would destroy the allocation win from V-S3 and produce
unusable traces for large streams. Runtime tracer injection remains V-O6:
streams do not demand `env#tracer`.

#### V-S10 — Final stub mli

The chosen contract is `scratch/stream_research/STUB_stream.mli`. It records
Stream-as-core, chunked pull, fold Sink, no public Channel, Eio interop, byte
source, concurrent operators, and tracing smart constructors.

### Artifacts

- `scratch/stream_research/dune`
- `scratch/stream_research/README.md`
- `scratch/stream_research/services.ml`
- `scratch/stream_research/s_a_channel_core.ml`
- `scratch/stream_research/s_b_stream_core.ml`
- `scratch/stream_research/s_c_eio_pipeline.ml`
- `scratch/stream_research/neg_a_resource_leak.ml`
- `scratch/stream_research/neg_b_escape.ml`
- `scratch/stream_research/neg_c_stage_unscoped.ml`
- `scratch/stream_research/runtime_smoke.ml`
- `scratch/stream_research/STUB_stream.mli`
- `scratch/stream_research/BACKLOG.md`

### What we are deliberately not building

- Public `Channel.t` in v0.
- Public `Fiber.t` or stream fibers that escape their owning switch.
- STM, Layer, Tag, Context, or a second error model.
- A full Effect-TS operator clone. The package starts with the operators in
  `STUB_stream.mli` and ports behaviours in slices.
- Per-element tracing by default.

### Meta-lesson

The useful reversal was small but important: S-A's negative compiled until the
scope parameter was annotated. That is the same lesson as V-R10: if the claim is
"OCaml enforces this", write the negative file. A passing positive smoke test
does not prove a type invariant.

### Implementation follow-up in the same session

Because the user clarified that a real package was in scope after research, I
started `packages/effet-stream/` after V-S1..V-S10 settled:

- `dune-project` now has an `effet-stream` package stanza.
- `packages/effet-stream/dune` defines public library `effet-stream`.
- `packages/effet-stream/effet_stream.mli` mirrors the selected public shape.
- `packages/effet-stream/effet_stream.ml` implements the sequential skeleton:
  constructors, `map`, `map_effect`, `filter`, `take`, `drop`, `scan`,
  `concat`, sequential `flat_map`, `Sink`, and runners.

Known skeleton gaps:

- `merge` and `flat_map_par` currently degrade to sequential structure; the
  concurrent implementation belongs to backlog task 5.
- `from_eio_stream` and `from_file` are structural placeholders; the resource
  implementation belongs to backlog task 4.
- No package tests were added yet; backlog task 6 covers the curated parity
  suite.

Validation:

```text
nix develop -c dune build packages/effet-stream/ scratch/stream_research/
nix develop -c dune exec scratch/stream_research/runtime_smoke.exe
```

Both pass. A broad `nix develop -c dune build` was attempted but interrupted
after producing no output for over a minute; targeted package and research
builds are the current evidence for this session.

## effet-stream second pass — stronger alternatives and confidence check

### Why this entry exists

The first V-S pass was good enough for a v0 direction, but not strong enough to
claim the chosen shape was close to optimal. The weak points were clear:

- S-C was an unfairly weak Eio candidate because it moved single elements, not
  chunks.
- S-A did not include a concrete transducer where Channel's input parameters
  earn their keep.
- S-D/Seq was dismissed in prose rather than tested.
- The allocation and early-termination cost model was reasoned, not measured.

This pass tries harder to disprove V-S1..V-S3.

### Added lab candidates

- `s_b2_pull_core.ml` — a stronger pull-core stream with explicit cursors,
  chunked pulls, close hooks, and stats counters.
- `s_d_eio_chunked.ml` — a stronger Eio-native stream where queues carry
  chunks, not elements. It explicitly cancels the switch on downstream
  completion.
- `s_e_channel_transducer.ml` — a Channel/transducer candidate with a
  `split_lines` example. This is the first lab example where Channel's input
  side does useful work.
- `s_f_seq_pull.ml` — a minimal `Seq.t`-style candidate. It computes the simple
  scenario but intentionally demonstrates a resource leak under early `take`.
- `benchmark_compare.ml` — a small comparative runner over 1M elements and an
  early-termination resource case.

### Positive checks

`runtime_smoke.ml` now covers S-A, S-B, S-C, S-B2, S-D, S-E, and S-F.

Results:

- All candidates compute the A/B/C scenario result `30`.
- S-A/S-B/S-C/S-B2/S-D close the fake file on early `take`.
- S-E's `split_lines` transducer turns `["a\nb"; "\nc"]` into
  lines `["a"; "b"]` plus carry `"c"`.
- S-F computes the value but leaves the fake resource unclosed after early
  `take`; this is recorded as a runtime hazard, not a compile-time failure.

Validation:

```text
nix develop -c dune build scratch/stream_research/
nix develop -c dune exec scratch/stream_research/runtime_smoke.exe
```

Both pass.

### Negative checks rerun

The original negatives were rerun after adding the stronger candidates:

- `neg_a_resource_leak.ml` still fails with the `S_a_channel_core.Channel.open_scope`
  mismatch.
- `neg_b_escape.ml` still fails when assigning a `` `Boom`` stream run to an
  effect typed as `` `Other``.
- `neg_c_stage_unscoped.ml` still fails as a missing `~sw` partial application.

No new compile-time negative exists for S-F because the point is the opposite:
the simple `Seq.t` shape compiles while losing the resource guarantee.
`runtime_smoke.ml` asserts the hazard by expecting zero closes.

### Benchmark evidence

Command:

```text
nix develop -c dune exec scratch/stream_research/benchmark_compare.exe
```

Observed output:

```text
pull_core stats: pulls=246 chunks=245 elements=1000000
pull_core full: 0.0276s 20249419_words
eio_chunked stats: fibers=3 chunks_sent=735 elements_sent=2333333
eio_chunked full: 0.0447s 19441019_words
pull_take stats: pulls=1 chunks=1 elements=4096 closes=1
pull_core take5: 0.0117s 5767128_words
eio_take stats: fibers=2 chunks_sent=4 elements_sent=12293 closes=1
eio_chunked take5: 0.0295s 14819337_words
```

Interpretation:

- Full sequential pipeline: chunked Eio queues are viable, but they still fork
  three fibers and send 735 chunks through queues for source/map/filter. The
  pull core performs 245 chunk pulls and no fibers. Wall time favoured pull in
  this run; allocation was similar for full traversal.
- Early `take 5`: pull core consumes one chunk (4096 elements) and closes once.
  The chunked Eio candidate consumes/sends four chunks and 12293 elements before
  cancellation wins. Allocation was ~14.8M words for Eio vs ~5.8M for pull.
- First S-D draft deadlocked on `take` because the source was blocked on a
  bounded queue while the switch waited for child fibers. Fixing it required
  explicit downstream-completion cancellation. This is a real implementation
  burden for Eio-as-core, not an argument against using Eio internally.

These are lab numbers, not production benchmarks. They are strong enough to
decide the representation default.

### Channel finding

S-E finally gives Channel a fair example. A `split_lines` transducer naturally
has:

- input element: byte/string chunk;
- input done: upstream completion;
- output element: line;
- output done: final carry.

That is real expressive power. It does not overturn V-S6 because the same lab
also shows the type cost:

```ocaml
(< >, no_error, string, unit, string, string) Channel.t
```

This is before modelling separate input errors and output errors. Channel is
worth keeping as an internal implementation concept and likely future
transducer API. It still does not belong in the first public surface.

### Seq finding

S-F is the boring OCaml baseline. It is attractive for pure finite streams, and
the A/B/C scenario is trivial. It fails the resource guarantee:

```text
resource |> take 1 |> fold
```

returns the value while leaving the fake file unclosed because `Seq.t` has no
standard finalization hook on early termination. A custom bracketed sequence
would be a new stream abstraction by another name.

### Decision update

#### V-S11 — S-B confirmed as public core

The second pass confirms the original public choice: Stream-as-core, chunked
pull, fold Sink, internal Channel. Confidence is now materially higher because
the strongest Eio alternative was chunked and still lost on default cost and
early-termination complexity.

#### V-S12 — Eio.Stream is an internal concurrency transport, not the core

Use Eio queues for `merge`, `flat_map_par`, fanout, buffering, and interop with
external Eio queues. Do not put an Eio queue/fiber behind every `map`,
`filter`, or `take`. The implementation rule from S-D: downstream completion
must cancel upstream producers explicitly or bounded queues can deadlock.

#### V-S13 — Channel remains internal, but transducers are the revisit trigger

Channel is not dead. `split_lines` demonstrates the real use case: byte/text
transducers with terminal carry. The trigger for public Channel is a small
cluster of byte/text APIs (`decode`, `split_lines`, framing) that cannot be
cleanly expressed with Stream + Sink alone.

#### V-S14 — Seq is rejected as core

Plain `Seq.t` is too weak for scoped resources. It can be an adapter source for
pure finite data, but not the representation underneath `effet-stream`.

### Contract impact

No change to `STUB_stream.mli`. The second pass strengthens the rationale
behind the existing contract. `BACKLOG.md` was updated only to add the S-D
lesson to concurrent-operator acceptance criteria: downstream completion must
cancel upstream producers.

## Effet schema/decode/validation design (2h research)

### Why this entry exists

Effet has no schema, decode, or validation surface. A prior conversation leaned
toward "build a small `Effet.Decode`, skip Schema entirely", but that was a
prose conclusion. This entry reruns the question lab-first, with H-S0 through
H-S5 treated as real candidates.

The scope is research only. No code in `packages/effet/` or
`packages/effet-otel/` was touched.

### Goal

Decide whether Effet should ship:

- nothing, with a documented OCaml stack;
- a small Decode wrapper;
- Decode plus validation;
- a first-class Schema GADT;
- a hybrid ppx-backed schema layer;
- or another shape found during the lab.

### Time budget

Strict budget: 2h. The lab and journal were completed inside that wall-clock
limit. The candidate implementations are intentionally small and not production
code.

### Constraints inherited from prior research

- V-R10 stands: if a decoder is effectful, its `'env` requirement must be an
  object row and demand only what it uses.
- Typed errors stay polymorphic variants. Decode failures must compose as
  ordinary `Effect.t` failures and travel through `Cause.Fail`.
- Slim `Cause.t` / `Exit.t` remain the only failure model.
- Effet is not an application framework. Applications own domain state and
  domain data modelling.

### Curated fixture from Effect-TS Schema

The fixture is `scratch/schema_research/fixture.ml`. It compresses the
8.3k-line `Schema.test.ts` and adjacent schema tests into 14 behaviours:

| Behaviour | Effect-TS source |
| --- | --- |
| decode unknown to typed value with structured issue | `Schema.ts` decode docs; `Schema.test.ts` struct failures |
| encode typed value to JSON | `Schema.ts` encode docs; `Schema.test.ts` struct encoding |
| struct fields | `Schema.test.ts` `{ readonly "a": string }` |
| array fields | `Schema.test.ts` array and struct-with-array cases |
| literal / union | `Schema.test.ts` `Literal`, `Literals`, `Union` |
| optional key | `Schema.test.ts` `Schema.optionalKey` |
| refinement | `Schema.test.ts` `isMinLength`, `isBetween` |
| branding | `Schema.ts` `brand`; representation brand tests |
| bidirectional transform | `Schema.test.ts` `NumberFromString`, `FiniteFromString`, `decodeTo` |
| effectful decode | `Schema.ts` `decodeUnknownEffect` service channel |
| JSON Schema doc | `toJsonSchemaDocument.test.ts` object/properties/required |
| arbitrary samples | `toArbitrary.test.ts` primitive/struct generation |
| equivalence | `toEquivalence.test.ts` string/struct equality |
| Cause integration | Effet-specific: `tap_error` / `catch` over `` `Decode`` |

The concrete fixture value is a `person` record:

```ocaml
type person = {
  name : string;
  age : int;
  email : string option;
  tags : string list;
}
```

The same valid JSON, missing-field JSON, and refinement-failing JSON are used
against every surviving hypothesis.

### Hypotheses and lab candidates

Artifacts live in `scratch/schema_research/`:

| Hypothesis | File | Shape |
| --- | --- | --- |
| H-S0 | `h_s0_skip.ml` | no Effet API; recommended external stack |
| H-S1 | `h_s1_decode.ml` | parser-to-`Effect.t` wrapper |
| H-S2 | `h_s2_decode_validate.ml` | H-S1 plus validators and hidden brand constructor |
| H-S3 | `h_s3_schema_gadt.ml` | first-class schema GADT / codec value |
| H-S4 | `h_s4_ppx_schema.ml` | ppx marshalling plus schema metadata/refinements |
| H-S5 | `h_s5_codec_record.ml` | discovered codec-record alternative |

Positive validation:

```text
nix develop -c dune build scratch/schema_research/
nix develop -c dune exec scratch/schema_research/runtime_smoke.exe
support counts: h0=0 h1=6 h2=8 h3=14 h4=10 h5=14
```

LOC / support count:

| Hypothesis | Candidate LOC | Fixture support |
| --- | ---: | ---: |
| H-S0 | 32 | 0 / 14 |
| H-S1 | 103 | 6 / 14 |
| H-S2 | 103 | 8 / 14 |
| H-S3 | 315 | 14 / 14 |
| H-S4 | 129 | 10 / 14 |
| H-S5 | 202 | 14 / 14 |

### Negative tests

Each negative was run by temporarily adding its module stem to
`scratch/schema_research/dune` and building `scratch/schema_research/`.

`neg_hs1_error_erasure.ml`:

```text
File "scratch/schema_research/neg_hs1_error_erasure.ml", line 6, characters 2-54:
6 |   H_s1_decode.decode_person Fixture.person_bad_missing
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: This expression has type
         (<  >, [> `Decode of Fixture.issue list ], Fixture.person)
         Effet.Effect.t
       but an expression was expected of type
         (<  >, [ `Other ], Fixture.person) Effet.Effect.t
       The second variant type does not allow tag(s) `Decode
```

Finding: H-S1 preserves the typed error row. Decode failures are not erased.

`neg_hs2_plain_brand.ml`:

```text
File "scratch/schema_research/neg_hs2_plain_brand.ml", line 4, characters 43-50:
4 | let bad : H_s2_decode_validate.User_id.t = "u_123"
                                               ^^^^^^^
Error: This constant has type string but an expression was expected of type
         H_s2_decode_validate.User_id.t =
           (string, H_s2_decode_validate.User_id.brand)
           H_s2_decode_validate.Brand.t
```

Finding: hidden constructors can enforce nominal/branded values, but only per
domain module. A generic public `brand` helper is not enough without hiding the
constructor behind a module signature.

`neg_hs3_encode_direction.ml`:

```text
File "scratch/schema_research/neg_hs3_encode_direction.ml", line 7, characters 4-9:
7 |     "1.5"
        ^^^^^
Error: This constant has type string but an expression was expected of type
         float
```

Finding: H-S3 can statically keep transformation direction straight. A
`FiniteFromString`-style schema decodes JSON string to `float`, and its
encoder accepts `float`, not the encoded string.

`neg_hs5_missing_env.ml`:

```text
File "scratch/schema_research/neg_hs5_missing_env.ml", lines 7-9, characters 2-26:
7 | ..H_s5_codec_record.Codec.decode
8 |     (H_s5_codec_record.person_with_policy ())
9 |     Fixture.person_ok_json
Error: This expression has type
         (< age_policy : int -> bool; .. >,
          [> `Decode of Fixture.issue list ], Fixture.person)
         Effet.Effect.t
       but an expression was expected of type
         (<  >, [> `Decode of Fixture.issue list ], Fixture.person)
         Effet.Effect.t
       The second object type has no method age_policy
```

Finding: the env-row dividend survives an effectful codec-record shape.

### Cause integration

`runtime_smoke.ml` verifies H-S1 decode failure through real Effet
`tap_error` and `catch`. The failure is a normal `` `Decode of issue list``
typed failure under `Cause.Fail`, not a parallel schema error hierarchy.

H-S5 also verifies an effectful decoder whose age policy is read from the env
object row. The negative above proves that missing service requirements are
reported at compile time.

### Ecosystem survey

The opam/web survey showed enough existing surface to make "ship a whole
schema library" a high bar:

| Library | Strength | Gap relative to Effect-TS Schema |
| --- | --- | --- |
| `decoders` | Elm-inspired combinator decoders for JSON-like values; backend packages include Yojson/Jsonm/etc. | Decode-only; no encode, JSON Schema, arbitrary, or equivalence. |
| `data-encoding` | Bidirectional JSON and binary encoding combinators. Closest to H-S5. | Heavier dependency stack; not Effet-shaped errors/env; not a validation/brand story by itself. |
| `ppx_yojson_conv` | Mature deriving plugin for Yojson conversion functions. | Latest opam package targets newer OCaml than Effet's 5.1 floor; decode errors are ppx library-shaped, not Effet-shaped. |
| `ppx_deriving_jsonschema` | Generates JSON Schema from OCaml types. | JSON Schema only; does not own decoding/validation/effectful services. |
| `atd` / `atdgen` | Schema-first IDL; generates efficient JSON serializers, deserializers, and validators. | Separate type-description language; good boundary tool, but not an Effet API. |
| `repr` / `ppx_repr` | Type representations and generic operations, used by Irmin-related packages. | `repr` states no stability guarantee for public consumption; closer to H-S3/H-S5 than to a small wrapper. |
| `irmin-type` | No standalone opam package was found in the survey; the relevant public artifact is `repr` / `ppx_repr`. | Not a direct dependency target for Effet. |

### Cross-tabulation

| Criterion | H-S0 | H-S1 | H-S2 | H-S3 | H-S4 | H-S5 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Fixture behaviours | 0 | 6 | 8 | 14 | 10 | 14 |
| Cause integration | n/a | yes | yes | yes | yes | yes |
| Env-row effectful decode | n/a | yes | inherited | possible | absent in lab | yes |
| Encode | external | no | no | yes | yes | yes |
| JSON Schema doc | external | no | no | yes | yes | yes |
| Arbitrary/equivalence | external | no | no | yes | yes | yes |
| Branding | app/private types | no | yes | yes | no | yes-by-convention |
| Competes with existing OCaml libs | no | low | medium | high | high | high |
| API/implementation size pressure | none | low | medium | high | medium | medium |

### Decision diary

#### V-Schema1 — H-S1 is not enough

H-S1 is useful but narrow. It preserves typed errors and Cause integration,
verified by `neg_hs1_error_erasure.ml` and `runtime_smoke.ml`, but it supports
only 6/14 fixture behaviours. It cannot encode, generate JSON Schema, derive
arbitrary samples, derive equivalence, or enforce branding. The prior
conversation's H-S1 instinct is therefore not a credible answer to "Schema" as
defined by Effect-TS; it is only a boundary adapter.

#### V-Schema2 — H-S2 improves validation but still is not Schema

H-S2 adds refinements and private branded values, reaching 8/14 behaviours.
`neg_hs2_plain_brand.ml` proves nominal identity is enforceable when the brand
constructor is hidden. The cost is that branding becomes per-domain module
ceremony, not a universal one-liner. H-S2 still has no encode, JSON Schema,
arbitrary, or equivalence story.

#### V-Schema3 — H-S3 survives the lab but is a real schema library

The first-class schema candidate passes all 14 behaviours and statically
protects transformation direction (`neg_hs3_encode_direction.ml`). That
overturns any claim that an OCaml schema GADT is impossible. The rejection is
not type-system failure; it is ownership. Even the lab needed 315 LOC, a
`custom` constructor for records, hand-written JSON Schema, arbitrary samples,
and equality. A credible production H-S3 would compete directly with
`data-encoding`, `repr`, `ppx_deriving_jsonschema`, `atdgen`, and ppx codecs.

#### V-Schema4 — H-S4 is a useful hybrid, not an Effet core surface

H-S4 shows that ppx-generated JSON codecs can be wrapped with schema metadata
and refinements, reaching 10/14 behaviours. It dodges reimplementing record
marshalling, but it still needs a parallel value-level schema for docs,
arbitrary, equivalence, and refinements. It also did not model effectful decode
or branding without adding the same machinery as H-S2/H-S5. This is an app
architecture pattern, not a core Effet abstraction.

#### V-Schema5 — H-S5 is the best "if we build something" shape

The discovered codec-record shape passes all 14 behaviours in 202 LOC and keeps
env-row effectful decode (`neg_hs5_missing_env.ml`). It is more OCaml-native
than the GADT for ordinary records. The lab also exposed a value-restriction
cost: polymorphic effectful codec values had to become `unit -> codec`
constructors to avoid weak env variables after reuse. H-S5 is the best future
companion-package shape, but it is also essentially `data-encoding` with
Effet-shaped decode effects.

#### V-Schema6 — Final recommendation: H-S0 for Effet core

Do not add `Effet.Schema`, `Effet.Decode`, or `Effet.Validate` to core Effet
now. The lab-backed reason is not that schema cannot be built. It can:
H-S3/H-S5 pass the fixture. The reason is that the useful versions are whole
codec/schema libraries, and the small versions are too narrow to justify an
Effet-owned API. Effet should document the recommended external stack and show
how to map external decoder errors into `Effect.fail (`Decode issues)`.

#### V-Schema7 — Package placement if this is reopened

If a real Effet artifact is demanded later, it should be a companion package,
not `packages/effet/`: `effet-codec` or `effet-decode`. Start from H-S5, not
H-S1 or H-S3. Acceptance for reopening: one real application needs effectful
decode with env-row services and Cause integration across multiple codecs, and
existing libraries cannot supply it with a small adapter.

### Recommended stack for H-S0

Effet should document these choices:

- Use `ppx_yojson_conv` when the app already accepts the Jane Street/Base stack
  and wants generated Yojson functions.
- Use `decoders` when the boundary is decoder-combinator heavy and encode/schema
  derivation is not needed.
- Use `data-encoding` when bidirectional codecs and JSON/binary encodings are
  needed.
- Use `ppx_deriving_jsonschema` when the deliverable is JSON Schema from OCaml
  types.
- Use `atd` / `atdgen` when the team wants an IDL and generated serializers.
- Use `repr` / `ppx_repr` only after accepting its stability caveat; it is the
  closest ecosystem precedent to H-S3/H-S5.

Effet documentation can include a tiny adapter pattern:

```ocaml
let decode_effect decode json =
  match decode json with
  | Ok value -> Effet.Effect.pure value
  | Error issues -> Effet.Effect.fail (`Decode issues)
```

That adapter is not enough to justify a package by itself.

### Artifacts

- `scratch/schema_research/dune`
- `scratch/schema_research/README.md`
- `scratch/schema_research/fixture.ml`
- `scratch/schema_research/h_s0_skip.ml`
- `scratch/schema_research/h_s1_decode.ml`
- `scratch/schema_research/h_s2_decode_validate.ml`
- `scratch/schema_research/h_s3_schema_gadt.ml`
- `scratch/schema_research/h_s4_ppx_schema.ml`
- `scratch/schema_research/h_s5_codec_record.ml`
- `scratch/schema_research/runtime_smoke.ml`
- `scratch/schema_research/neg_hs1_error_erasure.ml`
- `scratch/schema_research/neg_hs2_plain_brand.ml`
- `scratch/schema_research/neg_hs3_encode_direction.ml`
- `scratch/schema_research/neg_hs5_missing_env.ml`

No `STUB_*.mli` or backlog epic was created because the recommendation is
H-S0: no Effet package work now.

### What we are deliberately not building

- No `packages/effet-schema/` or `packages/effet-decode/`.
- No production JSON Schema generator, arbitrary generator, or equivalence
  derivation.
- No dependency on Yojson, Base, data-encoding, atdgen, or repr in Effet core.
- No second failure model for validation errors.

### Meta-lesson

The prior H-S1 instinct was too small, but H-S3's dismissal was also too quick.
The compiler and smoke fixture show H-S3 is viable. The final decision is an
ownership decision: Effet should not grow into a schema ecosystem unless a real
application forces that boundary.

## Effet schema second pass — migration-grade Schema contract

### Why this entry exists

The previous schema entry answered a generic-library question: "should Effet
core ship schema?". The user corrected the frame. Effect Schema is foundational
in real Effect-TS applications, so an OCaml+Effet migration target needs a
runtime contract layer even if the API is not a one-to-one TypeScript port.

This pass asks a sharper question: what schema shape gives the best OCaml
developer experience while preserving the capabilities needed to migrate
schema-heavy Effect applications?

### Wider fixture

The new fixture is `scratch/schema_research/migration_fixture.ml`. It expands
the first-pass `person` fixture into a small schema-heavy app:

- branded `user_id`, `email`, and `flag_key`;
- nested `config` record with database, auth, users, features, and retry
  duration;
- tagged unions for `auth` and `event`;
- recursive `menu` tree;
- `retryAfter : string <-> int` transformation (`"500ms"` to `500`);
- optional fields and arrays;
- accumulation of many nested decode issues;
- effectful policy check requiring `env#feature_allowed`;
- JSON Schema metadata, sample values, and equality hooks.

This maps to a wider Effect-TS Schema slice: `Struct`, `optionalKey`, `Array`,
`Literals`/`Union`, tagged unions, `decodeTo`/transforms, `brand`, `suspend`,
`parseOptions: { errors: "all" }`, `toJsonSchemaDocument`, `toArbitrary`, and
`toEquivalence`.

### Refined hypothesis split

The original H-S0..H-S5 split was too coarse. The useful axes are:

| Axis | Options tested |
| --- | --- |
| Env placement | env inside schema/codec vs pure schema plus effectful decode policy |
| Public idiom | raw schema values vs module-first domain APIs |
| Product encoding | arity-specific record builders now, ppx later |
| Sum encoding | tagged-union combinator over OCaml variants |
| Nominality | private branded wrapper instead of TypeScript intersections |
| Recursion | lazy schema knot |
| Existing libraries | adapters remain useful, but cannot replace the migration contract |

### Second-pass candidates

| Candidate | File | Shape |
| --- | --- | --- |
| M-A | `m_a_pure_schema_effect_policy.ml` | pure `'a Schema.t`; effectful policies attach at decode boundary |
| M-B | `m_b_env_codec_record.ml` | env-tracking codec record, closest to H-S5 |
| M-C | `m_c_module_first.ml` | idiomatic domain modules wrapping M-A schemas |

Validation:

```text
nix develop -c dune build scratch/schema_research/
nix develop -c dune exec scratch/schema_research/migration_smoke.exe
migration support counts: m_a=11 m_b=10 m_c=11
```

LOC:

| File | LOC | Notes |
| --- | ---: | --- |
| `migration_fixture.ml` | 330 | domain model, JSON samples, support matrix |
| `m_a_pure_schema_effect_policy.ml` | 663 | schema DSL plus migrated app schemas |
| `m_b_env_codec_record.ml` | 75 | thin env-codec wrapper over M-A |
| `m_c_module_first.ml` | 101 | domain-module facade over M-A |
| `STUB_schema.mli` | 150 | proposed `effet-schema` contract |
| `BACKLOG_SCHEMA.md` | 54 | implementation slices |

### Negative tests

`neg_m_a_policy_env.ml`:

```text
File "scratch/schema_research/neg_m_a_policy_env.ml", lines 7-8, characters 2-40:
7 | ..M_a_pure_schema_effect_policy.decode_config_with_policy
8 |     Migration_fixture.sample_config_json
Error: This expression has type
         (< feature_allowed : string -> bool; .. >,
          [> `Decode of Fixture.issue list ], Migration_fixture.config)
         Effet.Effect.t
       but an expression was expected of type
         (<  >, [> `Decode of Fixture.issue list ], Migration_fixture.config)
         Effet.Effect.t
       The second object type has no method feature_allowed
```

Finding: M-A keeps V-R10 env-row inference even though `Schema.t` itself is
pure. The effectful policy introduces the env requirement exactly where it is
used.

`neg_m_a_brand_forge.ml`:

```text
File "scratch/schema_research/neg_m_a_brand_forge.ml", line 3, characters 38-47:
3 | let bad : Migration_fixture.user_id = "usr_123"
                                          ^^^^^^^^^
Error: This constant has type string but an expression was expected of type
         Migration_fixture.user_id =
           (string, Migration_fixture.user_id_brand)
           Migration_fixture.Brand.t
```

Finding: OCaml can enforce nominal identity more strongly than TypeScript
brands if the constructor is hidden behind a module boundary.

`neg_m_b_value_required.ml`:

```text
File "scratch/schema_research/neg_m_b_value_required.ml", line 5, characters 36-63:
5 |   M_b_env_codec_record.Codec.decode M_b_env_codec_record.config
                                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The value M_b_env_codec_record.config has type
         unit ->
         ('a, Schema_research.Migration_fixture.config)
         M_b_env_codec_record.Codec.t
       but an expression was expected of type
         ('b, 'c) M_b_env_codec_record.Codec.t
       Hint: Did you forget to provide () as argument?
```

Finding: putting env-polymorphic effects inside codec records causes an
ergonomic penalty. The lab had to expose `config ()`, not `config`, to avoid
weak env variables. This is a strong argument against carrying `'env` in the
schema value.

### Cross-tabulation

| Criterion | M-A pure schema + policy | M-B env codec record | M-C module-first facade |
| --- | ---: | ---: | ---: |
| Migration fixture support | 11 / 11 | 10 / 11 | 11 / 11 |
| Env-row policy support | yes | yes | yes |
| Plain reusable schema values | yes | no, thunked | yes |
| Branded value enforcement | yes | via M-A | yes |
| Nested record / all-error decode | yes | yes | yes |
| Tagged unions | yes | yes | yes |
| Recursive schemas | yes | yes | yes |
| JSON Schema / samples / equality | yes | yes | yes |
| Idiomatic OCaml call site | good | weaker (`codec ()`) | best |
| Implementation complexity | medium | medium plus weak-value hazards | low facade over M-A |

### Decision diary

#### V-Schema8 — Reverse the H-S0 recommendation for migration

H-S0 remains defensible for Effet core as a small effects library, but it is
not defensible for an Effect-TS migration target. Real Effect apps use Schema
as a contract layer for config, API boundaries, tagged events, transformations,
brands, test data, and documentation. The migration fixture proves that
external libraries alone do not give Effet-shaped env-row effect policies and
Cause integration as a coherent developer experience.

#### V-Schema9 — Choose pure schema values plus effectful decode policies

Adopt M-A as the implementation core. `Schema.t` should be pure and reusable:
decode, encode, JSON Schema, samples, and equality are properties of the data
shape. Effectful validation belongs at decode boundaries via
`decode_with_policy`. This keeps OCaml values generalisable and avoids the
weak-value/thunking penalty exposed by M-B.

#### V-Schema10 — Public usage should be module-first

Adopt M-C as the recommended user style. OCaml domain modules should expose
`type t`, `val schema`, `val decode`, `val encode`, and `val equal`. This is
more idiomatic than asking users to pipe everything through a large
TypeScript-shaped namespace. It also gives strong nominal boundaries for brands
without TypeScript-style intersection machinery.

#### V-Schema11 — Build a companion package, not core Effet

The implementation target is `packages/effet-schema/`, not `packages/effet/`.
Effet core should stay the effect runtime. `effet-schema` depends on Effet and
uses `Effect.t` for decode results, but schema should not add new constructors
to `Effect.t` or a second failure model.

#### V-Schema12 — Feature parity is capability parity, not API parity

Do not port Effect-TS Schema's public API one-to-one. OCaml should use:

- private modules and abstract constructors for brands;
- arity-specific record builders or generated code for products;
- normal variants plus tagged-union schemas for sums;
- lazy knots for recursion;
- polymorphic variant `` `Decode`` errors under `Cause.Fail`;
- object-row env only on effectful decode policies.

The capabilities match the relevant Effect-TS behaviours, but the surface is
OCaml-shaped.

#### V-Schema13 — PPX is a follow-up, not the foundation

Manual `record3`/`record4`/`record6` builders are acceptable for the v0 lab,
but they are not the final developer experience for large apps. A future
`ppx_effet_schema` can generate product/variant schema boilerplate after the
runtime contract is stable. Do not start with ppx: it would hide whether the
core representation is right.

#### V-Schema14 — Existing libraries are backends/adapters, not the answer

`data-encoding`, `decoders`, `ppx_yojson_conv`, `ppx_deriving_jsonschema`,
`atdgen`, and `repr` remain useful references or adapters. They do not remove
the need for an Effet-native contract layer because migration requires a single
story for typed errors, env-row effect policies, brands, transforms, recursion,
JSON Schema, and test/equality hooks. The package should offer adapters rather
than build Effet core around one external library.

### Contract and backlog

The proposed public contract is `scratch/schema_research/STUB_schema.mli`.
The implementation handoff is `scratch/schema_research/BACKLOG_SCHEMA.md`.

The first implementation slice should build `effet-schema` around:

```ocaml
type 'a Schema.t
val decode : 'a Schema.t -> json -> ('env, [> `Decode of issue list ], 'a) Effect.t
val decode_with_policy :
  'a Schema.t ->
  ('a -> ('env, [> `Decode of issue list ], 'a) Effect.t) ->
  json ->
  ('env, [> `Decode of issue list ], 'a) Effect.t
```

### Artifacts added

- `scratch/schema_research/migration_fixture.ml`
- `scratch/schema_research/m_a_pure_schema_effect_policy.ml`
- `scratch/schema_research/m_b_env_codec_record.ml`
- `scratch/schema_research/m_c_module_first.ml`
- `scratch/schema_research/migration_smoke.ml`
- `scratch/schema_research/neg_m_a_policy_env.ml`
- `scratch/schema_research/neg_m_a_brand_forge.ml`
- `scratch/schema_research/neg_m_b_value_required.ml`
- `scratch/schema_research/STUB_schema.mli`
- `scratch/schema_research/BACKLOG_SCHEMA.md`

### Current recommendation

Build `effet-schema` as a companion package. The core representation should be
pure `Schema.t` with derived codec/doc/test hooks. Effectful policies should be
separate decode-boundary functions that return Effet effects and therefore
preserve object-row env inference. The recommended user-facing style is
module-first, with domain modules wrapping schema values.

## effet-schema implementation — companion package v0

### Why this entry exists

The user reopened the schema work from research into implementation: create
`effet-schema`, implement the migration-grade subset justified by
V-Schema8..V-Schema14, and avoid adding schema machinery to Effet core.

### Implemented shape

The package lives under `packages/effet-schema/` with public library
`effet-schema` / module `Effet_schema`. It follows V-Schema9 and
V-Schema11:

- pure `'a Schema.t` values;
- `Schema.decode` returning `('env, [> `Decode of issue list ], 'a) Effect.t`;
- `Schema.decode_with_policy` for effectful env-row policy checks;
- structured `issue` paths;
- OCaml-first nominal values via domain-owned modules and `Schema.transform`;
- arrays, options, string enums, tagged unions, lazy recursion, refinement,
  transforms, and nominal schemas;
- arity-specific `record1`..`record6` product builders;
- JSON Schema metadata, samples, and equality hooks;
- a core `Json` module plus `JSON_ADAPTER` signature, with no hard Yojson
  dependency in the core package.

Production adjustments from `STUB_schema.mli`: record samples are optional
rather than required, and the public `Brand` / `Schema.brand` surface was
removed after the V-Brand research pass. Validated nominal types are now
represented by normal OCaml modules with abstract or private `type t` values
and schemas built from `Schema.transform`.

### Files added

- `packages/effet-schema/dune`
- `packages/effet-schema/effet_schema.mli`
- `packages/effet-schema/effet_schema.ml`
- `packages/effet-schema/README.md`
- `packages/effet-schema/test/dune`
- `packages/effet-schema/test/run.ml`
- `effet-schema.opam`

`dune-project` now declares the `effet-schema` package. No files under
`packages/effet/` or `packages/effet-otel/` were intentionally changed.

### Test fixture implemented

`packages/effet-schema/test/run.ml` ports the second-pass migration fixture to
the public package API:

- nominal `User_id.t`, `Email.t`, and `Flag_key.t` private string types;
- nested `config` with database/auth/users/features/retry duration;
- tagged `auth`, `event`, and recursive `menu`;
- `"500ms" <-> 500` transform;
- accumulation of nested decode issues;
- effectful policy requiring `env#feature_allowed`;
- `tap_error` / `catch` over ``Decode`` failures;
- JSON Schema title smoke check.

The test uses a tiny evaluator for the subset of `Effect.t` produced by
schema decoders. That keeps the package test independent of `eio_main` and
`alcotest`; runtime interpretation remains Effet core's responsibility.

### Verification

The implementation and interface type-check against the already-built Effet
interfaces:

```text
ocamlc -I _build/default/packages/effet/.effet.objs/byte \
  -I _build/default/packages/effet \
  -c packages/effet-schema/effet_schema.mli \
  -o /tmp/effet_schema.cmi

ocamlc -I /tmp \
  -I _build/default/packages/effet/.effet.objs/byte \
  -I _build/default/packages/effet \
  -c packages/effet-schema/effet_schema.ml \
  -o /tmp/effet_schema.cmo
```

Both commands exited 0.

The public-package migration test also type-checks against the new API:

```text
ocamlc -I /tmp \
  -I _build/default/packages/effet/.effet.objs/byte \
  -I _build/default/packages/effet \
  -c packages/effet-schema/test/run.ml \
  -o /tmp/effet_schema_test.cmo
```

This command exited 0.

Full Dune verification was blocked by the local shell environment, not by a
schema compile error:

```text
_opam/bin/dune build packages/effet-schema @runtest
Error: Library "eio" not found.
Error: Library "eio_main" not found.
Error: Library "alcotest" not found.
Error: Library "ppxlib" not found.
```

`nix develop -c dune build packages/effet-schema` required daemon access; when
run with approval, it produced no compiler output for more than a minute and
was terminated rather than treated as a successful verification.

### Follow-up

The next useful slice is an optional `effet-schema-yojson` adapter package or
sublibrary implementing `JSON_ADAPTER`. It should not be a core dependency
unless a downstream package proves that forcing Yojson is worth the weight.

## Effet schema nominality — public Brand vs OCaml newtypes

### Why this entry exists

After the first `effet-schema` implementation pass, the user asked whether a
public `Brand` abstraction is actually needed in OCaml. The earlier schema
research treated Effect-TS branding as a behaviour to preserve, but the lab did
not isolate whether TypeScript's brand API should survive in an OCaml-first
design.

This entry asks the narrower question: if Effect Schema had been designed in
OCaml from the start, how should nominal validated scalar types such as
`User_id.t`, `Email.t`, and `Flag_key.t` look?

### Capability target

The required capability is not a TypeScript-style `string & Brand<...>`.
The required capability is:

- decode a JSON string into a distinct validated type;
- reject invalid input at decode time with structured issues;
- prevent raw strings from being used as validated values;
- prevent two validated string-like domains from being mixed;
- encode the validated value back to JSON;
- keep equality, samples, and JSON Schema metadata available through
  `Schema.t`;
- keep the public API obvious to an OCaml user.

### Lab artifacts

The focused lab is `scratch/nominality_research/`.

Positive candidates:

| Candidate | File | Shape |
| --- | --- | --- |
| B-A | `b_a_public_brand.ml` | current generic phantom `('a, 'brand) Brand.t` |
| B-B | `b_b_abstract_newtype.ml` | ordinary abstract module/newtype, constructor hidden |
| B-C | `b_c_witness_newtype.ml` | functor helper that generates abstract newtype modules |
| B-D | `b_d_private_abbrev.ml` | `type t = private string` for scalar domains |

Positive validation:

```text
dune build scratch/nominality_research
dune exec scratch/nominality_research/runtime_smoke.exe
nominality scenarios passed
```

All four positive candidates decode, encode, compare, and preserve nominal use
sites in the happy path.

### Negative tests

`neg_abstract_newtype_plain_string.ml`:

```text
File "scratch/nominality_research/neg_abstract_newtype_plain_string.ml", line 4, characters 43-50:
4 | let bad : B_b_abstract_newtype.User_id.t = "usr_1"
                                               ^^^^^^^
Error: This constant has type string but an expression was expected of type
         B_b_abstract_newtype.User_id.t
```

Finding: an ordinary abstract module/newtype prevents raw string forgery.

`neg_abstract_newtype_mix.ml`:

```text
File "scratch/nominality_research/neg_abstract_newtype_mix.ml", line 6, characters 49-54:
6 |   | Ok email -> B_b_abstract_newtype.use_user_id email
                                                     ^^^^^
Error: The value email has type B_b_abstract_newtype.Email.t
       but an expression was expected of type B_b_abstract_newtype.User_id.t
```

Finding: two abstract domain modules remain nominally distinct even when both
are backed by strings.

`neg_witness_make_hidden.ml`:

```text
File "scratch/nominality_research/neg_witness_make_hidden.ml", line 4, characters 10-42:
4 | let bad = B_c_witness_newtype.User_id.make "usr_1"
              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: Unbound value B_c_witness_newtype.User_id.make
```

Finding: a helper/functor can reduce boilerplate while still hiding the
constructor. Users get `decode`, `schema`, `encode`, `value`, and
`equal`, not an unchecked `make`.

`neg_private_abbrev_plain_string.ml`:

```text
File "scratch/nominality_research/neg_private_abbrev_plain_string.ml", line 4, characters 41-48:
4 | let bad : B_d_private_abbrev.User_id.t = "usr_1"
                                             ^^^^^^^
Error: This constant has type string but an expression was expected of type
         B_d_private_abbrev.User_id.t
```

Finding: `type t = private string` prevents raw construction outside the
module while preserving cheap coercion from `t` to `string`.

`neg_private_abbrev_mix.ml`:

```text
File "scratch/nominality_research/neg_private_abbrev_mix.ml", line 6, characters 47-52:
6 |   | Ok email -> B_d_private_abbrev.use_user_id email
                                                   ^^^^^
Error: The value email has type B_d_private_abbrev.Email.t
       but an expression was expected of type B_d_private_abbrev.User_id.t
```

Finding: private string abbreviations are still nominal across modules.

`neg_public_brand_alias.ml`:

```text
exit 0
```

Finding: the public `Brand` alias shape compiles as an exposed representation:

```ocaml
type exposed =
  (string, B_a_public_brand.user_id_brand) B_a_public_brand.Brand.t

let representation_leaks (id : B_a_public_brand.user_id) : exposed = id
```

This is not unsound, but it is a public-surface smell. The domain type is no
longer just `User_id.t`; users can name and think in terms of a generic
`Brand.t` representation. That is TypeScript migration vocabulary leaking
into an OCaml API.

### Cross-tabulation

| Criterion | B-A public Brand | B-B abstract newtype | B-C helper functor | B-D private abbreviation |
| --- | ---: | ---: | ---: | ---: |
| Reject raw string | yes, if alias hidden | yes | yes | yes |
| Reject Email-as-UserId | yes | yes | yes | yes |
| Public API says `User_id.t` | weaker | yes | yes | yes |
| Generic reusable helper | yes | no | yes | no |
| Constructor hidden by default | only if module wraps it | yes | yes | yes |
| Cheap coercion to string | via `Brand.value` | via `value` | via `value` | via `:>` or `value` |
| Good for non-string carriers | yes | yes | with more functors | private only per carrier |
| OCaml-first idiom | medium | high | high for boilerplate | high for scalar IDs |

### Decision diary

#### V-Brand1 — Public `Brand` is not needed for OCaml nominality

OCaml already has the static capability TypeScript brands emulate. The lab
proves ordinary abstract modules reject raw strings and cross-domain mixing:
`neg_abstract_newtype_plain_string.ml` and `neg_abstract_newtype_mix.ml`
fail with the intended type errors. Therefore `Brand` is not required as a
public abstraction to achieve Effect Schema's branding capability.

#### V-Brand2 — Prefer domain-owned modules as the public shape

The OCaml-first surface should be:

```ocaml
module User_id : sig
  type t
  val schema : t Schema.t
  val decode : json -> ('env, [> error ], t) Effect.t
  val encode : t -> json
  val value : t -> string
  val equal : t -> t -> bool
end
```

This matches V-Schema10's module-first recommendation and avoids asking users
to reason about `(string, user_id_brand) Brand.t`. It is clearer at call
sites, stronger as an abstraction boundary, and more idiomatic than a
TypeScript-shaped brand namespace.

#### V-Brand3 — `Schema.transform` is the primitive, not `Schema.brand`

Validated nominal scalars are just bidirectional transformations from an
encoded carrier into a domain type. The primitive should remain
`Schema.transform`:

```ocaml
type t = User_id of string

let schema =
  Schema.transform Schema.string
    ~name:"user_id"
    ~decode:(fun s -> if valid s then Ok (User_id s) else Error [...])
    ~encode:(fun (User_id s) -> s)
    ~equal
```

`Schema.brand` adds no capability that `transform` plus an abstract module
does not already provide. If kept at all, it should be compatibility sugar or
an internal helper, not the recommended public path.

#### V-Brand4 — Private abbreviations are a useful scalar-specialized idiom

`type t = private string` is attractive for IDs, emails, keys, and other
string-backed scalar contracts. The lab proves it rejects construction and
mixing while allowing cheap upcast to `string`. The tradeoff is that it is
carrier-specific and less general than a normal variant wrapper. Recommended
guidance: use `type t = private string` for simple scalar domains when cheap
string interop matters; use an abstract variant/record newtype when the domain
may grow behaviour or change representation.

#### V-Brand5 — A helper functor can replace generic `Brand` ergonomics

B-C shows the useful part of `Brand` is boilerplate reduction, not the public
phantom type. A future `Schema.Newtype.Make_string` or documented local
functor can generate the module-first API while keeping constructors hidden.
This gives migration convenience without exposing a universal `Brand.t`
representation.

### Recommended API change

For an OCaml-first `effet-schema`, de-emphasize or remove the public
`Brand` module and `Schema.brand` from the main surface before the package is
treated as stable. Replace the concept in docs and examples with
domain-owned modules built from `Schema.transform`.

Concrete direction:

- keep `Schema.transform` as the core primitive;
- document `module User_id : sig type t ... end` as the nominality pattern;
- consider `Schema.Newtype.Make_string` as optional helper sugar;
- consider `type t = private string` examples for scalar IDs;
- if migration vocabulary is valuable, move `Brand` to a compatibility or
  advanced module rather than teaching it first.

Implementation follow-up: this recommendation was materialized immediately in
`packages/effet-schema/`. The public `Brand` module and `Schema.brand` were
removed, the package fixture now uses `User_id`, `Email`, and `Flag_key`
modules with `type t = private string`, and README examples teach
`Schema.transform` as the nominality primitive. The rejected public-brand
scratch candidate was removed from the maintained nominality lab after its compiler
evidence was recorded here.

### Meta-lesson

Branding is a TypeScript repair for a structural type system. OCaml does not
need that repair as a first-class public abstraction. The capability survives,
but the API should collapse into OCaml's module system: abstract types,
private abbreviations, and schema transforms.

## Effet-4n3 supervision research — nursery / supervisor surface (2.5h)

### Why this entry exists

Effet's earlier fiber research made the right negative call for a raw public
`Fiber.t`: escaped handles compile and become runtime traps. The review finding
behind Effet-4n3 points out the missing candidate: a first-class supervised
scope, closer to Trio/Eio's nursery idiom, where handles exist but are bound to
a lexical scope.

The pressure is no longer theoretical. `Resource.auto` now exists and is built
on `Effect.detach`. Refresh failures are either swallowed or sent to an
untyped side-effect callback. That is enough for a cache, but it is not a
structured failure-management surface.

### Goal

Reopen V-F2/V-F3 with compiler-backed evidence. Compare:

| Tag | Candidate |
|---|---|
| F-D | Scoped supervisor: explicit supervisor value, scope-bound child handles |
| F-E | Supervisor strategies: `One_for_one` / `One_for_all` and restart policy |
| F-F | Ambient nursery: nursery operations available inside a rank-2 scope |
| F-G | Detach-only baseline: current `detach` / `Resource.auto` style |

The required question is not "should Effet expose raw fibers?". That remains
answered by V-F2. The question is whether Effet needs a structured supervisor
surface that makes child failure observable without allowing handles to escape.

### Current implementation pressure

Current public concurrency surface:

- `Effect.par` / `all` / `for_each_par`: fail-fast collection combinators.
- `Effect.all_settled`: collects child exits as values.
- `Effect.for_each_par_bounded`: bounded fail-fast traversal.
- `Effect.detach`: runtime-owned unit fiber; child failures do not flow back.
- `Resource.auto`: seeds a cache, then uses `Effect.detach` for refresh loop.
  Refresh typed failures keep the old value and call `?on_error` when provided.

That is a useful base, but it has no parent-visible typed sink for detached
failures and no place to encode restart/failure policy.

### Lab

Artifacts live in `scratch/supervision_research/`.

| File | Purpose | Result |
|---|---|---|
| `f_d_supervisor_scope.ml` | Rank-2 scoped supervisor with `start` / `await` / `cancel` / `observe` / `check_threshold` | Compiles |
| `f_e_supervisor_strategies.ml` | Pure restart strategy model for `One_for_one` and `One_for_all` | Compiles |
| `f_f_ambient_nursery.ml` | Ambient nursery shape using the same scope-tag trick | Compiles |
| `f_g_detach_only.ml` | Baseline showing callback-only observability | Compiles |
| `runtime_smoke.ml` | Runtime fixtures across all candidates | Passes |
| `neg_d_handle_escape.ml` | F-D escaped child handle must fail to compile | Fails as expected |
| `neg_f_ambient_escape.ml` | F-F escaped ambient child handle must fail to compile | Fails as expected |

Positive validation:

~~~text
nix develop -c dune build scratch/supervision_research
nix develop -c dune exec scratch/supervision_research/runtime_smoke.exe
~~~

Observed output:

~~~text
F-D observe child failure: ok
F-D await child result: ok
F-D cancel finalizer: ok
F-D threshold failure: ok
F-D Resource.auto-shaped failure sink: ok
F-D nested supervisors: ok
F-E one-for-one: ok
F-E one-for-all: ok
F-F ambient nursery: ok
F-G swallowed: ok
F-G callback: ok
supervision research smoke tests passed
~~~

### Negative tests

`neg_d_handle_escape.ml` was temporarily added to the library's `(modules ...)`
list. The compiler rejected the escape:

~~~text
File "scratch/supervision_research/neg_d_handle_escape.ml", lines 14-16, characters 6-21:
14 | ......fun (type s) sup ->
15 |         let** (child : (s, [> `Boom ], int) child) = start sup (s_pure 1) in
16 |         s_pure child;
Error: This field value has type
         ('s, [> `Boom ] as 'a) supervisor ->
         ('s, 'b, 'a, ('s, 'a, int) child) scoped_t
       which is less general than
         's0. ('s0, 'c) supervisor -> ('s0, 'd, 'c, 'e) scoped_t
~~~

`neg_f_ambient_escape.ml` was then added instead. The compiler rejected that
escape too:

~~~text
File "scratch/supervision_research/neg_f_ambient_escape.ml", lines 13-15, characters 6-19:
13 | ......fun (type s) () ->
14 |         let* (child : (s, [> `Boom ], int) child) = start (pure 1) in
15 |         pure child;
Error: This field value has type
         unit -> ('s, 'a, 'b, ('s, [> `Boom ], int) child) scoped_t
       which is less general than 's0. unit -> ('s0, 'c, 'd, 'e) scoped_t
~~~

The failure mode matches V-F3's earlier rank-2 evidence: a child handle's type
mentions the locally quantified `'s`, so it cannot become the result of the
scope.

### Cross-tabulation

| Property | F-D scoped supervisor | F-E strategies | F-F ambient nursery | F-G detach-only |
|---|:---:|:---:|:---:|:---:|
| Child handle escape blocked statically | yes | n/a | yes | n/a |
| Await typed child result in scope | yes | n/a | yes | no |
| Observe child failure without failing parent by default | yes | yes | possible, not modelled fully | no typed sink |
| Cancel child and run finalizer | yes | n/a | not modelled | no handle |
| Supervisor threshold failure | yes | policy can express | not modelled | no |
| Nested supervisors compose | yes | n/a | yes by same scope trick | no supervisor |
| Resource.auto failure observability | yes | policy layer only | possible | callback/swallow only |
| Surface cost | medium | high if public first | medium-high | low |
| OCaml idiom fit | good: Eio nursery + rank-2 scope | mixed: OTP-like, not Eio-first | weaker: hidden ambient context | good but incomplete |

### Decision diary

#### V-Sv1 — Keep rejecting raw public `Fiber.t`

V-F2 still holds. A raw public handle can escape its parent switch, and the type
system will not stop it. Effet should not expose that trap. The new lab does not
revive raw `Fiber.t`; it revives scoped child handles whose phantom scope makes
escape a compile error (`f_d_supervisor_scope.ml`, `neg_d_handle_escape.ml`).

#### V-Sv2 — Adopt a scoped supervisor/nursery as the recommended direction

F-D is the winning shape. It gives the missing capability without violating
structured concurrency: `start` returns a child handle, `await` re-enters the
child's typed error channel, `cancel` terminates the child, and `observe` gives
the supervisor a failure sink that does not fail the parent by default. The
runtime smoke verifies all required fixtures, including finalizer execution on
cancellation and nested supervisor composition.

Recommended surface, sketched:

~~~ocaml
module Supervisor : sig
  type ('s, 'err, 'a) child
  type ('s, 'err) t

  type ('env, 'err, 'a) body = {
    run : 's. ('s, 'err) t -> ('s, 'env, 'err, 'a) Scope.t;
  }

  val scoped :
    ?max_failures:int ->
    ('env, 'err, 'a) body ->
    ('env, 'err, 'a) Effect.t

  val start :
    ('s, 'err) t ->
    ('s, 'env, 'err, 'a) Scope.t ->
    ('s, 'env, 'err, ('s, 'err, 'a) child) Scope.t

  val await : ('s, 'err, 'a) child -> ('s, 'env, 'err, 'a) Scope.t
  val cancel : ('s, 'err, 'a) child -> ('s, 'env, 'err, unit) Scope.t
  val failures : ('s, 'err) t -> ('s, 'env, 'err, 'err Cause.t list) Scope.t
end
~~~

Names can change. The invariant should not: child handles are only usable inside
the supervisor scope.

#### V-Sv3 — Do not lead with OTP restart strategies

F-E proves `One_for_one` / `One_for_all` restart policies are expressible, but
the strategy layer is orthogonal to the core handle/supervision question. If it
ships first, Effet would import a large OTP-shaped policy vocabulary before it
has a minimal nursery. Keep restart strategy as a second slice layered on F-D's
observable child outcomes.

#### V-Sv4 — Ambient nursery is not worth the hidden context

F-F blocks handle escape, but only because it keeps the same rank-2 scoped
effect type. Ambient access removes one explicit argument while adding hidden
state. That is a poor trade in Effet because the library already makes
requirements explicit through the `'env` object row. Prefer passing the
supervisor value explicitly inside `Supervisor.scoped`.

#### V-Sv5 — Detach-only is no longer sufficient

F-G captures the current weakness: detached failures have no typed sink. The
baseline can increment a callback, but it cannot offer `await`, `cancel`,
threshold policy, nested supervision, or a typed failure history. The
`Resource.auto`-shaped F-D fixture shows the better shape: the cache can keep
the last good value while the supervisor records `Cause.Fail (`Refresh)`.

#### V-Sv6 — Resource.auto should eventually move off raw `detach`

Do not rewrite `Resource.auto` in this research pass. The implementation task
should first land F-D's supervisor primitive, then rebuild `Resource.auto` so
its background refresh fiber is owned by an internal supervisor. Public API
options can stay conservative: preserve `?on_error` for compatibility, but add
an observable diagnostic sink through the supervisor machinery rather than
relying on callback-only reporting.

#### V-Sv7 — Failure model stays `Cause.t`

The lab reused a slim cause type with `Fail` / `Die` / `Interrupt`. The
production version should use Effet's existing `Cause.t` directly. Supervision
does not create a second failure model; it gives child causes an owner and an
inspection point.

#### V-Sv8 — First implementation slice

Create a follow-up implementation slice under the Effet-0jv remediation epic:

- add an internal/public `Supervisor` module with a scoped body record;
- add a scoped child effect type or nested `Supervisor.Scope.t` using the F-D
  rank-2 phantom tag;
- implement `start`, `await`, `cancel`, `failures`, and `max_failures`;
- prove handle escape rejection with a scratch negative or expect-test-style
  compiler fixture;
- add runtime tests for observable child failure, await, cancellation finalizer,
  threshold failure, nested supervisors, and Resource.auto-shaped refresh
  observability;
- leave restart strategies for a follow-up after the primitive lands.

### Recommendation

Adopt F-D: scoped supervisor/nursery with scope-bound child handles. Keep
`Effect.detach` for fire-and-forget compatibility, but stop treating
detach-only as Effet's final answer for long-lived background work. Defer
F-E restart strategies until the smaller supervisor primitive is real. Reject
F-F ambient nursery as a public shape because it keeps the type complexity while
hiding ownership.

### What we are deliberately not building in this entry

- No production `packages/effet/supervisor.ml` yet.
- No rewrite of `Resource.auto` yet.
- No restart-tree API yet.
- No public raw `Fiber.t`.

### Meta-lesson

The previous "no public fiber" conclusion was too broad. The real invariant is
"no escaping child handles." OCaml can enforce that with the same rank-2 scope
tag V-F3 already proved. The new evidence says Effet should expose supervised
concurrency, not raw fibers and not detach-only background work.


### Implementation follow-up — F-D adopted

The approved recommendation was materialized in the live Effet package.

Changed surface:

- Added `packages/effet/supervisor.{ml,mli}`.
- Added `Supervisor.scoped` with rank-2 body record.
- Added `Supervisor.Scope` operations: `pure`, `lift`, `fail`, `bind`,
  `start`, `await`, `cancel`, `failures`, `check`, and `yield`.
- Added supervisor GADT nodes to `Effect.t` and interpreted them in
  `Runtime` using Eio switches, promises, and Effet's existing `Cause.t`.
- Kept raw public `Fiber.t` absent.
- Kept `Effect.detach` for compatibility and fire-and-forget work.

Runtime behavior now covered by package tests:

- child failure is observable through `Supervisor.Scope.failures` without
  failing the parent by default;
- `await` rethrows the child's typed failure;
- `cancel` interrupts the child and protected finalizers run;
- `max_failures` plus `Scope.check` fails with `Supervisor_failed n`;
- nested supervisors compose without unwinding the outer scope.

Resource follow-up:

`Resource.auto` still returns a long-lived resource, so it cannot literally own
its refresh fiber through a lexical `Supervisor.scoped` whose scope closes
before the resource is used. Instead, it now records typed refresh failures in
the resource itself and exposes them through `Resource.failures`. The old
`?on_error` callback remains for compatibility, but refresh failures are no
longer callback-only evidence.

This slightly refines V-Sv6: lexical supervisors are the public structured
concurrency surface; long-lived returned resources use the same observable
`Cause.t` sink idea because their lifecycle is runtime-owned rather than
lexically scoped.

## Effet-j40 detach survival lab — delete-or-supervise

### Why this entry exists

Effet-4n3 adopted F-D supervised concurrency, which removed the need for a
public raw fiber handle. It did not answer whether `Effect.detach` should stay
as public fire-and-forget. The survival question is now narrower: can we delete
public `detach`, or should it survive with observable failures?

### Goal

Run a deletion-pressure lab after Supervisor adoption. Branch A removes public
`detach` and tries to keep a runtime-owned background primitive for
`Resource.auto`. Branch B keeps public `detach`, but makes detached failures
observable instead of silently swallowed.

### Lab

Artifacts live in `scratch/detach_survival/`.

| File | Purpose | Result |
|---|---|---|
| `branch_a_delete_public.ml` | Shows the viable delete-public-detach shape: make `Effect.t` abstract and keep daemon in `Private` | Compiles |
| `branch_b_hook.ml` | Keeps public `Detach`, preserves the child error row, and reports failures to a runtime hook | Compiles |
| `neg_a_hidden_constructor.ml` | Proves an exact public GADT cannot hide an extra internal daemon constructor | Fails as expected |
| `runtime_smoke.ml` | Runs the Branch B observable-failure fixture | Passes |

Positive validation:

~~~text
nix develop -c dune build scratch/detach_survival
nix develop -c dune exec scratch/detach_survival/runtime_smoke.exe
~~~

Observed output:

~~~text
Branch B hook observes detached failure: ok
detach survival smoke tests passed
~~~

### Negative test

`neg_a_hidden_constructor.ml` was temporarily added to the scratch library
module list. The compiler rejected the attempted hidden constructor:

~~~text
warning: Git tree '/home/ribelo/projects/ribelo/ocaml/Effet' is dirty
File "scratch/detach_survival/neg_a_hidden_constructor.ml", lines 16-22, characters 6-3:
16 | ......struct
17 |   type ('env, 'err, 'a) t =
18 |     | Pure : 'a -> (_, _, 'a) t
19 |     | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t
20 |
21 |   let pure value = Pure value
22 | end
Error: Signature mismatch:
       ...
       Type declarations do not match:
         type ('env, 'err, 'a) t =
             Pure : 'a -> ('b, 'c, 'a) t
           | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t
       is not included in
         type ('env, 'err, 'a) t = Pure : 'a -> ('b, 'c, 'a) t
       An extra constructor, Daemon, is provided in the first declaration.
       File "scratch/detach_survival/neg_a_hidden_constructor.ml", line 14, characters 2-53:
         Expected declaration
       File "scratch/detach_survival/neg_a_hidden_constructor.ml", lines 17-19, characters 2-59:
         Actual declaration
~~~

This is the key Branch A result. With the current public-GADT API, an internal
daemon AST node cannot be hidden while the signature exposes an exact variant
type. Branch A is possible only if `Effect.t` becomes abstract and all
constructors move behind smart constructors. That is a broad API shift, not a
surgical deletion of `detach`.

### Decision diary

#### V-RDv1 — Public `detach` survives for now

Decision: keep `Effect.detach` public. Rationale: deletion is not locally
cheap under the current public-GADT surface. The lab shows the only clean hidden
daemon shape requires abstracting `Effect.t` itself
(`branch_a_delete_public.ml`), while the negative test proves the current
exact-variant signature cannot hide the daemon constructor. Supervisor covers
scoped child ownership, but it does not replace runtime-owned work that
intentionally outlives the current effect body and is bounded by the runtime
switch.

#### V-RDv2 — Remove error erasure from `detach`

Decision: change `detach` from `('env, _, unit) Effect.t -> ('env, 'err, unit)
Effect.t` to `('env, 'err, unit) Effect.t -> ('env, 'err, unit) Effect.t`.
Rationale: a detached child failure still does not fail the parent, but the
program type should not pretend the child has no typed failure channel. The
Branch B lab locks this shape with an ascribed value whose error row includes
`Detached_boom`.

#### V-RDv3 — Add a runtime detached-failure hook

Decision: add `Runtime.create ~on_detached_failure`. Rationale: detached
failures must have an owner. The runtime owns detached fibers, so the runtime is
the right observation point. The production hook uses `Obj.t Cause.t`, not
`'err Cause.t`, because `Catch` and similar local interpretation can run a
detached subeffect under an error row different from the runtime's outer error
row. The cause tree shape is preserved; only typed payloads are existential at
the runtime boundary.

#### V-RDv4 — Resource.auto stays on runtime-owned detach semantics

Decision: keep `Resource.auto` on the runtime-owned daemon path, with
`Resource.failures` as its typed resource-local sink. Rationale: a lexical
`Supervisor.scoped` cannot directly own a background refresh loop for a
resource that is returned and used after the constructor effect completes. The
right distinction is now clear: `Supervisor` for lexical child lifecycles,
`detach` for runtime-owned daemons, and `Resource.failures` /
`on_detached_failure` for observability.

### Implementation follow-up in the same session

The Branch B decision was materialized immediately:

- `Effect.Detach` and `Effect.detach` now preserve the child error row.
- `Runtime.create` accepts `?on_detached_failure:(Obj.t Cause.t -> unit)`.
- Detached daemon failures call the hook and still do not fail the parent.
- A package test verifies parent success plus hook-observed
  `Cause.Fail Detached_boom`.
- The full gate passed: `nix develop -c dune runtest --force`.

### What remains deliberately open

A future major API cleanup may still abstract `Effect.t` and hide all raw
constructors. That would reopen Branch A on better terms. This entry rejects a
surgical public-detach deletion under the current public-GADT API.

### Global-optimum correction — public detach removed

The previous V-RDv1/V-RDv3 result was a local optimum: it treated the current
public-GADT shape as a hard constraint and therefore kept `Effect.detach` with
an observable runtime hook. The design bar was raised: churn is not a reason to
keep a flawed public primitive before the API hardens. Under that criterion,
the decision flips.

#### V-RDv5 — Make `Effect.t` abstract

Decision: `Effect.t` is now abstract in `effect.mli`. The interpreter view
moved under `Effect.Private.view`, and the runtime pattern-matches on that
private view. Rationale: an exact public GADT prevents internal-only runtime
nodes. The earlier negative test already proved this: adding a daemon
constructor to the implementation while hiding it from the exact public variant
signature is rejected by the compiler. Abstraction is the right fix because it
lets Effet keep internal AST nodes without accidentally promoting them into the
public API.

#### V-RDv6 — Remove public `Effect.detach`

Decision: public `Effect.detach` is removed. Public child lifecycles go
through `Supervisor.scoped`, `par`, `all`, `all_settled`, `race`, and
bounded traversal. Rationale: public fire-and-forget has no lexical owner, no
await/cancel surface, and awkward typed-failure semantics. Supervisor is the
structured public answer. Runtime-owned daemon work remains possible, but it is
not a general user-facing effect constructor.

#### V-RDv7 — Keep daemon as an internal effect node only

Decision: replace the public `Detach` node with internal `Daemon`, exposed
only through `Effect.Private.daemon` for package-internal modules such as
`Resource`. Rationale: `Resource.auto` returns a long-lived resource whose
refresh loop is owned by the runtime switch rather than by a lexical supervisor
scope. That lifecycle exists, but it is a library/runtime implementation
detail, not a public concurrency abstraction.

#### V-RDv8 — Remove `on_detached_failure`

Decision: remove the runtime `on_detached_failure` hook introduced by the
local-optimum pass. Rationale: once public `detach` is gone, the hook no
longer has a general public role. `Resource.auto` already records typed
refresh failures in `Resource.failures`; unexpected daemon defects remain
runtime-internal defects until a concrete diagnostics surface is designed.

Implementation update:

- `packages/effet/effect.mli` now exposes `type ('env, 'err, 'a) t` abstractly.
- `Effect.Private.view` gives `Runtime` the interpreter-facing AST view.
- `Effect.Private.daemon` is the internal runtime-owned background primitive.
- `Resource.auto` uses `Effect.Private.daemon` instead of public `Effect.detach`.
- Public tests now use `Supervisor.scoped` for child-work observability and
  span inheritance.
- The full project gate passed with this shape: `nix develop -c dune runtest
  --force`.

This supersedes V-RDv1 through V-RDv4. The durable decision is: no public
`detach`; structured public concurrency only.

## Effet-6s5 Cause research — structured Cause algebra

### Why this entry exists

Slim Cause / Exit was explicitly adopted on probation. The original decision
kept only `Fail`, `Die`, `Interrupt`, and binary `Both` because Effet had
only the first parallel-failure hole to close. Since then, supervision,
runtime-owned resources, scoped finalizers, and OTel flattening made the
missing structure concrete.

The design question is now whether public `Cause.t` should harden as the slim
shape, or whether this is the last practical moment to replace `Both` with a
diagnostic algebra that preserves concurrency, sequencing, and suppressed
finalizer failures.

### Goal

Research Effet-6s5 for a 2h time budget. Build a lab under
`scratch/cause_research/` comparing today's `Both` shape with a structured
algebra, run the same fixtures through both, verify the typed-failure boundary,
and decide whether to keep `Both`, adopt the structured algebra, or reopen for
more research.

### Context read

Relevant prior decisions:

- Slim Cause / Exit adopted `Both` only as "enough for the current parallel
  hole."
- `Effect.catch` catches only a single typed `Cause.Fail err`; it must not
  catch `Die`, `Interrupt`, or compound causes.
- Scoped finalizers are now Effet-owned, not delegated to raw Eio switch
  finalizers.
- Supervision stores child failures as `Cause.t`; it did not create a second
  failure model.
- Public `detach` was removed; structured public concurrency now goes through
  `Supervisor`, `par`, `all`, `race`, and traversal combinators.
- OTel currently flattens `Cause.Both` into one exception event per leaf, which
  keeps leaf count but erases cause relation.

The Effect-smol reference Cause is a flat list of reasons with optional
annotations. That is useful evidence, but not a direct target for Effet. The
open question here is relational structure between reasons, and OCaml can model
that directly with variants.

### Lab

Artifacts live in `scratch/cause_research/`.

| File | Purpose | Result |
|---|---|---|
| `fixture.ml` | Shared fixture functor over a Cause signature | Compiles |
| `current_both.ml` | Today's algebra: `Fail / Die / Interrupt / Both` | Compiles |
| `proposed_structured.ml` | Proposed algebra: `Sequential / Concurrent / Suppressed` plus interrupt id | Compiles |
| `runtime_smoke.ml` | Runs identical fixture suite through both candidates | Passes |
| `current_runtime_probe.ml` | Probes live Effet behavior for finalizer and race causes | Passes |
| `README.md` | Lab navigation and commands | Written |

Validation commands:

~~~text
nix develop -c dune build scratch/cause_research
nix develop -c dune exec scratch/cause_research/current_runtime_probe.exe
nix develop -c dune exec scratch/cause_research/runtime_smoke.exe
~~~

Observed live-runtime output:

~~~text
scoped body+release failure: Fail(Body)
race two failures: Both(Fail(A), Fail(B))
~~~

Observed candidate comparison:

~~~text
== current Both ==
par_two_failures: Both(Fail(First), Fail(Second))
  event path=exception msg=Fail:First
  event path=exception msg=Fail:Second
all_failure_plus_sibling_finalizer: Both(Both(Fail(First), Fail(Sibling)), Fail(Finalizer))
  event path=exception msg=Fail:First
  event path=exception msg=Fail:Sibling
  event path=exception msg=Fail:Finalizer
nested_scoped_finalizer_during_failure: Both(Both(Fail(Body), Fail(Finalizer)), Die(outer finalizer defect))
  event path=exception msg=Fail:Body
  event path=exception msg=Fail:Finalizer
  event path=exception msg=Die:outer finalizer defect
sequential_tap_rethrow: Both(Fail(Typed), Fail(Tap))
  event path=exception msg=Fail:Typed
  event path=exception msg=Fail:Tap
== structured ==
par_two_failures: Concurrent[Fail(First); Fail(Second)]
  event path=cause.concurrent.0 msg=Fail:First
  event path=cause.concurrent.1 msg=Fail:Second
all_failure_plus_sibling_finalizer: Suppressed{primary=Concurrent[Fail(First); Fail(Sibling)]; finalizer=Fail(Finalizer)}
  event path=cause.primary.concurrent.0 msg=Fail:First
  event path=cause.primary.concurrent.1 msg=Fail:Sibling
  event path=cause.suppressed_finalizer msg=Fail:Finalizer
nested_scoped_finalizer_during_failure: Suppressed{primary=Suppressed{primary=Fail(Body); finalizer=Fail(Finalizer)}; finalizer=Die(outer finalizer defect)}
  event path=cause.primary.primary msg=Fail:Body
  event path=cause.primary.suppressed_finalizer msg=Fail:Finalizer
  event path=cause.suppressed_finalizer msg=Die:outer finalizer defect
sequential_tap_rethrow: Sequential[Fail(Typed); Fail(Tap)]
  event path=cause.seq.0 msg=Fail:Typed
  event path=cause.seq.1 msg=Fail:Tap
cause research smoke tests passed
~~~

### Cross-tabulation

| Property | Current Both | Structured algebra |
|---|---:|---:|
| Single typed `Fail` remains catchable | yes | yes |
| Compound cause remains outside `catch` | yes | yes |
| Multiple leaf failures preserved | partial | yes |
| Parallel vs sequential relation preserved | no | yes |
| Finalizer failure marked as suppressed | no | yes |
| Nested suppression chain preserved | no | yes |
| Interrupt can name the interrupting scope/fiber | no | yes, optional id |
| OTel flattening can preserve event role/path | no | yes |
| Pattern matching is idiomatic OCaml | okay | good |
| Implementation churn | low | medium-high |

### Decision diary

#### V-RCv1 — Adopt structured Cause algebra

Decision: replace binary `Both` with a structured algebra. The lab shows that
`Both` preserves at most leaf count. It cannot say whether two failures are
parallel children, sequential failures, or a primary failure plus a suppressed
release failure. The structured candidate preserves that relation directly in
the value: `Concurrent [...]`, `Sequential [...]`, and `Suppressed { primary;
finalizer }`.

#### V-RCv2 — Keep `Effect.catch` as a single typed-Fail boundary

Decision: `catch` semantics do not change. It catches only a top-level
`Fail err`. The fixture verifies both candidates catch a single typed fail and
do not catch a compound concurrent cause. This keeps the typed error channel
honest: diagnostics may be structured, but a handler still receives an `'err`,
not a cause tree.

#### V-RCv3 — Finalizer failures must not be swallowed

Decision: release/finalizer failures should become `Suppressed` causes. The
live runtime probe shows today's implementation returns only `Fail(Body)` when
the body and release both fail, so the release failure is lost completely. That
is worse than slim `Both`. The implementation follow-up should run finalizers
under cause capture and combine body/release as `Suppressed { primary; finalizer
}`.

#### V-RCv4 — Parallel collection should report `Concurrent`

Decision: `race`, `par`, `all`, and `for_each_par` should use
`Concurrent` for multiple observed child failures. Fail-fast operators may
still only observe failures that happen before cancellation wins; the algebra
does not require waiting for all children. When multiple causes are observed,
nesting them into `Both` is unnecessary and loses the operator semantics.

#### V-RCv5 — Add optional interruption identity

Decision: change `Interrupt` to carry an optional id. The proposed lab used
`Interrupt of interrupt_id option`; production should make `interrupt_id`
opaque, not a public string. This preserves today's ability to say "cancelled"
while giving supervisors, races, and scopes a future place to say who triggered
the interruption.

#### V-RCv6 — OTel flattening should emit role-aware exception events

Decision: flattening a cause for OTel should keep a path/kind attribute, not
only one exception event per leaf. The structured fixture emits paths such as
`cause.primary.concurrent.0` and `cause.suppressed_finalizer`. That gives
diagnostic consumers enough structure without requiring OTel to understand
Effet's ADT.

#### V-RCv7 — `Exit.to_result` stays narrow

Decision: `Exit.to_result` remains valid only for `Ok v` and single
`Error (Fail err)`. `Die`, `Interrupt _`, `Sequential`, `Concurrent`,
and `Suppressed` have no faithful OCaml `result` representation. This is the
same contract as the slim model, with more compound constructors.

#### V-RCv8 — Suggested production shape

Recommended public shape:

~~~ocaml
type interrupt_id

type 'err t =
  | Fail of 'err
  | Die of exn * Printexc.raw_backtrace option
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Suppressed of { primary : 'err t; finalizer : 'err t }
~~~

Keep smart constructors for the common cases. Add helpers to flatten leaves for
logging/OTel, but keep the tree as the source of truth. Lists should be
non-empty by construction through smart constructors where practical; the raw
variant can still exist because an empty `Concurrent []` is not catastrophic,
only unhelpful.

#### V-RCv9 — Implementation slice

Follow-up implementation should update:

- `Cause.t`, `Cause.equal`, `Cause.pp`, and smart constructors;
- `Exit.to_result` and existing tests that match `Both`;
- `Runtime.cause_of_exn` for `Eio.Exn.Multiple` to produce `Concurrent`;
- `race` all-failures path to accumulate `Concurrent`;
- `par`, `all`, `for_each_par`, and bounded traversal where multiple
  failures are observed;
- `run_finalizers`, `Acquire_release`, `Scoped`, and supervisor child
  cleanup to report `Suppressed` instead of swallowing release failures;
- tracer status rendering and exception event flattening to preserve role/path;
- `packages/effet-otel` tests if they assert exception flattening.

### Recommendation

Adopt the structured Cause algebra now. This is an API correctness decision, not
a convenience decision. `Both` was acceptable when the only requirement was
"there were two failures." It is no longer acceptable now that Effet owns
scoped finalizers, supervision, concurrent operators, and trace diagnostics.

### What we are deliberately not doing in this entry

- No production `packages/effet/` change yet.
- No `packages/effet-otel/` change yet.
- No attempt to reproduce the whole Effect-smol Cause API. Effet needs the
  capability, not the TS surface.
- No restart/supervision policy change. Supervision remains a consumer of
  `Cause.t`, not a separate failure model.

### Implementation follow-up - structured Cause adopted

The approved V-RCv recommendation was materialized in the live Effet package.

Changed surface:

- Cause.t now exposes Fail, Die of exn * raw_backtrace option, Interrupt of interrupt_id option, Sequential, Concurrent, and Suppressed.
- interrupt_id is opaque. Public code can still use Cause.interrupt (Interrupt None); runtime-owned identities can be added without changing the variant shape.
- Cause.both and Both were removed from the live API.
- Effect.acquire_release release effects now share the acquire/body error channel so typed release failures can be represented honestly in the resulting cause.

Runtime behavior now covered by tests:

- race all-failures returns Concurrent [Fail first; Fail second].
- Acquire_release body failure plus release failure returns Suppressed { primary; finalizer }.
- catch still catches only a top-level Fail.
- cancellation remains outside the typed error channel as Interrupt None.
- OTel-style exception events include effet.cause.path, for example cause.concurrent.0 and cause.concurrent.1.

Validation after implementation:

~~~text
nix develop -c dune build scratch/cause_research
nix develop -c dune exec scratch/cause_research/current_runtime_probe.exe
nix develop -c dune exec scratch/cause_research/runtime_smoke.exe
nix develop -c dune runtest --force
~~~

Updated probe output:

~~~text
scoped body+release failure: Suppressed{primary=Fail(Body); finalizer=Fail(Release)}
race two failures: Concurrent[Fail(A); Fail(B)]
~~~

The durable decision is now implemented: Effet uses structured causes as the runtime diagnostic algebra; Exit.to_result remains narrow; typed recovery still goes through Effect.catch over a single Fail.

## Effet-0u8 provide survival lab - dynamic env substitution

### Why this entry exists

Review 2 put Effect.provide on probation. V-R10 kept provide as the single Layer-shaped primitive, but the concrete justification was still mostly asserted: test isolation, dynamic sub-system substitution, and sandboxing.

This entry tests whether those examples actually need dynamic env substitution, or whether ordinary OCaml parameter passing is clearer and equally capable.

### Goal

Run a survival lab for Effect.provide with no time budget. Build three with-provide / without-provide pairs, run identical behaviour, compare LOC, inferred signatures, error quality, and whether provide has a property the ordinary OCaml version lacks.

### Lab

Artifacts live in scratch/provide_survival/.

| Fixture | With provide | Without provide | Result |
|---|---|---|---|
| Scoped service factory | with_provide_scoped_factory.ml | without_provide_scoped_factory.ml | identical behaviour |
| Test-local mock injection | with_provide_mock_injection.ml | without_provide_mock_injection.ml | identical behaviour |
| Sandboxed subsystem | with_provide_sandbox.ml | without_provide_sandbox.ml | identical behaviour |
| Shared services | services.ml | services.ml | compiles |
| Smoke runner | runtime_smoke.ml | runtime_smoke.ml | passes |

Validation:

~~~text
nix develop -c dune build scratch/provide_survival
nix develop -c dune exec scratch/provide_survival/runtime_smoke.exe
~~~

Observed output:

~~~text
provide survival smoke tests passed
~~~

### LOC comparison

~~~text
  48 scratch/provide_survival/with_provide_mock_injection.ml
  35 scratch/provide_survival/with_provide_sandbox.ml
  28 scratch/provide_survival/with_provide_scoped_factory.ml
  37 scratch/provide_survival/without_provide_mock_injection.ml
  28 scratch/provide_survival/without_provide_sandbox.ml
  27 scratch/provide_survival/without_provide_scoped_factory.ml
~~~

Summary:

| Fixture | With provide LOC | Without provide LOC | Delta |
|---|---:|---:|---:|
| Scoped service factory | 28 | 27 | without is -1 |
| Mock injection | 48 | 37 | without is -11 |
| Sandbox | 35 | 28 | without is -7 |

The without-provide versions contain zero Effect.provide calls. They pass runtime envs directly at Runtime.run boundaries and pass services as ordinary values inside the program.

### Signature evidence

The module ascriptions lock the important shapes.

With provide:

~~~ocaml
val child : (< db : db >, string, string) Effect.t
val read_user : (< audit : audit; db : db >, string, string) Effect.t
~~~

Without provide:

~~~ocaml
val child : db -> ('env, 'err, string) Effect.t
val read_user : db -> (< audit : audit >, string, string) Effect.t
val program : db -> (< secret : secret >, string, string * string) Effect.t
~~~

The without-provide shape makes service substitution ordinary function application. It also keeps the child effect's ambient env smaller: a child that receives db as an argument no longer needs a db method in env.

### Negative probes

neg_with_provide_missing_db.ml was temporarily added as an executable. The compiler rejected running a db-requiring child under an empty env:

~~~text
File "scratch/provide_survival/neg_with_provide_missing_db.ml", line 10, characters 42-54:
10 |   Services.run With_provide_sandbox.child (object end)
                                               ^^^^^^^^^^^^
Error: This expression has type <  > but an expression was expected of type
         < db : Services.db >
       The first object type has no method db
~~~

neg_without_provide_missing_arg.ml was temporarily added instead. The compiler rejected treating a service-parameterized child function as an already-built effect:

~~~text
File "scratch/provide_survival/neg_without_provide_missing_arg.ml", line 10, characters 2-31:
10 |   Without_provide_sandbox.child
       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The value Without_provide_sandbox.child has type
         Provide_survival.Services.db -> ('a, 'b, string) Effect.t
       but an expression was expected of type (<  >, string, string) Effect.t
~~~

Both errors are good. The provide error is an object-row missing-method error. The without-provide error is a direct missing-argument shape: db -> Effect.t is not Effect.t. The latter is more local for ordinary OCaml programmers.

### Cross-tabulation

| Criterion | With provide | Without provide |
|---|---|---|
| Scoped factory | Works, but wraps child env with object | Works by passing db to child |
| Mock injection | Works, but fake env must reconstruct every needed method | Works by passing fake db; real env still supplies audit |
| Sandbox fewer capabilities | Works by providing smaller env | Works by passing only allowed values |
| LOC | Higher or equal in all three fixtures | Lower or equal in all three fixtures |
| Missing service error | Good object-row error | Good direct function-shape error |
| Unique capability | None found | n/a |
| Runtime AST node needed | Yes | No |

### Decision diary

#### V-RPv1 - Scoped service factories do not need provide

Decision: scoped factories are clearer as ordinary bind plus parameter passing. The with-provide version builds a db env object solely to run one child. The without-provide version passes db to child directly and is one line shorter. No lifecycle property is lost: acquire_release still opens and closes db inside Effect.scoped.

#### V-RPv2 - Mock injection is stronger without provide

Decision: test-local substitution does not justify provide. The with-provide version must build a fake env containing fake db and the real audit service. The without-provide version passes fake db as a normal argument while the real runtime env keeps audit. It is 11 LOC shorter and expresses the substitution at the call site.

#### V-RPv3 - Sandbox is a value boundary, not an env substitution boundary

Decision: sandboxed children do not need dynamic env replacement. Passing only db to child gives it no env-level secret requirement. This is at least as clear as constructing a smaller child env through provide, and it avoids a public AST node.

#### V-RPv4 - Missing-service diagnostics do not favour provide

Decision: both shapes fail statically. Provide gives a row error: object type lacks method db. Ordinary parameter passing gives a function-shape error: db -> Effect.t is not Effect.t. The second error is more direct when the design is service-as-argument.

#### V-RPv5 - Effect.provide is unearned

Decision: delete Effect.provide from the public API and interpreter. The survival lab found no fixture where provide has a property ordinary OCaml lacks. It adds a GADT constructor, a public operator, and a runtime case to recover behaviour already expressible through function arguments and Runtime.run env selection.

### Recommendation

Delete Effect.provide as unearned. Keep the object-row env channel from V-R10, but use it at runtime boundaries and for leaf requirements. For mid-tree service substitution, prefer ordinary OCaml parameter passing. If a future use case requires dynamic replacement that cannot be expressed this way, it should reopen with a concrete lab fixture.

### What we are deliberately not doing in this entry

- No production deletion yet.
- No change to packages/effet in this research pass.
- No Layer revival. The lab strengthens the no-Layer decision rather than weakening it.

### Implementation follow-up - 2026-05-20

The recommendation above was materialized in the live library. Effect.provide is removed
from the public interface, the internal GADT, Effect.Private.view, and the Runtime
interpreter. The old test asserting mid-tree env substitution was deleted because that
behaviour is no longer an API promise.

The schema test helper previously interpreted Effect.Private.Provide in its tiny local
evaluator. That case is gone as well; schema effect tests continue to use the remaining
pure/sync/map/bind/catch/tap_error subset.

scratch/provide_survival was converted from a comparison lab into a post-deletion
survival proof. The with-provide candidate modules and the stale with-provide negative
probe were removed with the API. The remaining modules compile the three recommended
ordinary-OCaml replacements:

- without_provide_scoped_factory.ml
- without_provide_mock_injection.ml
- without_provide_sandbox.ml

Verification:

~~~text
nix develop -c dune build scratch/provide_survival
nix develop -c dune exec scratch/provide_survival/runtime_smoke.exe
post-provide survival smoke tests passed

nix develop -c dune runtest --force
effet-schema tests passed
effet-otel: 19 tests run
effet: 79 tests run
~~~

This closes the V-RPv5 recommendation: mid-tree dependency substitution is ordinary
OCaml parameter passing, not a public Effet runtime primitive. If a future use case wants
dynamic env replacement, it needs a new lab fixture that ordinary functions cannot
express.

## Effet-0u8 Layer survival lab - merge_explicit and GADT presence sets

### Why this entry exists

Review 1 finding #2 correctly identified an incompleteness in V-R2. The earlier Layer rejection argued from the absence of type-level object-row intersection, then dismissed phantom lists, Hmap, and restricted merge. It did not test two missing candidates:

- explicit output merging with combine;
- GADT presence sets with hidden lookup witnesses.

This entry reopens V-R2 against those candidates.

### Goal

Within a 3h budget, build scratch/layer_research/ with the shared-Clock fixture:

- Db layer needs Clock.
- Http layer needs Clock and Log.
- App merges Db and Http.
- Boot supplies Clock and Log.
- Missing Clock or Log must fail statically.
- Method-name collisions or duplicate services must surface clearly.

Compare each candidate against the current no-Layer answer: ordinary OCaml service factories, scoped acquire/release, and bind.

### Lab artifacts

Files:

- scratch/layer_research/services.ml
- scratch/layer_research/merge_explicit.ml
- scratch/layer_research/gadt_presence_set.ml
- scratch/layer_research/no_layer_baseline.ml
- scratch/layer_research/runtime_smoke.ml
- scratch/layer_research/neg_merge_missing_clock.ml
- scratch/layer_research/neg_merge_collision.ml
- scratch/layer_research/neg_gadt_missing_clock.ml
- scratch/layer_research/neg_no_layer_missing_log.ml

Positive validation:

~~~text
nix develop -c dune build scratch/layer_research
nix develop -c dune exec scratch/layer_research/runtime_smoke.exe
layer research smoke tests passed
~~~

LOC:

~~~text
  115 scratch/layer_research/gadt_presence_set.ml
   74 scratch/layer_research/merge_explicit.ml
   37 scratch/layer_research/no_layer_baseline.ml
~~~

### Candidate A - Layer.merge_explicit

Shape tested:

~~~ocaml
module Layer : sig
  type ('rin, 'err, 'out) t = ('rin, 'err, 'out) Effect.t

  val scoped :
    acquire:('rin, 'err, 'a) Effect.t ->
    release:('a -> ('rin, 'err, unit) Effect.t) ->
    ('rin, 'err, 'a) t

  val merge :
    combine:('a -> 'b -> 'out) ->
    ('rin, 'err, 'a) t ->
    ('rin, 'err, 'b) t ->
    ('rin, 'err, 'out) t

  val use :
    ('rin, 'err, 'out) t ->
    ('out -> ('rin, 'err, 'a) Effect.t) ->
    ('rin, 'err, 'a) Effect.t
end
~~~

The important signature lock:

~~~ocaml
val db_layer : unit -> (< clock : clock; .. >, string, db) Effect.t

val http_layer :
  unit -> (< clock : clock; log : log; .. >, string, http) Effect.t

val app_layer :
  unit ->
  (< clock : clock; log : log; .. >, string, < db : db; http : http >) Effect.t
~~~

Finding: explicit combine solves the output-intersection problem. The input side also works: OCaml row unification widens Db's <clock; ..> requirement to the merged app's <clock; log; ..> requirement.

But reusable layer values need thunks. Without eta/thunking, the compiler monomorphised the layer value at its later app-layer use, and the signature lock failed:

~~~text
Values do not match:
  val db_layer : (< clock : clock; log : log >, string, db) Layer.t
is not included in
  val db_layer : (< clock : clock; .. >, string, db) Layer.t
The second object type has no method log
~~~

So the viable surface is not just "a first-class Layer.t value"; in practical OCaml it is "a function returning a fresh Layer.t" when open object rows must remain reusable.

### Candidate B - GADT presence-set with hidden witnesses

Shape tested:

~~~ocaml
type _ cap = Clock : clock cap | Log : log cap | Db : db cap | Http : http cap

type _ env =
  | Nil : unit env
  | Cons : 'a cap * 'a * 'rest env -> ('a * 'rest) env

type (_, _) has =
  | Here : ('a * 'rest, 'a) has
  | There : ('rest, 'a) has -> ('b * 'rest, 'a) has

type ('need, 'provide, 'err) layer =
  'need env -> (< >, 'err, 'provide env) Effect.t
~~~

The service constructors hide the lookup witnesses for the fixture:

~~~ocaml
val db_layer : (clock * 'rest, db * unit, string) layer

val http_layer :
  (clock * (log * 'rest), http * unit, string) layer

val app_layer :
  (clock * (log * 'rest), db * (http * unit), string) layer
~~~

Finding: the fixture can be made to compile, but only by importing a parallel Tag/Context/HList model. The type-level service order is now part of the public API: Clock must precede Log for this fixture. This is not object-row inference; it is a second service language.

The generic merge tested here is also intentionally narrow: it merges singleton-providing layers. A general merge needs type-level append and dedup witnesses, which either become visible at the call site or require a larger generated DSL.

Collision/dedup evidence: duplicate Db providers compile and are signature-locked:

~~~ocaml
val duplicate_db_layer : (clock * 'rest, db * (db * unit), string) layer
~~~

A good Layer merge should reject or resolve duplicate services. This candidate silently accumulates duplicates.

### Baseline - no Layer

Shape tested:

~~~ocaml
val db_factory : clock -> (< >, string, db) Effect.t
val http_factory : clock -> log -> (< >, string, http) Effect.t
val boot : clock -> log -> (< >, string, string * db * http) Effect.t
~~~

This is the post-provide style from V-RPv5: build services with ordinary values, compose with bind, use Effect.scoped for finalizers. It is half the size of merge_explicit and a third of the GADT candidate.

### Negative probes

neg_merge_missing_clock.ml was temporarily added as an executable. The compiler rejected booting the merged app without Clock:

~~~text
File "scratch/layer_research/neg_merge_missing_clock.ml", line 11, characters 4-87:
11 |     (Merge_explicit.Layer.use (Merge_explicit.app_layer ()) Merge_explicit.app_program)
         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: This expression has type
         (< clock : Services.clock; log : Services.log; .. >, string,
          string * Services.db * Services.http)
         Merge_explicit.Layer.t
       but an expression was expected of type
         (< log : Services.log >, 'a, 'b) Merge_explicit.Layer.t
       The second object type has no method clock
~~~

neg_merge_collision.ml was temporarily added as an executable. The compiler rejected duplicate object methods in the explicit combine:

~~~text
File "scratch/layer_research/neg_merge_collision.ml", line 14, characters 8-29:
14 |         method service = http
             ^^^^^^^^^^^^^^^^^^^^^
Error: The method service has multiple definitions in this object
~~~

neg_gadt_missing_clock.ml was temporarily added as an executable. The compiler rejected a boot env containing Log without Clock:

~~~text
File "scratch/layer_research/neg_gadt_missing_clock.ml", line 13, characters 34-61:
13 |   Gadt_presence_set.Layer.use env Gadt_presence_set.app_layer
                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The value Gadt_presence_set.app_layer has type
         (Services.clock * (Services.log * 'a),
          Services.db * (Services.http * unit), string)
         Gadt_presence_set.Layer.t =
           (Services.clock * (Services.log * 'a)) Gadt_presence_set.Env.t ->
           (<  >, string,
            (Services.db * (Services.http * unit)) Gadt_presence_set.Env.t)
           Effet.Effect.t
       but an expression was expected of type
         (Services.log * unit) Gadt_presence_set.Env.t ->
         ('b, 'c, 'd) Effet.Effect.t
       Type Services.clock is not compatible with type Services.log
~~~

neg_no_layer_missing_log.ml was temporarily added as an executable. The compiler rejected forgetting the Log boot argument as an ordinary partial application warning promoted to error by the build:

~~~text
File "scratch/layer_research/neg_no_layer_missing_log.ml", line 10, characters 2-30:
10 |   No_layer_baseline.boot clock
       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error (warning 5 [ignored-partial-application]): this function application is partial,
  maybe some arguments are missing.
~~~

### Cross-tabulation

| Criterion | merge_explicit | GADT presence-set | no Layer |
|---|---|---|---|
| Shared Clock fixture | Passes | Passes | Passes |
| Missing Clock static check | Good object-row error | Fails statically, but as ordered-list mismatch | Direct missing value / type error |
| Method collision | Good at combine site | Avoids method names, but duplicate caps compile | Ordinary OCaml naming |
| Output merge | Explicit combine | Singleton merge only; general append/dedup missing | No output merge type needed |
| Reusable builders | Need thunks for open rows | Need HList order/witness discipline | Plain functions |
| Public concepts | Layer.t + merge/use | cap, env, has, layer, order, hidden witnesses | functions and Effect.scoped |
| LOC in fixture | 74 | 115 | 37 |

### Decision diary

#### V-RLv1 - merge_explicit is possible but not optimal

Decision: the earlier V-R2 claim was too broad if read as "no Layer-like merge can compile". merge_explicit does compile and gives good object-row errors. However, it does not beat ordinary OCaml. It requires a new Layer module, explicit combine lambdas, Layer.use, and thunked layer factories to preserve reusable open-row signatures. The no-Layer baseline expresses the same scoped service graph in 37 LOC with direct arguments.

#### V-RLv2 - explicit combine is a local app helper, not a core abstraction

Decision: if an application wants to assemble a dependency graph as a value, merge_explicit is a reasonable app-local helper. It should not be in Effet core. Effet's public API should not privilege a helper that mostly wraps Effect.bind and Effect.scoped while adding a second name for ordinary composition.

#### V-RLv3 - GADT presence sets are rejected

Decision: do not ship the GADT presence-set Layer. The positive fixture compiles only by introducing cap constructors, HLists, ordered type-level service sets, and a non-general singleton merge. The missing-service error is less idiomatic than object rows, and duplicate Db providers compile. This recreates Effect-TS Context/Tag in OCaml despite OCaml already having modules, abstract types, objects, and functions.

#### V-RLv4 - no-Layer remains the global optimum for OCaml Effet

Decision: V-RPv5's post-provide style wins this lab too. Service construction is an ordinary function problem; resource lifetime is an Effect.scoped/acquire_release problem; dependency threading is ordinary OCaml parameter passing plus object-row env at runtime boundaries. This gives fewer concepts, shorter code, and better errors than either Layer candidate.

#### V-RLv5 - V-R2 holds, with a narrower rationale

Decision: keep "no Layer module" as the durable public API decision. Refine the rationale: a restricted Layer.merge_explicit is technically viable, so V-R2 should not say every Layer merge is untypeable. The stronger reason not to ship it is that the viable subset is not materially better than ordinary OCaml. The faithful Tag/Context-style route remains rejected because it loses the OCaml object-row dividend and reintroduces service witnesses/order/dedup machinery.

### Recommendation

V-R2 holds: Effet should not ship Layer.t.

No follow-up implementation task is needed. The only documentation follow-up worth considering is a services guide showing the no-Layer pattern:

- define service handles as ordinary module-owned types;
- build services with functions returning Effect.t;
- compose factories with bind inside Effect.scoped;
- pass Clock/Log/Db/Http as normal values or runtime env methods at the outer boundary.

### Documentation follow-up - 2026-05-20

The approved recommendation was materialized as documentation, not production API.
docs/services.md now records the no-Layer service-construction pattern and links to the
compiling scratch/layer_research fixture. README.md links to the guide from a new
Services section.

No Layer module, Tag, Context, or Effect.provide was added.

## Effet-0u8 R-channel DX scale lab - object-row env at 20 modules

### Why this entry exists

Review 1 finding #3 challenged V-R10's evidence base. The auto-DI lab proved that a three-function object-row env example can hide service plumbing from inner functions, but it did not measure developer experience at larger scale.

This entry measures the costs directly: inferred type size, compiler error length and pinpoint quality, build time, incremental rebuild time, and a method-shape refactor.

### Goal

Build a synthetic 20-module app with 30 capability methods and compare three encodings:

- env-row: current Effet style, effects read capabilities from the runtime env;
- args: explicit named service arguments;
- bag: one composite services object passed as a value.

The fixture deliberately uses common verb pressure in method names (query/get/run/fetch), deep chains through m01..m20, and a shape-refactor probe for one method.

### Lab artifacts

Artifacts live in scratch/r_dx_research/.

- generate_fixture.ml
- dx_common.ml
- env_m01.ml .. env_m20.ml, env_top.ml
- args_m01.ml .. args_m20.ml, args_top.ml
- bag_m01.ml .. bag_m20.ml, bag_top.ml
- runtime_smoke.ml
- measure.sh
- neg_env_missing_cap.ml
- neg_args_missing_cap.ml
- neg_bag_shape_refactor.ml
- neg_env_collision.ml
- results/summary.md

Positive validation:

~~~text
nix develop -c ocaml scratch/r_dx_research/generate_fixture.ml
nix develop -c dune build scratch/r_dx_research
nix develop -c dune exec scratch/r_dx_research/runtime_smoke.exe
r-dx smoke tests passed
~~~

### Fixture shape

The generator creates 30 capability methods:

~~~text
user_query user_get user_run user_fetch
order_query order_get order_run order_fetch
cache_query cache_get cache_run cache_fetch
billing_query billing_get billing_run billing_fetch
audit_query audit_get audit_run audit_fetch
search_query search_get search_run search_fetch
notify_query notify_get notify_run notify_fetch
feature_query feature_get
~~~

Modules m01..m10 add two capabilities each. Modules m11..m20 add one capability each. The top chain therefore accumulates all 30 capabilities.

LOC:

| Variant | LOC |
|---|---:|
| env-row modules + top | 135 |
| args modules + top | 169 |
| bag modules + top | 135 |

### Build-time measurements

Single local run. The script removes only _build/default/scratch/r_dx_research, not the whole repo build cache.

| Measurement | ms |
|---|---:|
| clean all variants | 525 |
| clean env-row top | 189 |
| clean args top | 187 |
| clean bag top | 236 |
| noop incremental all | 41 |
| touch env_m10 rebuild top | 28 |
| touch args_m10 rebuild top | 29 |
| touch bag_m10 rebuild top | 30 |
| shape refactor failed rebuild | 442 |

Finding: no variant has a material compile-time advantage in this fixture. Object rows are not measurably slower here.

### Interface / hover proxy

ocamlmerlin was not available as a one-shot CLI in this environment. ocamllsp is installed, but it is an interactive language server, not a direct hover command. The lab uses ocamlc -i as a hover/interface proxy.

| Variant | ocamlc -i bytes | lines |
|---|---:|---:|
| env-row top | 851 | 16 |
| args top | 901 | 32 |
| bag top | 88 | 2 |

env-row top interface excerpt:

~~~ocaml
val program :
  unit ->
  (< audit_fetch : 'a -> 'b; audit_get : 'c -> 'd; audit_query : 'e -> 'c;
     audit_run : 'd -> 'a; billing_fetch : 'f -> 'e; billing_get : 'g -> 'h;
     billing_query : 'i -> 'g; billing_run : 'h -> 'f;
     ...
     user_fetch : 'b1 -> 'x; user_get : 'c1 -> 'd1; user_query : int -> 'c1;
     user_run : 'd1 -> 'b1; .. >,
   'e1, 'o)
  Effet.Effect.t
~~~

args top interface excerpt:

~~~ocaml
val program :
  user_query:(int -> 'a) ->
  user_get:('a -> 'b) ->
  ...
  feature_get:('c1 -> 'd1) -> ('e1, 'f1, 'd1) Effet.Effect.t
~~~

bag top interface:

~~~ocaml
val program : #Dx_common.services -> ('a, 'b, int) Effet.Effect.t
val run : unit -> int
~~~

Finding: bag has the cleanest hover but hides dependency precision. env-row and args both expose large polymorphic chains; env-row is denser, args is longer but more familiar.

### Value restriction finding

The first env-row generator emitted module-level values:

~~~ocaml
let program = ...
~~~

That failed at m01:

~~~text
Error: The type of this expression,
       (< user_get : '_weak2 -> '_weak3; user_query : int -> '_weak2; .. >
        as '_weak1, '_weak4, '_weak3)
       Effect.t, contains the non-generalizable type variable(s)
~~~

The working env-row fixture uses thunks:

~~~ocaml
let program () = ...
~~~

Decision impact: module-level reusable env-row effects may need eta-expansion/thunks when open object rows and polymorphic result chains appear. This is a real DX cost. It is not a soundness failure.

### Negative probes

#### Missing capability - env-row

neg_env_missing_cap.ml omits billing_fetch from the boot env.

~~~text
File "scratch/r_dx_research/neg_env_missing_cap.ml", line 36, characters 66-86:
36 | let _ : (int, string Cause.t) result = Dx_common.run_with_env env (Env_top.program ())
                                                                       ^^^^^^^^^^^^^^^^^^^^
Error: This expression has type
         (< audit_fetch : 'a -> 'b; audit_get : 'c -> 'd;
            audit_query : 'e -> 'c; audit_run : 'd -> 'a;
            billing_fetch : 'f -> 'e; billing_get : 'g -> 'h;
            billing_query : 'i -> 'g; billing_run : 'h -> 'f;
            cache_fetch : 'j -> 'i; cache_get : 'k -> 'l;
            cache_query : 'm -> 'k; cache_run : 'l -> 'j;
            feature_get : 'n -> 'o; feature_query : 'p -> 'n;
            notify_fetch : 'q -> 'p; notify_get : 'r -> 's;
            notify_query : 't -> 'r; notify_run : 's -> 'q;
            order_fetch : 'u -> 'm; order_get : 'v -> 'w;
            order_query : 'x -> 'v; order_run : 'w -> 'u;
            search_fetch : 'y -> 't; search_get : 'z -> 'a1;
            search_query : 'b -> 'z; search_run : 'a1 -> 'y;
            user_fetch : 'b1 -> 'x; user_get : 'c1 -> 'd1;
            user_query : int -> 'c1; user_run : 'd1 -> 'b1; .. >,
          'e1, 'o)
         Effect.t
       but an expression was expected of type
         (< audit_fetch : int -> int; audit_get : int -> int;
            audit_query : int -> int; audit_run : int -> int;
            billing_get : int -> int; billing_query : int -> int;
            billing_run : int -> int; cache_fetch : int -> int;
            cache_get : int -> int; cache_query : int -> int;
            cache_run : int -> int; feature_get : int -> int;
            feature_query : int -> int; notify_fetch : int -> int;
            notify_get : int -> int; notify_query : int -> int;
            notify_run : int -> int; order_fetch : int -> int;
            order_get : int -> int; order_query : int -> int;
            order_run : int -> int; search_fetch : int -> int;
            search_get : int -> int; search_query : int -> int;
            search_run : int -> int; user_fetch : int -> int;
            user_get : int -> int; user_query : int -> int;
            user_run : int -> int >,
          'f1, 'g1)
         Effect.t
       The second object type has no method billing_fetch
~~~

Size excluding nix dirty warning: 2295 bytes, 40 lines.

Quality: correct missing method, poor pinpoint. The useful fact is at the bottom after a full row dump.

#### Missing capability - args

neg_args_missing_cap.ml omits the billing_fetch named argument.

~~~text
File "scratch/r_dx_research/neg_args_missing_cap.ml", lines 6-35, characters 2-37:
 6 | ..Args_top.program
 7 |     ~user_query:services#user_query
 8 |     ~user_get:services#user_get
 9 |     ~user_run:services#user_run
10 |     ~user_fetch:services#user_fetch
...
32 |     ~notify_run:services#notify_run
33 |     ~notify_fetch:services#notify_fetch
34 |     ~feature_query:services#feature_query
35 |     ~feature_get:services#feature_get
Error: This expression has type
         billing_fetch:(int -> int) -> ('a, 'b, int) Effect.t
       but an expression was expected of type (<  >, string, int) Effect.t
Hint: This function application is partial, maybe some arguments are missing.
~~~

Size excluding nix dirty warning: 689 bytes, 15 lines.

Quality: better. It names billing_fetch directly and reads like ordinary OCaml.

#### Shape refactor - bag

neg_bag_shape_refactor.ml changes billing_fetch to string -> int.

~~~text
File "scratch/r_dx_research/neg_bag_shape_refactor.ml", line 35, characters 24-32:
35 | let _ = Bag_top.program services
                             ^^^^^^^^
Error: The value services has type
         < audit_fetch : int -> int; audit_get : int -> int;
           audit_query : int -> int; audit_run : int -> int;
           billing_fetch : string -> int; billing_get : int -> int;
           ...
           user_query : int -> int; user_run : int -> int >
       but an expression was expected of type
         #Dx_common.services as 'a =
           < audit_fetch : int -> int; audit_get : int -> int;
             audit_query : int -> int; audit_run : int -> int;
             billing_fetch : int -> int; billing_get : int -> int;
             ...
             user_query : int -> int; user_run : int -> int; .. >
       The method billing_fetch has type string -> int,
       but the expected method type was int -> int
~~~

Size excluding nix dirty warning: 2284 bytes, 38 lines.

Quality: long, but precise. The final sentence is directly actionable.

#### Generic method collision - env-row

neg_env_collision.ml composes effects that all use common method names query/get with incompatible shapes.

~~~text
File "scratch/r_dx_research/neg_env_collision.ml", line 8, characters 2-3:
8 |   a |> Effect.bind (fun _ -> b)
      ^
Error: The value a has type (< query : int -> 'a; .. >, 'b, 'a) Effect.t
       but an expression was expected of type
         (< query : string -> 'c; .. >, 'd, 'e) Effect.t
       The method query has type int -> 'a, but the expected method type was
       string -> 'c
~~~

Size excluding nix dirty warning: 391 bytes, 8 lines.

Quality: good. Generic method-name collisions fail near the composition point with the incompatible method name.

### Shape-refactor rebuild

A temporary generated change modified billing_fetch from int -> int to string -> int in dx_common.ml and then built scratch/r_dx_research.

~~~text
exit=1
elapsed_ms=442
~~~

The failed build reported all three affected styles:

- bag: failed in bag_m08 when billing_fetch changed the chain input type;
- env-row: failed at Env_top.run with a long row mismatch;
- args: failed at Args_top.run where services#billing_fetch no longer matched int -> 'a.

Finding: the changed method propagates quickly and fails statically. The env-row failure is the longest; args is most local; bag fails inside the first module where the chain type becomes inconsistent.

### Cross-tabulation

| Criterion | env-row | args | bag |
|---|---|---|---|
| Clean build time | 189 ms | 187 ms | 236 ms |
| Touch rebuild | 28 ms | 29 ms | 30 ms |
| Top interface size | 851 bytes | 901 bytes | 88 bytes |
| Missing capability error | 2295 bytes, precise final line | 689 bytes, direct missing arg | n/a for missing method if bag type is named |
| Shape refactor error | long row mismatch | direct bad argument at top | long but precise services mismatch |
| Collision quality | good for incompatible method shape | ordinary value naming | hidden behind bag type |
| Module-boundary cost | thunks needed for reusable open-row values | none observed | none observed |
| Dependency precision | per effect | per function arg list | all-or-nothing bag |

### Decision diary

#### V-Dxv1 - Compile time does not reopen V-R10

Decision: V-R10 is not rejected on compile-time grounds. At 20 modules / 30 capabilities, clean and incremental build times are effectively tied across env-row, args, and bag. The differences are below the noise floor for this synthetic fixture.

#### V-Dxv2 - Env-row diagnostics are correct but noisy

Decision: env-row error quality is the main cost. Missing capability errors are statically correct and name the missing method, but the compiler dumps the whole row before the actionable final line. This is materially worse than explicit args for "forgot one dependency at boot".

#### V-Dxv3 - Hover usefulness is mixed

Decision: env-row hovers are dense and expose the full capability row. Args hovers are longer but familiar. Bag hovers are tiny, but that is because the bag hides dependency precision. This does not justify flipping to bag; it does suggest keeping public examples away from giant env rows.

#### V-Dxv4 - Value restriction is a real env-row footgun

Decision: reusable module-level env-row effects may need thunks. The generator's first env-row version failed with non-generalizable weak variables. The fixed version exports program : unit -> Effect.t. This should be documented as a pattern for polymorphic env-row values that cross module boundaries.

#### V-Dxv5 - Method-name collisions are manageable

Decision: generic collisions on query/get/run/fetch fail statically and locally when shapes conflict. The lab supports the existing guidance: avoid generic env method names in public libraries; namespace methods or pass service handles as values.

#### V-Dxv6 - V-R10 confirmed, with DX mitigations

Decision: keep V-R10. The object-row env channel remains sound and compile-time cost is acceptable at this synthetic scale. Do not flip to args or composite bag globally. The right mitigation is narrower: use env rows for leaf/runtime-boundary capabilities, use ordinary args for service graph construction, and document thunking for reusable polymorphic env-row effects.

### Recommendation

V-R10 remains valid at scale for Effet core.

Mitigation tasks worth keeping in mind:

- document the thunk pattern for module-level polymorphic env-row effects;
- keep README/docs examples from accumulating giant env rows;
- prefer service handles as ordinary values for large application graphs;
- consider a short "reading object-row errors" troubleshooting note if users report pain.

No migration epic is justified by this lab.

## R-channel follow-up review labs - black-box effects, public APIs, naming, evolution

### Why this entry exists

GPT Pro reviewed the R-channel research and agreed with the narrowed final design:
keep the structural object-row R-channel, but do not treat it as a general DI system.
It also identified five remaining holes before the design could be considered settled:
black-box env-requiring effects after Effect.provide deletion, real public/editor DX,
public .mli style, same-shape semantic collisions, and library evolution when a leaf
effect gains a capability.

This entry closes those holes as far as the current lab can.

### Goal

Verify whether the current split still holds:

- Effect.t keeps the R-channel for leaf/runtime-boundary capabilities.
- Application service graphs use ordinary OCaml arguments and scoped factories.
- Layer.t, Tag/Context, and Effect.provide stay out of the public API.

### Artifacts

Lab: scratch/r_followup_research/

- black_box.ml: black-box env-effect substitution fixture.
- public_mli_styles.mli/ml: exported API shape comparisons.
- naming_collision.ml: generic vs namespaced method collision fixture.
- library_evolution.ml: leaf gains metrics capability across env-row, args, bag.
- neg_black_box_value.ml: open-row effect value fails by value restriction.
- neg_closed_row_extra_env.ml: closed row rejects extra env methods.
- neg_evolution_env_missing_metric.ml: env-row missing new leaf capability.
- neg_evolution_args_missing_metric.ml: explicit args missing new argument.
- hazard_same_shape_collision.ml: deliberately compiles; documents semantic collision.
- results.md: command outputs.

Positive build and smoke:

~~~text
nix develop -c dune build scratch/r_followup_research
exit=0

nix develop -c dune exec scratch/r_followup_research/runtime_smoke.exe
exit=0
~~~

### Lab 1 - black-box env-requiring effect substitution

Fixture: a third-party module exposes a child computation that requires db through env,
and the host program requires real db, audit, and secret. The host wants to run its own
before/after db work against real db, but the child against fake db.

Candidate A, direct black-box env effect:

~~~ocaml
host_program (Third_party.black_box ())
~~~

Result: child uses the host db. This is type-correct but cannot locally swap db for only
the child. Runtime result:

~~~text
before=real:before;child=real:child;after=real:after;secret=s3
~~~

Candidate B, constructor / ordinary-argument library API:

~~~ocaml
host_program (Third_party.make fake_db)
~~~

Result: works and preserves host env for real db/audit/secret. Runtime result:

~~~text
before=real:before;child=fake:child;after=real:after;secret=s3
~~~

Candidate C, separate Runtime.run boundary:

~~~ocaml
let fake_child = run_with_env fake_db_env (Third_party.black_box ()) in
host_program (Effect.pure fake_child)
~~~

Result: works only by splitting the child out of the parent program. That is acceptable
for test setup or an actual process/runtime boundary, but it is not a general
in-effect local substitution primitive.

Candidate D, private provide-like local evaluator:

~~~ocaml
Private_eval.locally fake_db_env (Third_party.black_box ())
~~~

Result: works only by reinterpreting Effect.Private.view for a tiny subset
Pure/Fail/Sync/Bind/Map. This is not a viable user API; full correctness would require
duplicating the runtime semantics for scoped resources, supervision, cancellation,
tracing, async, par/all/race, finalizers, and cause shaping.

The lab also exposed a stronger OCaml-specific constraint: a reusable already-built
open-row effect value is not exportable without weak variables. The black-box public
shape must be a thunk.

~~~text
R_FOLLOWUP_NEG=black_box_value nix develop -c dune build scratch/r_followup_research/neg_black_box_value.exe
File "scratch/r_followup_research/neg_black_box_value.ml", lines 11-14, characters 6-3:
11 | ......struct
12 |   let black_box =
13 |     Effect.sync "third.black_box" (fun env -> query env#db "child")
14 | end
Error: Signature mismatch:
       ...
       Values do not match:
         val black_box :
           (< db : db; .. > as '_weak1, '_weak2, string) Effect.t
       is not included in
         val black_box : (< db : db; .. >, string, string) Effect.t
       The type (< db : db; .. > as '_weak1, '_weak2, string) Effect.t
       is not compatible with the type
         (< db : db; .. >, string, string) Effect.t
       Type '_weak1 is not compatible with type 'a
~~~

Finding: the deletion of Effect.provide remains correct for the public core, but the
documentation must tell library authors to expose env-requiring effects as thunks or as
ordinary constructors. If a future real fixture requires local substitution for a
black-box effect that cannot expose either form, the primitive to reopen is not broad
provide; it is a narrow, runtime-owned local-env interpreter with the full runtime
semantics. No such fixture exists yet.

### Lab 2 - public .mli and editor-DX proxy

public_mli_styles.mli compares the public API options:

~~~ocaml
val open_row_thunk :
  unit -> (< clock : clock ; log : log ; .. >, string, result) Effect.t

val closed_row_value : (< clock : clock ; log : log >, string, result) Effect.t

val args :
  clock:clock -> log:log -> ('env, string, result) Effect.t

val bag :
  #clock_log -> ('env, string, result) Effect.t
~~~

ocamllsp is installed, but the lab did not find a reliable one-shot CLI hover command;
the server exposes only stdio/socket modes. As a proxy, the lab used explicit .mli
text plus ocamlc -i output from the implementation:

~~~text
val open_row_thunk :
  unit ->
  (< clock : R_followup_research.Services.clock;
     log : R_followup_research.Services.log; .. >,
   'a, string)
  Effet.Effect.t
val closed_row_value :
  (< clock : R_followup_research.Services.clock;
     log : R_followup_research.Services.log; .. >
   as '_weak1, '_weak2, string)
  Effet.Effect.t
val args :
  clock:R_followup_research.Services.clock ->
  log:R_followup_research.Services.log -> ('a, 'b, string) Effet.Effect.t
val bag :
  < clock : R_followup_research.Services.clock;
    log : R_followup_research.Services.log; .. > ->
  ('a, 'b, string) Effet.Effect.t
~~~

The explicit .mli is clearer than inferred output. The inferred output shows why public
interfaces should be written deliberately: reusable effect values infer weak env/error
variables, while thunks and ordinary-arg constructors remain polymorphic.

Closed rows are compact but too strict:

~~~text
R_FOLLOWUP_NEG=closed_row_extra_env nix develop -c dune build scratch/r_followup_research/neg_closed_row_extra_env.exe
File "scratch/r_followup_research/neg_closed_row_extra_env.ml", line 17, characters 28-62:
17 |   Services.run_with_env env Public_mli_styles.closed_row_value
                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The value Public_mli_styles.closed_row_value has type
         (< clock : Services.clock; log : Services.log >, string, string)
         Effet.Effect.t
       but an expression was expected of type
         (< clock : Services.clock; log : Services.log;
            secret : Services.secret >,
          string, 'a)
         Effet.Effect.t
       The first object type has no method secret
~~~

Finding: public APIs should prefer open-row thunks for reusable env effects, ordinary
arguments for service construction, and closed rows only for intentionally sealed
subsystems.

### Lab 3 - same-shape semantic collisions

Previous DX research proved incompatible method-shape collisions fail locally. This lab
tests the missing case: two libraries both require env#query : string -> string, but
mean different things.

~~~ocaml
let user_by_generic_query =
  Effect.sync "user.generic_query" (fun env -> env#query "current-user")

let order_by_generic_query =
  Effect.sync "order.generic_query" (fun env -> env#query "current-order")
~~~

This compiles:

~~~text
R_FOLLOWUP_NEG=hazard_same_shape_collision nix develop -c dune build scratch/r_followup_research/hazard_same_shape_collision.exe
exit=0
~~~

Runtime result uses the same implementation for both semantics:

~~~text
shared:current-user
shared:current-order
~~~

Namespaced methods avoid the ambiguity:

~~~ocaml
env#user_query
env#order_query
~~~

Finding: structural object rows cannot detect same-shape semantic collisions. This is
not a reason to drop the R-channel; it is a reason to prohibit generic verbs as public
env methods. Public capabilities should be service-shaped or namespaced.

### Lab 4 - library evolution

Fixture: a four-layer library has a leaf that initially needs clock. V2 adds metrics at
the leaf. Compare env-row, explicit args, and bag.

Observed source churn in the hand-written fixture:

| Shape | Files/functions touched | Reason |
|---|---:|---|
| env-row | 1 | leaf source changes; inferred top env row grows |
| args | 4 | leaf plus every pass-through function grows ~metrics |
| bag | 2 | bag type plus leaf change; dependency precision hidden |

All V2 positives pass and record the metric exactly once.

Env-row missing metric fails at boot/run boundary:

~~~text
R_FOLLOWUP_NEG=evolution_env_missing_metric nix develop -c dune build scratch/r_followup_research/neg_evolution_env_missing_metric.exe
File "scratch/r_followup_research/neg_evolution_env_missing_metric.ml", line 14, characters 28-65:
14 |   Services.run_with_env env (Library_evolution.Env_row.V2.top ())
                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: This expression has type
         (< clock : Services.clock; metrics : Services.metrics; .. >, 'a,
          int)
         Effet.Effect.t
       but an expression was expected of type
         (< clock : Services.clock >, string, 'b) Effet.Effect.t
       The second object type has no method metrics
~~~

Explicit args fail at the pass-through call site:

~~~text
R_FOLLOWUP_NEG=evolution_args_missing_metric nix develop -c dune build scratch/r_followup_research/neg_evolution_args_missing_metric.exe
File "scratch/r_followup_research/neg_evolution_args_missing_metric.ml", line 8, characters 2-58:
8 |   Library_evolution.Args.V2.top ~clock:(Services.clock 42)
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error (warning 5 [ignored-partial-application]): this function application is partial,
  maybe some arguments are missing.
~~~

Finding: this is the strongest positive evidence for the R-channel after V-R10. Adding
a new leaf capability does not force source churn through every intermediate function.
The cost is that missing capability diagnostics are row-shaped and appear at the run
boundary. Args have better local errors but more ripple.

### Decision diary

#### V-RFv1 - Black-box effect substitution does not restore public provide

Decision: keep Effect.provide deleted. Direct black-box env effects use the host env;
constructor/ordinary-arg APIs solve local substitution cleanly; separate Runtime.run
works only by splitting the program; a local provide-like helper requires reimplementing
the runtime. The only reopening criterion is a real third-party black-box effect that
cannot expose a thunk/constructor and must be locally reinterpreted inside a parent
effect with full scoped/supervised semantics.

#### V-RFv2 - Public env effects should be thunks

Decision: document unit -> Effect.t for reusable open-row env effects. The compiler
rejects an exported already-built open-row effect value with weak variables. This is a
language-level constraint, not a style preference.

#### V-RFv3 - Closed rows are niche

Decision: do not recommend closed object rows for public capability requirements.
They are compact in signatures, but they reject callers with extra capabilities.
Use them only when a subsystem is intentionally sealed.

#### V-RFv4 - Same-shape semantic collisions are a convention risk

Decision: keep structural object rows, but document naming rules. OCaml catches
incompatible method shapes, but cannot distinguish two env#query methods with the same
type and different meaning. Public env methods should be namespaced or service-shaped:
clock, db, audit, user_query, order_query, not query/get/run/fetch.

#### V-RFv5 - Library evolution supports the narrowed R-channel

Decision: the R-channel earns its place for effect requirements. When a leaf gains a
metrics capability, env-row changes stay at the leaf and inferred requirements propagate
to the boundary. Explicit args give better local errors but force pass-through churn.
The correct split remains: use env rows for effect requirements, arguments for service
construction.

#### V-RFv6 - Real editor DX remains partly open

Decision: the public .mli experiment is sufficient to set signature guidance, but not
to claim complete editor-DX evidence. ocamllsp was available only as an LSP server in
this lab, and no stable one-shot hover capture was recorded. Keep the mitigation:
write explicit .mli files for public modules and avoid exposing large inferred rows.

### Final recommendation

The GPT Pro review did not overturn the design. It sharpened it.

Keep the current R-channel, no Layer.t, no Effect.provide. The missing experiments
support the same narrowed rule:

~~~text
Env rows: leaf/runtime-boundary effect requirements.
Ordinary arguments: service construction, mocks, scoped factories, app graphs.
Thunks: reusable public env-requiring effects.
Namespaced methods: public capabilities.
Closed rows: rare sealed subsystem boundary only.
~~~

Required documentation follow-up: add the thunk pattern, black-box library guidance,
closed-row warning, namespaced capability naming rule, and library-evolution tradeoff to
the README/services guide.

## PPX env-DX research - syntax only, no hidden DI

### Why this entry exists

The R-channel follow-up labs kept the structural object-row env channel, but narrowed
its use: env rows are for leaf/runtime-boundary capabilities, while service graphs are
ordinary OCaml values and functions. The remaining question is whether ppx_effet should
improve the env-row DX without reopening Layer, Context, Tag, provide, or hidden service
wiring.

### Goal

Evaluate all proposed PPX ideas:

- raw env#cap baseline;
- explicit leaf capability binding;
- capability declaration/profile/accessor generation;
- runtime env object builder;
- declared leaf requirements that prevent accidental env creep;
- troubleshooting/check-env helpers;
- anti-hypotheses: Layer/Context/Tag generation, inferred env construction, implicit
  service injection, arg/env conversion, mega service bags, tracer-as-env, silent
  thunking.

If a candidate is clearly good and semantics-preserving, implement it in ppx_effet.

### Artifacts

Lab: scratch/ppx_env_research/

- p_a_baseline_raw.ml: raw env#cap leaves.
- p_b_leaf_ppx.ml: [%effet.sync] / [%effet.async] leaf capability binding.
- p_c_capability_profile.ml: manual shape that a capability declaration PPX would
  generate.
- p_d_env_builder.ml: [%effet.env] boundary object builder.
- neg_b_env_creep.ml: direct env read inside a declared leaf must fail.
- neg_b_duplicate_cap.ml: duplicate capability binding must fail.
- neg_d_duplicate_env.ml: duplicate env object field must fail.
- neg_value_restriction_raw.ml: raw open-row value hits weak variables.
- results.md: command outputs and interface measurements.

Production implementation:

- packages/ppx_effet/ppx_effet.ml
- packages/ppx_effet/test/test_ppx_effet.ml
- README.md
- docs/services.md

### Syntax reality check

The pretty proposed binding form:

~~~ocaml
let%effet.sync current_user () [auth : Auth.t] =
  Auth.current_user auth
~~~

does not fit normal OCaml expression grammar cleanly. The implemented shape keeps the
same explicit capability-binding idea but uses a valid expression extension:

~~~ocaml
let current_user () =
  [%effet.sync "auth.current_user" (auth : Auth.t)
    (Auth.current_user auth)]
~~~

Multiple capabilities use a tuple:

~~~ocaml
[%effet.sync "auth.current_user_logged" ((auth : Auth.t), (log : Log.t))
  (let user = Auth.current_user auth in
   Log.info log ("user=" ^ user);
   user)]
~~~

Boundary env objects use ordinary record-like payload syntax:

~~~ocaml
let env =
  [%effet.env { auth = (auth : Auth.t); log = (log : Log.t) }]
~~~

### Candidate results

Positive build and smoke:

~~~text
nix develop -c dune build scratch/ppx_env_research
exit=0

nix develop -c dune exec scratch/ppx_env_research/runtime_smoke.exe
exit=0
~~~

Interface measurements from ocamlc -i over preprocessed candidates:

| Candidate | Lines | Bytes | Notes |
|---|---:|---:|---|
| P-A raw env#cap | 12 | 368 | shortest control |
| P-B ppx leaf | 15 | 429 | adds async sample, same inferred env shape |
| P-C capability profile | 18 | 576 | named class type survives as #Auth_cap.has_auth |
| P-D env builder | 12 | 386 | type-annotated object method output |

The P-B expansion is readable and semantics-preserving:

~~~ocaml
let current_user () =
  Effet.Effect.fn __POS__ __FUNCTION__
    (Effet.Effect.sync "auth.current_user"
       (fun __effet_env ->
          let auth = (__effet_env#auth : Auth.t) in Auth.current_user auth))
~~~

The P-D expansion is just an object:

~~~ocaml
let env ~auth ~log =
  object method auth = (auth : Auth.t) method log = (log : Log.t) end
~~~

### Negative tests

Direct env read inside a declared leaf fails during PPX expansion:

~~~text
PPX_ENV_NEG=env_creep nix develop -c dune build scratch/ppx_env_research/neg_b_env_creep.exe
File "scratch/ppx_env_research/neg_b_env_creep.ml", line 8, characters 4-50:
8 |     (Auth.current_user auth ^ Db.query env#db "x")]
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: effet leaf body must use listed capabilities, not env directly
~~~

Duplicate leaf capabilities fail before type checking:

~~~text
PPX_ENV_NEG=duplicate_cap nix develop -c dune build scratch/ppx_env_research/neg_b_duplicate_cap.exe
File "scratch/ppx_env_research/neg_b_duplicate_cap.ml", lines 7-8, characters 2-29:
7 | ..[%effet.sync "bad.duplicate" ((auth : Auth.t), (auth : Auth.t))
8 |     (Auth.current_user auth)]
Error: duplicate capability binding: auth
~~~

Duplicate env builder fields fail before type checking:

~~~text
PPX_ENV_NEG=duplicate_env nix develop -c dune build scratch/ppx_env_research/neg_d_duplicate_env.exe
File "scratch/ppx_env_research/neg_d_duplicate_env.ml", line 7, characters 2-65:
7 |   [%effet.env { auth = (auth : Auth.t); auth = (auth : Auth.t) }]
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: duplicate capability binding: auth
~~~

The raw module-level open-row value still hits weak variables:

~~~text
PPX_ENV_NEG=value_restriction_raw nix develop -c dune build scratch/ppx_env_research/neg_value_restriction_raw.exe
File "scratch/ppx_env_research/neg_value_restriction_raw.ml", lines 10-13, characters 6-3:
10 | ......struct
11 |   let current_user =
12 |     Effect.sync "auth.current_user" (fun env -> Auth.current_user env#auth)
13 | end
Error: Signature mismatch:
       ...
       Values do not match:
         val current_user :
           (< auth : Auth.t; .. > as '_weak1, '_weak2, string) Effect.t
       is not included in
         val current_user : (< auth : Auth.t; .. >, string, string) Effect.t
~~~

### Anti-hypotheses

PPX-generated Layer/Context/Tag remains rejected. The Layer lab already proved an
explicit merge layer can compile but is worse than ordinary OCaml service construction.
PPX would hide that cost, not remove it.

Inferred env construction remains rejected. A normal PPX runs before typing and cannot
inspect the inferred object row of an arbitrary program. A .cmt analyzer would be a
separate tool, not ppx_effet.

Implicit service injection by variable name remains rejected. The accepted syntax writes
the capability list in source. There is no magic lookup of unbound variables.

Automatic function-arg/env-row conversion remains rejected. It blurs the settled split:
arguments construct service graphs; env rows describe effect requirements.

Generated service bags remain rejected for application wiring. [%effet.env] is a
boundary object literal helper only.

Tracer-as-env remains rejected. [%effet.sync] wraps with Effect.fn, but it does not add
env#tracer. Tracing remains a Runtime.create parameter and interpreter concern.

Silent thunking remains rejected. The PPX does not rewrite let program = ... into
let program () = .... The user writes () explicitly.

### Decision diary

#### V-PPX1 - Leaf capability binding is accepted

Decision: ship expression forms [%effet.sync] and [%effet.async]. They directly target
real DX problems: leaf boilerplate, explicit capability list, accidental env creep, and
source-position span naming. The expansion is plain Effect.fn around Effect.sync/async,
so runtime semantics do not change.

#### V-PPX2 - Binding syntax is deferred

Decision: do not ship let%effet.sync binding syntax now. The attractive proposed
surface does not fit OCaml grammar as written, and the expression extension already
handles the load-bearing case while keeping the explicit thunk visible.

#### V-PPX3 - Runtime env builder is accepted

Decision: ship [%effet.env { cap = (value : Type); ... }]. It generates only an object
literal with annotated methods and rejects duplicates early. This improves boundary code
without creating Layer or service wiring.

#### V-PPX4 - Capability declaration/profile generation is not accepted yet

Decision: defer [%%effet.capability] and [%%effet.env_profile]. The manual P-C shape
compiles and #Auth_cap.has_auth appears in ocamlc -i, but it adds more interface surface
than the leaf/builder helpers and needs a real ocamllsp hover study before becoming
public syntax.

#### V-PPX5 - Check-env helper is not accepted yet

Decision: defer [%effet.check_env]. The env builder already localizes boundary method
types for constructed envs. A separate check helper is only justified if users report
large boundary-object diagnostics that [%effet.env] does not improve.

#### V-PPX6 - ppx_effet remains syntactic and documentary

Decision: ppx_effet is not dependency injection. It may name and bind capabilities that
the author writes explicitly, and it may generate object literals at the runtime
boundary. It must not infer, resolve, provide, substitute, merge, or auto-wire services.

### Implementation summary

Implemented in ppx_effet:

~~~ocaml
[%effet.sync "name" (cap : Type) body]
[%effet.sync "name" ((cap1 : T1), (cap2 : T2)) body]
[%effet.async "name" (cap : Type) body]
[%effet.env { cap = (value : Type); ... }]
~~~

All sync/async leaves expand through Effect.fn __POS__ __FUNCTION__, preserving the
existing span convention. The generated env variable is named __effet_env, and the PPX
rejects direct identifier env in the body.

### Final recommendation

Keep the new PPX helpers. Do not add any broader PPX mechanism now.

The accepted surface is small enough to explain in README and strong enough to address
the concrete R-channel DX pain:

- less leaf boilerplate;
- explicit capability lists;
- no accidental env#cap creep in leaves;
- explicit thunk style for exported effects;
- boundary env object annotations;
- no service-graph machinery.

## OTel propagation — W3C context, baggage, sampling flags (V-P)

### Why this entry exists

V-O6 correctly moved tracer injection to `Runtime.create ?tracer`, but it only
settled in-process span emission. Distributed tracing needs a propagation value:
W3C `traceparent`, `tracestate`, the sampled flag, and baggage must cross
service boundaries and must affect runtime sampling before a span is opened.

### Goal

Decide where full propagation belongs, prove the choice in a lab, then implement
the confirmed minimum surface.

### Constraints inherited from prior research

- V-O6 holds: tracer remains a runtime parameter, not an env-row capability.
- Eio fiber-local context remains the runtime propagation mechanism.
- `effet-otel` stays a companion package for OTLP export; core Effet must not
  grow a network stack.
- The public effect surface should expose capabilities, not Effect-TS type names
  for their own sake.

### Hypothesis space

- **P-A — pair-only external parent.** Keep `with_external_parent ~trace_id
  ~span_id` as the only boundary primitive.
- **P-B — full core trace_context.** Add a W3C-shaped record in core, carry it in
  runtime fiber-local state, and expose extract/inject helpers.
- **P-C — exporter-only propagation.** Put header parsing and injection in
  `effet-otel`; leave core runtime unchanged.

### Lab

`scratch/otel_propagation/` contains three self-contained candidates and a
runtime smoke executable.

- `p_a_pair_only.ml` demonstrates that the current pair-only shape correlates a
  child but necessarily drops trace flags, tracestate, and baggage.
- `p_b_core_context.ml` round-trips W3C-style headers and lets a parent sampled
  flag suppress child span creation.
- `p_c_exporter_only.ml` can parse/inject headers but cannot make `named`,
  `par`, logs, or `current_context` observe baggage or sampling flags.

Command:

```sh
nix develop -c dune exec scratch/otel_propagation/runtime_smoke.exe
```

Result:

```text
otel propagation lab passed
```

Negative fixture:

```sh
nix develop -c dune exec scratch/otel_propagation/neg_malformed_traceparent.exe
```

Result: exited successfully because malformed all-zero trace IDs are rejected.

### ocaml-opentelemetry comparison

The upstream `ocaml-opentelemetry` library already has `Trace_context.Traceparent`
helpers and a `Span_ctx` model. Its public `Traceparent.of_value` currently
returns only `Trace_id.t * Span_id.t` and the source comment says flags are
ignored. The Cohttp integration also notes that parsing an external traceparent
really wants a span context. It does not give Effet a drop-in Eio runtime context
or baggage carrier.

Decision: do not depend on `ocaml-opentelemetry` for core propagation. Keep the
dependency-free W3C parser in core and allow alternate exporter adapters later.

### Decision diary

#### V-P1 — Propagation context lives in core

Decision: adopt P-B. A full `Capabilities.trace_context` record is now core
state because sampling and `Effect.current_context` need it before any exporter
sees a span. P-C is too late in the pipeline: an exporter can serialize headers,
but it cannot make `Runtime` suppress unsampled children or carry baggage through
`par`.

#### V-P2 — Pair-only external parent remains only as compatibility

Decision: keep `Effect.with_external_parent ~trace_id ~span_id` as a wrapper,
but document `Trace_context.extract` + `Effect.with_context` as the real
boundary API. The lab shows pair-only propagation drops the fields production OTel
needs.

#### V-P3 — Header extract/inject is dependency-free and small

Decision: `Effet.Trace_context` parses and injects `traceparent`,
`tracestate`, and `baggage` as HTTP-style `(string * string) list` headers.
It rejects malformed trace IDs/span IDs, including all-zero IDs. It intentionally
does not implement a full HTTP abstraction.

#### V-P4 — Parent-based sampling reads the W3C sampled flag

Decision: `Effect.with_context ctx body` binds runtime sampled state from
`ctx.trace_flags land 1`. A parent-based sampler now treats an inbound context
as a parent even before a local span exists. The new test
`trace context unsampled parent suppresses child` verifies `traceflags=00`
creates no child span.

#### V-P5 — Baggage and tracestate propagate through fibers

Decision: the runtime stores trace context in an Eio fiber-local key, so `par`,
`all`, `for_each_par`, supervisors, and runtime-owned daemons inherit it at
fork time via the same mechanism used for active span context. The test
`trace context par inherits baggage` verifies both `par` children see baggage.

#### V-P6 — effet-otel preserves traceState, baggage remains propagation-only

Decision: emitted OTLP spans now preserve `traceState` when a remote parent
provided it. Baggage is carried by `Trace_context.inject`; it is not an OTLP span
field. The `effet-otel` encoder smoke test now asserts `traceState` appears in
the exported JSON.

#### V-P7 — current_context is the user-facing outbound hook

Decision: add `Effect.current_context`. In an active span it returns that span's
propagation context; otherwise it returns the ambient context installed by
`with_context`. Outbound HTTP wrappers should call
`Effect.current_context |> Effect.map Trace_context.inject`.

### Implementation summary

Implemented:

- `packages/effet/trace_context.{ml,mli}`
- `Capabilities.trace_context` and widened `span_info`
- `Effect.with_context` and `Effect.current_context`
- Runtime fiber-local propagation of full context and sampled flag
- `effet-otel` tracer storage/export of trace flags, tracestate, and baggage
- README and `packages/effet-otel/README.md` propagation docs

Verification:

```sh
nix develop -c dune runtest --force
```

Result: `effet-schema`, `ppx_effet`, `effet` (83 tests), and
`effet-otel` (19 tests) passed.

### What remains deliberately out of scope

- URL percent-decoding and metadata-preserving baggage parsing. The current API
  preserves key/value baggage needed for Effet propagation; richer baggage
  metadata can be added without changing `Effect.with_context`.
- A full HTTP client/server wrapper. The surface is header-list based so Eio,
  Piaf, Cohttp, or app-local transports can adapt it.
- Replacing `effet-otel` with `ocaml-opentelemetry`. The core trait remains
  adapter-friendly, but the current package keeps the dependency closure small.

## V-O7r - OTLP backend re-comparison after Yojson and propagation

### Why this entry exists

V-O7 chose a hand-rolled effet-otel OTLP/JSON transport partly because it added
zero dependencies. That premise is stale. Later work replaced the hand-written
JSON buffer assembly with Yojson and V-P added core W3C propagation helpers. The
backend decision needed to be rerun against the current dependency baseline and
current propagation surface.

This is research-only. No live exporter implementation was changed in this
entry.

### Goal

Compare the current effet-otel transport with an ocaml-opentelemetry-style
adapter on the axes the original V-O7 decision used plus the new production
axes raised by the reviews:

- dependency closure;
- LOC and local maintenance surface;
- retry, batching, backoff, and dropped-signal observability;
- propagation fit after V-P;
- semantic conventions and SDK drift cost.

### Evidence read

Current code:

- packages/effet-otel/effet_otel.ml: 710 LOC.
- packages/effet-otel/effet_otel.mli: 65 LOC.
- Current package direct dependencies in dune-project: effet, eio, eio_main,
  yojson, and alcotest for tests.

Upstream package metadata and source survey:

- opentelemetry.0.91/opam depends on ptime, hmap, pbrt, pbrt_yojson,
  ambient-context, mtime, dune, and has optional integrations for eio, lwt,
  thread-local-storage, and tracing.
- opentelemetry-client.0.91/opam depends on matching opentelemetry and
  thread-local-storage.
- opentelemetry-client-cohttp-eio.0.91/opam adds ca-certs,
  mirage-crypto-rng, ambient-context-eio, cohttp-eio, and tls-eio.
- Upstream 0.90/0.91 changelog records HTTP/JSON support, retry with
  exponential backoff, bounded queue overhaul, batching enabled by default,
  better OTLP HTTP failure errors, and self debug/metrics for retry/drop paths.
- Upstream Span_ctx has W3C trace-context helpers and sampled flag support, but
  it is not a drop-in replacement for Effet's runtime fiber-local
  Trace_context.t.

### Lab

Created scratch/otlp_compare/.

The lab intentionally models the comparison instead of linking the upstream SDK.
That keeps the repo dependency graph unchanged and isolates the behavioral
questions. The upstream model is based on the 0.90/0.91 package/source survey,
not on a production adapter implementation.

Files:

- common.ml: shared signal, batch, result, and propagation fixtures.
- current_hand_roll_model.ml: fixed batch sizes, one POST attempt, on_error as
  the only failure signal.
- upstream_adapter_model.ml: default batching, retry attempts, bounded queue
  pressure, and self diagnostics.
- runtime_smoke.ml: collector OK/down/intermittent/slow plus W3C extract/inject
  fixture.
- results.md: short result table and recommendation.

Command:

~~~sh
nix develop -c dune exec scratch/otlp_compare/runtime_smoke.exe
~~~

Result:

~~~text
otlp_compare runtime smoke passed
~~~

### Dependency comparison

V-O7's "zero new dependencies" argument is retired.

Current effet-otel already depends on Yojson. The revised hand-roll argument is
not zero dependencies; it is a small and explicit dependency closure: effet, eio,
eio_main, and yojson at runtime.

The Eio upstream adapter path would add at least:

~~~text
opentelemetry
opentelemetry-client
opentelemetry-client-cohttp-eio
ptime
hmap
pbrt
pbrt_yojson
ambient-context
thread-local-storage
mtime
cohttp-eio
tls-eio
ca-certs
mirage-crypto-rng
ambient-context-eio
~~~

That list is acceptable for an application that already wants the upstream SDK,
but it is a large increase for a small companion exporter.

### LOC comparison

Current implementation:

~~~text
710 packages/effet-otel/effet_otel.ml
 65 packages/effet-otel/effet_otel.mli
~~~

The scratch adapter model is only 73 LOC, but that is not a real adapter. A real
adapter would still need translation from Effet span/log/metric traits into the
upstream SDK's tracer/logger/meter providers, propagation bridge code, global SDK
setup policy, and tests. The useful conclusion is narrower: upstream would
delete wire-format and transport maintenance, but not all adapter code.

### Failure behavior

This is the strongest point against the current transport.

Current effet-otel batches signals and posts once. On failure, the daemon calls
on_error if the user supplied it and then moves on. There is no retry, backoff,
bounded queue accounting, self-diagnostic stream, or built-in dropped signal
counter. The scratch model's intermittent-failure fixture drops the first batch.

The upstream SDK has the right production semantics already: bounded queues,
batching enabled by default, retry with exponential backoff, better HTTP failure
messages, and self debug/metrics. The scratch model's intermittent-failure
fixture retries and delivers.

### Propagation

V-P changes the propagation comparison.

Effet core now owns W3C traceparent, tracestate, sampled flag, and baggage
extract/inject through Trace_context. That means distributed propagation no
longer requires the upstream SDK. It also means an upstream adapter would need to
bridge Effet's fiber-local runtime context into the upstream ambient context or
choose one context owner explicitly.

The upstream library has useful W3C/span-context pieces, but adopting the full
SDK for propagation alone would duplicate a solved core problem and introduce a
second context model.

### Semantic conventions and SDK drift

The upstream SDK wins long-term spec maintenance. It tracks OTLP wire shape,
semantic convention updates, HTTP/JSON behavior, bounded queue details, retry
policy, and self diagnostics. Hand-roll means Effet owns all of those decisions.

Effet still has a reason to keep the current adapter small: the public capability
traits are already Effet-shaped, and the exporter can serialize the same runtime
context without translating through a second global SDK. The maintenance cost is
acceptable only if the wire layer stays deliberately small and we stop pretending
it is feature-complete.

### Decision diary

#### V-O7r1 - Zero-dependency rationale is invalid

Decision: supersede the V-O7 rationale. effet-otel now uses Yojson, so the
winning argument cannot be "zero new dependencies" or "hand-written JSON". The
valid remaining argument is small dependency closure plus direct integration
with Effet runtime context.

#### V-O7r2 - Do not migrate to ocaml-opentelemetry now

Decision: do not replace the current exporter with an upstream SDK adapter in
this pass. The adapter would bring a much larger dependency closure and a second
ambient context model. V-P already gives Effet the propagation capabilities that
were the most urgent SDK-shaped gap.

Deferred: a separate adapter package can still be built later for applications
that already standardize on ocaml-opentelemetry.

#### V-O7r3 - Upstream wins failure semantics

Decision: the current transport is weaker on production failure behavior. The
lab and upstream changelog agree on the gap: retry, bounded queues, backoff,
self diagnostics, and dropped-signal accounting are real capabilities, not
cosmetic SDK features. Hand-roll only remains defensible if these semantics are
added or explicitly rejected with a production rationale.

#### V-O7r4 - Propagation stays Effet-owned

Decision: keep propagation in core Effet. Trace_context.extract,
Effect.with_context, Effect.current_context, and Trace_context.inject compose
with Eio fiber-local runtime state and do not require a network/exporter
dependency. Exporters should consume this context rather than own it.

#### V-O7r5 - Recommendation

Decision: keep the hand-rolled effet-otel transport for now, but change the
roadmap. The correct follow-up is not a migration; it is a small hardening slice
that cherry-picks the upstream behaviors that matter:

- bounded retry with exponential backoff for failed POSTs;
- dropped-signal counters or callback payloads per signal kind;
- richer error payloads including signal, endpoint, attempt count, and failure;
- optional self-diagnostic hook or metrics path;
- documentation that the package is a minimal Effet-native exporter, not a full
  OTel SDK.

Implementation is intentionally not started here. This entry is the approval
point.

### Final recommendation

Recommendation (c): keep hand-roll, but cherry-pick adapter behavior.

Do not use V-O7's old wording again. The revised position is:

> effet-otel stays Effet-native because its runtime context and dependency
> closure are small. It must adopt upstream-style retry/drop diagnostics before
> being treated as production-grade transport.

### Artifacts

- scratch/otlp_compare/README.md
- scratch/otlp_compare/common.ml
- scratch/otlp_compare/current_hand_roll_model.ml
- scratch/otlp_compare/upstream_adapter_model.ml
- scratch/otlp_compare/runtime_smoke.ml
- scratch/otlp_compare/results.md

## V-LM - Logger/Meter AST survival lab

### Why this entry exists

Effet-9qk reopens V-O10/V-O11 under deletion pressure. Review 2 argued that
Effect.log and Effect.metric_update may be overbuilt as core AST constructors
because span correlation could be implemented by adapters over standard
logging/metrics ecosystems. If that adapter shape gives the same behavior with
less core surface and similar ergonomics, the AST constructors are unearned.

This pass is both research and implementation-gated. The implementation rule
was: delete or change the live code only if the lab indicates a better design.

### Goal

Compare two branches:

- Branch A: current design. Log and Metric_update are effect AST constructors
  interpreted by the runtime.
- Branch B: adapter design. The effect AST has no log/metric constructors.
  Logs go through a Logs reporter and metrics through a registry. Both read a
  fiber-local runtime observation context to correlate with the active span.

### Lab

Artifacts:

- scratch/log_meter_survival/common.ml
- scratch/log_meter_survival/branch_a_ast.ml
- scratch/log_meter_survival/branch_b_adapter.ml
- scratch/log_meter_survival/runtime_smoke.ml
- scratch/log_meter_survival/results.md

Command:

~~~sh
nix develop -c dune exec scratch/log_meter_survival/runtime_smoke.exe
~~~

Result:

~~~text
log_meter_survival runtime smoke passed
~~~

### Fixture

Both branches run the same behavioral shape:

1. Open a named span parent.
2. Emit one log record with body hello.
3. Emit one metric point named requests.
4. Assert the log and metric carry the span trace/span identifiers.

Branch B also checks that emitting outside a runtime observation context drops
the signal rather than fabricating correlation.

### LOC and dependency evidence

Scratch model LOC:

~~~text
 72 scratch/log_meter_survival/branch_a_ast.ml
126 scratch/log_meter_survival/branch_b_adapter.ml
~~~

Relevant live-code LOC:

~~~text
 32 packages/effet/logger.ml
 27 packages/effet/logger.mli
 35 packages/effet/meter.ml
 27 packages/effet/meter.mli
360 packages/effet/effect.ml
349 packages/effet/effect.mli
773 packages/effet/runtime.ml
155 packages/effet-otel/test/test_logger.ml
240 packages/effet-otel/test/test_metrics.ml
~~~

Logs is available in the current Nix shell. No metrics or prometheus package is
installed there. That matters: the logging half can be a real adapter, but the
metrics half still needs either a new dependency or an Effet-owned registry.

### Ergonomics

Branch A application code is effect-native:

~~~ocaml
Effect.named "parent"
  (Effect.log "hello"
   |> Effect.bind (fun () ->
      Effect.metric_update ~name:"requests"
        ~kind:Capabilities.Counter_monotonic (Capabilities.Int 1)))
~~~

Branch B can preserve laziness only by wrapping ordinary emissions in an effect
leaf:

~~~ocaml
Effect.named "parent"
  (Effect.sync "emit" (fun _ ->
     Logs.info (fun m -> m "hello");
     Metric_registry.record ~name:"requests" ~kind:Counter (Int 1)))
~~~

That shape proves correlation is possible, but it is not simpler. It moves the
signal API out of the effect AST and into a process-global Logs reporter plus a
metrics registry. For logs, global reporter state also has test/runtime
isolation costs that Runtime.create ?logger avoids.

### Test equivalence

The scratch fixtures pass with identical correlation assertions. The existing
ports in packages/effet-otel/test/test_logger.ml and
packages/effet-otel/test/test_metrics.ml would not pass unchanged because they
intentionally exercise Effect.log and Effect.metric_update. Branch B would
require test-body rewrites to Logs.info and registry calls.

### Decision diary

#### V-LMv1 - Logs adapter is possible

Decision: the reviewer was correct that a Logs reporter can correlate records
with the active span without a Log AST constructor. Branch B uses an Eio
fiber-local observation context and the Logs reporter API to emit a correlated
record inside a named span.

Rationale: branch_b_adapter.ml passes the same trace/span correlation fixture as
branch_a_ast.ml.

#### V-LMv2 - Metrics are not equivalent to logs

Decision: do not treat metrics as solved by the logging result. The current
environment has logs, but not a comparable metrics registry package. Branch B
therefore implements an Effet-local Metric_registry, which is conceptually the
same responsibility as the current Meter capability moved sideways.

Deferred: a future task may compare a concrete OCaml metrics package if Effet
chooses one as a dependency. This lab does not justify adding that dependency.

#### V-LMv3 - Process-global reporter state is a regression

Decision: global Logs.set_reporter is worse than runtime-local Runtime.create
?logger for Effet core semantics. Effet already treats the runtime as the owner
of interpretation, tracing, sampling, logging, and metrics. A global reporter
makes multi-runtime tests and nested runtimes harder to reason about.

Rationale: Branch B must install and restore the reporter around runtime
execution. Branch A uses the runtime value directly and needs no global state.

#### V-LMv4 - Keep Log and Metric_update AST nodes

Decision: keep Log and Metric_update as core AST constructors.

Rationale: deletion is possible but not superior. The adapter model is larger
in the scratch lab, forces test-body rewrites, introduces process-global
logging state, and still needs an Effet-owned metrics registry. The current
constructors are small, lazy until interpretation, runtime-scoped, independent
of env rows, and preserve the same effect sequencing model as the rest of the
library.

#### V-LMv5 - No live code changes required

Decision: no packages/ implementation changes are made for this task.

Rationale: the lab rejects the deletion hypothesis. The only durable artifact
needed is this journal entry plus the scratch lab. V-O10/V-O11 survive with a
better rationale: the AST nodes are not there because span correlation is
impossible otherwise; they are there because the effect runtime is the right
owner for these runtime-scoped signals.

### Final recommendation

Recommendation (a): keep the current AST nodes with documented reason.

Do not migrate Effect.log to Logs.info or Effect.metric_update to a separate
metrics registry in core Effet. Adapters can still be added later as interop
conveniences, but they should not replace the effect-native operations.

## V-Sh - effet-stream hardening before release

### Why this entry exists

Effet-zx5 reopens the stream package after external review. The research shape
survived, but the package implementation still had release-blocking skeletons:
`merge` was sequential `concat`, `flat_map_par` was sequential
`flat_map`, `from_file` and `from_eio_stream` returned empty streams, and
there were no package-level tests.

This entry records the implementation hardening done before treating
`effet-stream` as a real package surface.

### Goal

Close the concrete gaps named by Effet-zx5:

- downstream early `take` closes a file source;
- `merge` runs concurrent producers and cancels upstream when downstream stops;
- `flat_map_par` runs bounded-concurrent inner streams;
- bounded internal queues do not deadlock when downstream stops;
- object-row env and polymorphic-variant error rows survive composition.

### Implementation

The package moved from whole-list materialization to a stop-aware monadic fold.
Each source/operator receives an `emit` callback that returns the updated sink
state plus a boolean saying whether upstream should continue. `take` now stops
upstream instead of collecting all values and slicing afterward.

`Stream.merge` is now a real concurrent operator. It starts both producers
under `Effet.Supervisor.scoped`, forwards values through a bounded Eio queue,
and sets a stop flag before cancelling producer children when downstream
finishes early.

`Stream.flat_map_par` now uses a bounded outer queue, fixed worker fibers, and
a bounded output queue. The outer producer feeds values to workers; each worker
runs inner streams and forwards items to the downstream consumer. The
`max_concurrency` semaphore shape from the placeholder was replaced with
actual worker ownership under the Effet supervisor scope.

`Stream.from_file` is implemented as a v0 whole-file source using
`Eio.Path.load`, emitting one `bytes` chunk. That is enough to prove descriptor
closure under `take 1`, but it is deliberately not yet an incremental byte
stream.

### Tests

New package tests live in `packages/effet-stream/test/test_effet_stream.ml`.

Focused command:

~~~sh
nix develop -c dune runtest packages/effet-stream --force
~~~

Result:

~~~text
Test Successful in 0.513s. 6 tests run.
~~~

Covered fixtures:

- A/B/C scenario: integer source, map `* 2`, `take 5`, fold sum = 30.
- `take_then_close`: `from_file |> take 1 |> drain` does not increase
  `/proc/self/fd` count.
- `merge_cancellation`: `merge` plus downstream `take 1` stops both large
  delayed producers before full production.
- `flat_map_par_concurrency`: 100 inner streams each delay 50ms; with
  `max_concurrency:10`, total runtime stays below 2s instead of the sequential
  5s shape.
- `bounded_queue_no_deadlock`: delayed producers plus downstream early stop
  complete under a 1s timeout.
- `row_polymorphism`: a clock+db pipeline through `merge` and
  `flat_map_par` is locked with a module signature requiring
  `< clock : Capabilities.clock; db : db; .. >` and error row
  `[> `Negative]`.

### Decision diary

#### V-Shv1 - Replace list materialization with stop-aware folding

Decision: `run` is now based on a monadic fold that can stop upstream. The
previous `effect_list` interpreter made early termination impossible because
operators such as `take` ran only after the entire stream was collected.

Rationale: the new `take_then_close` and merge cancellation fixtures would not
be meaningful under the old collect-then-slice model.

#### V-Shv2 - Implement merge as supervised producers plus queue

Decision: `merge` is no longer `concat`. It forks both producers under the
current Effet runtime via `Supervisor.scoped`, forwards items through an Eio
queue, and cancels producers when the downstream fold returns stop.

Rationale: the `merge_cancellation` test observes that both large upstream
sources stop before producing all 1000 values.

#### V-Shv3 - Implement flat_map_par with bounded workers

Decision: `flat_map_par` is no longer sequential `flat_map`. It uses a
bounded outer queue and fixed worker fibers; at most `max_concurrency` inner
streams are active.

Rationale: the timing fixture uses 100 inputs with 50ms inner delays and
`max_concurrency:10`. The test completes below 2s, which excludes the old
sequential 5s behavior.

#### V-Shv4 - Keep from_file whole-file in v0, document it

Decision: `from_file` now works and closes, but it emits one whole-file
`bytes` chunk. Incremental byte chunks are deferred.

Rationale: the release blocker was the empty placeholder and close behavior
under early take. The package now passes that test. A chunk-size API should not
be invented until the byte-stream use case is clearer.

#### V-Shv5 - Eio.Stream interop is prefix-oriented

Decision: `from_eio_stream` pulls from an existing Eio queue but does not
invent an end-of-stream marker. Callers own producer lifetime and should use
`take` for finite prefixes.

Rationale: Eio.Stream itself has no close/end signal. Adding one in Effet would
change ownership semantics. The README now calls this out as a v0 footgun.

#### V-Shv6 - Stream rows survive concurrent composition

Decision: the stream package keeps Effet's env/error channel discipline through
concurrent operators. No separate stream error model was introduced.

Rationale: the row-polymorphism test locks a `merge` plus `flat_map_par`
pipeline to the expected object-row env and polymorphic-variant error row.

### Deferred

- `from_file` is not yet an incremental byte stream.
- `from_eio_stream` has no end-of-stream sentinel; callers must bound prefix
  consumption or provide a producer that continues.
- The current `merge` and `flat_map_par` queues are bounded implementation
  details, not public tuning parameters.

### Artifacts

- packages/effet-stream/effet_stream.ml
- packages/effet-stream/effet_stream.mli
- packages/effet-stream/README.md
- packages/effet-stream/test/dune
- packages/effet-stream/test/test_effet_stream.ml

## V-Rs - Resource module survival lab

### Why this entry exists

Effet-6yf reopens the Resource module under deletion pressure. Review 2 argued
that Resource may be decorative: a cached effectful loader can be written with
an Atomic.t cell, Effect.sync, Effect.bind, and a scheduled background refresh.
If that replacement is equally clear and uses public primitives, Resource does
not earn a separate public module.

The current code is not the same code the original criticism saw. Public
Effect.detach has already been removed. Resource.auto now uses the internal
Effect.Private.daemon primitive and Resource.failures records typed refresh
failures as Cause.t values.

### Goal

Compare two branches against the existing Resource behavioral slice:

- Branch A: keep packages/effet/resource.ml as today.
- Branch B: implement the cached-loader recipe directly with Atomic.t and
  Effect primitives.

Behavioral requirements:

- manual refresh updates cached value;
- failed manual refresh keeps the last good value;
- auto refresh follows a schedule;
- failed auto refresh keeps the last good value, invokes on_error, and records
  the typed failure in a failure sink.

### Lab

Artifacts:

- scratch/resource_survival/common.ml
- scratch/resource_survival/branch_a_resource.ml
- scratch/resource_survival/branch_b_atomic.ml
- scratch/resource_survival/runtime_smoke.ml
- scratch/resource_survival/results.md

Command:

~~~sh
nix develop -c dune exec scratch/resource_survival/runtime_smoke.exe
~~~

Result:

~~~text
resource_survival runtime smoke passed
~~~

### LOC and shape comparison

~~~text
 47 packages/effet/resource.ml
 27 packages/effet/resource.mli
  9 scratch/resource_survival/branch_a_resource.ml
 61 scratch/resource_survival/branch_b_atomic.ml
127 scratch/resource_survival/runtime_smoke.ml
~~~

Branch B is not shorter than the current implementation. It is nearly the same
algorithm, written at each call site or in an application-local helper. The
important line is not the Atomic.t cell; it is this one:

~~~ocaml
Effect.Private.daemon (refresh_loop resource 0)
~~~

After public detach removal, an app cannot express Resource.auto using only the
ordinary public Effect surface without either using Private or owning its own
Eio fiber/switch outside Effect. That is the real survival criterion.

### Ergonomics

Branch A call site:

~~~ocaml
Resource.auto ~load ~schedule:(Schedule.spaced (Duration.ms 5)) ()
~~~

Branch B call site requires introducing a local resource record, cache cell,
failure cell, refresh loop, catch path, and daemon ownership. That is acceptable
inside Effet, but poor as repeated application boilerplate.

Manual cached loading alone is recipe-sized. Auto-refresh is not.

### Failure isolation

Both branches preserve the important behavior: failed refresh does not replace
the last good value. Both branches record the failed auto-refresh as
Cause.Fail err before invoking on_error.

That behavior does not fall out of Atomic.t. It comes from the refresh protocol:
only update after a successful load, catch refresh failures in the daemon loop,
and record them in a typed sink. Keeping Resource makes that protocol the
single audited implementation.

### Thread-safety

Branch B uses Atomic.t and therefore makes the cache cell explicit. The current
Resource uses mutable fields and refs, which is sufficient for the current Eio
single-runtime usage tested here. This lab does not prove a multi-domain
Resource contract, and Effet does not otherwise document one.

Decision: do not widen Resource's contract to domain-safe caching in this
survival task. If Effet later promises cross-domain sharing, Resource should be
revisited with explicit Atomic/locking tests.

### Decision diary

#### V-Rsv1 - Manual Resource is a recipe

Decision: manual cached loading by itself does not justify a module. The lab
shows the manual get/refresh behavior is straightforward with an option cell
and Effect.map/bind.

Rationale: branch_b_atomic.ml reproduces manual refresh and failed manual
refresh behavior without special runtime support.

#### V-Rsv2 - Resource.auto is not public-userland code

Decision: Resource.auto earns a library seam. The replacement branch can only
match auto-refresh by calling Effect.Private.daemon. That primitive exists so
packages can own runtime-daemon behavior without restoring public detach.

Rationale: branch_b_atomic.ml line using Effect.Private.daemon is the same
lifecycle dependency as packages/effet/resource.ml. Removing Resource would
push users toward Private or raw Eio fibers for the exact behavior Effet already
centralizes.

#### V-Rsv3 - Keep last-good and failure history centralized

Decision: keep the failure-isolation protocol in Resource. The behavior is small
but subtle enough to centralize: successful loads update the cache, failed
refreshes preserve last-good, auto refresh records Cause.Fail err, and on_error
remains compatibility side-effect evidence.

Rationale: both branches pass the same fixture, but Branch B duplicates the
same catch/update/history protocol.

#### V-Rsv4 - Do not replace Resource with documentation-only recipe

Decision: do not delete Resource. A recipe doc would be acceptable for manual
caches, but it would either omit auto-refresh or teach users to use the Private
daemon escape hatch.

Rationale: that would weaken the public/private boundary established by the
detach deletion work.

#### V-Rsv5 - No live implementation change

Decision: no packages/ code change is required from this survival lab.

Rationale: Resource survives. The Atomic.t replacement did not expose a better
implementation target for today's documented runtime model. The existing test
suite already covers the retained behavior.

### Final recommendation

Recommendation (a): keep Resource with a narrowed rationale.

Resource is not a general Effect-TS Resource port and should not be documented
as one. It is the Effet-owned cached-loader abstraction for a runtime-owned
auto-refresh loop with last-good semantics and typed refresh-failure history.
Manual-only caches remain simple enough to write by hand, but auto-refresh
belongs in the library.

## V-Shf - Stream.from_file public hardening

### Why this entry exists

The first stream hardening pass made `from_file` safe enough not to leak, but it
kept a whole-file `Eio.Path.load` implementation and explicitly deferred
incremental chunks. That was acceptable only as a v0 placeholder. A public
`effet-stream` byte source cannot read the entire file before downstream gets a
chance to stop.

This entry supersedes V-Shv4.

### Goal

Harden `Stream.from_file` until it is fit for the public stream API: chunked
reading, bounded memory, descriptor cleanup on normal completion, early
termination, typed downstream failure, and clear documentation of file I/O
failure semantics.

### Implementation shape

`Stream.from_file ?chunk_size path` now stores the chunk size in the stream AST.
When interpreted, it starts one supervised producer fiber. The producer opens the
file with `Eio.Path.with_open_in`, reads with `Eio.Flow.single_read` into a
fixed Cstruct buffer, copies each read into a fresh `bytes` chunk, and pushes
chunks through a bounded internal queue.

Completion is signalled with an `Eio.Promise`, not a queue sentinel. That matters
because finalization must not block trying to enqueue `Done` when downstream has
already failed or the supervisor is cancelling the reader. Downstream `take` sets
a stop flag and cancels the child reader; normal EOF awaits the child so read
errors still surface through Effet's `Cause.Die` path.

### Evidence

Focused command:

~~~sh
nix develop -c dune runtest packages/effet-stream --force
~~~

Result:

~~~text
11 tests run, all OK
~~~

New file-specific tests:

- `from_file emits bounded chunks`: a 7-byte file with `chunk_size:3` emits
  `["abc"; "def"; "g"]`.
- `take from_file closes`: a 1 MiB file read with `chunk_size:4096` and
  `take 1` returns exactly one 4096-byte chunk and does not increase fd count.
  The previous `Path.load` implementation would have returned the whole 1 MiB
  file as the first chunk.
- `from_file rejects invalid chunk size`: `chunk_size <= 0` is rejected at
  construction with `Invalid_argument`.
- `from_file missing path dies`: Eio file exceptions enter the unchecked
  `Cause.Die` channel rather than inventing a stream-specific typed error.
- `from_file take zero is lazy`: `take 0 (from_file missing_path)` succeeds
  without opening the file.
- `from_file downstream failure closes`: a typed failure in the downstream
  consumer returns the typed failure, completes within the timeout, and does not
  leak descriptors.

### Decision diary

#### V-Shfv1 - from_file is chunked now

Decision: `from_file` is no longer a whole-file source. It emits bounded
`bytes` chunks with a default 64 KiB chunk size and an explicit `?chunk_size`
parameter.

Rationale: the old placeholder violated stream backpressure. The bounded-chunk
test and the 1 MiB `take 1` test prove the consumer can observe a prefix without
forcing a full file load.

#### V-Shfv2 - one supervised producer owns the file descriptor

Decision: the file descriptor lives inside one supervised reader child. The
consumer owns cancellation by setting a stop flag and cancelling that child when
downstream stops early.

Rationale: this keeps the implementation aligned with Effet's structured
concurrency rule. No background file reader exists outside a supervisor scope,
and `with_open_in` closes the file on EOF, exceptions, or cancellation.

#### V-Shfv3 - completion is a promise, not a queue sentinel

Decision: `from_file` uses a bounded queue only for chunks and an `Eio.Promise`
for producer completion.

Rationale: a queue sentinel makes finalization potentially blocking if the
consumer has already failed and stopped draining. A promise gives a nonblocking
completion signal while still allowing the consumer to drain any chunk already
queued before EOF.

#### V-Shfv4 - file I/O exceptions remain defects

Decision: `from_file` does not add a stream-specific file error row. Missing
files and other Eio I/O exceptions currently surface as `Cause.Die`.

Rationale: Effet's typed error channel is application-owned. A public file
source that guesses a portable typed I/O error algebra would be more API than
the stream package has earned. Callers that need typed file errors can check or
open at their own boundary and map that effect into their error row.

#### V-Shfv5 - take 0 is lazy

Decision: `take 0` does not interpret its source, so `take 0 (from_file path)`
does not open `path`.

Rationale: this preserves pull semantics and matters for resource safety. The
missing-path fixture verifies it.

### Artifacts

- packages/effet-stream/effet_stream.ml
- packages/effet-stream/effet_stream.mli
- packages/effet-stream/README.md
- packages/effet-stream/test/test_effet_stream.ml
- dune-project
- effet-stream.opam

## V-Shfe - Stream.from_file typed file errors

### Why this entry exists

V-Shfv4 kept file I/O failures as `Cause.Die` defects. That was a placeholder,
not a final API. Eio's own exception docs say `Eio.Io` is used for interaction
with the outside world and "does not generally indicate a bug in the program".
That makes defect-only file errors the wrong default for a typed-effect stream
source.

This entry supersedes V-Shfv4.

### Goal

Find the final public `Stream.from_file` error API and implement it.

### Lab

Created `scratch/from_file_research/`.

Candidates:

- F-A typed default: `from_file` fails with
  `` `File_error of file_error``.
- F-B mapper-only: caller supplies `file_error -> 'err`.
- F-C unsafe/exn: file I/O exceptions stay defects.
- F-D pre-opened flow: caller supplies an already-open Eio flow.

Command:

~~~sh
nix develop -c dune exec scratch/from_file_research/runtime_smoke.exe
~~~

Result:

~~~text
from_file_research runtime smoke passed
~~~

Evidence:

- F-A exposes missing file as a typed `File_error` with `kind = `Not_found` and
  `operation = `Open`, and recovery can be written directly.
- F-B maps the same public `file_error` into an application error variant.
- F-C raises raw `Eio.Io`; typed recovery is impossible at the stream boundary.
- F-D is useful future interop, but it cannot own open errors because the file
  is already open before the stream exists.

### Decision diary

#### V-Shfe1 - File I/O failures are typed failures, not defects

Decision: `Stream.from_file` now returns
`('env, [> `File_error of Stream.file_error ], bytes) Stream.t`.

Rationale: file not found, permission denied, and read errors are expected
environmental failures. They belong in Effet's typed error channel. Defects are
reserved for bugs and unexpected exceptions.

#### V-Shfe2 - Keep a public file_error record

Decision: expose `Stream.file_error` with `operation`, `path`, `kind`, `message`,
and `cause`.

Rationale: callers need stable matching for common branches such as
`Not_found`, while diagnostics still need the original Eio exception and
formatted message. The coarse `kind` avoids forcing user code to pattern-match
directly on backend-specific Eio exception details.

#### V-Shfe3 - Provide an explicit mapper

Decision: add `Stream.from_file_map_error`.

Rationale: typed default is best for quick use, but real applications often
want their own error algebra. A mapper avoids making every application expose
Effet Stream's public variant in its top-level error type.

#### V-Shfe4 - Do not ship unsafe as the default

Decision: no defect-only `from_file` remains as the public default.

Rationale: the lab's unsafe candidate only makes sense when a caller explicitly
wants exceptions. Effet should not make ordinary I/O failures unrecoverable by
default.

#### V-Shfe5 - Pre-opened flow is separate future interop

Decision: do not fold the pre-opened-flow candidate into this change.

Rationale: it has a different ownership contract. It may be useful for byte-flow
interop, but it cannot solve `from_file` open errors and should not complicate
the file source API.

### Implementation

Implemented:

- `Stream.file_operation`
- `Stream.file_error_kind`
- `Stream.file_error`
- `Stream.pp_file_error`
- typed default `Stream.from_file`
- custom mapper `Stream.from_file_map_error`

Runtime behavior:

- open/read/close Eio errors become typed file errors;
- cancellation still propagates as interruption;
- downstream typed failures are not wrapped;
- `take 0` remains lazy;
- early `take` still cancels the supervised reader and closes the descriptor.

### Verification

Focused command:

~~~sh
nix develop -c dune runtest packages/effet-stream --force
~~~

Result:

~~~text
13 tests run, all OK
~~~

New typed-error tests:

- `from_file missing path fails typed`
- `from_file error is recoverable`
- `from_file maps file error`

## Effet-9ey - typed request DSL over OCaml native effects

### Why this entry exists

Review 1 finding #4 reopened R-D. V-R10 rejected OCaml 5 native effects because raw handlers do not statically track which handlers are installed; forgetting a handler compiles and crashes with `Effect.Unhandled`. That rejection was correct for raw handlers, but it did not test a typed request DSL layered over native effects.

This entry tests that missing candidate.

### Goal

Decide whether a typed `Req.t`/handler DSL over native effects can compete with the current object-row R-channel.

The success bar is V-R10's bar:

- `a` calls `b` and `c`;
- `b` needs Log, `c` needs Db;
- `a` is defined without mentioning services in its body or argument list;
- the inferred type carries transitive requirements;
- missing handlers are compile-time errors.

### Lab

Created `scratch/native_effects_research/`.

Candidates:

- `r_d_raw.ml`: raw OCaml 5 native handlers, matching the original R-D dismissal.
- `r_d_typed.ml` / `Presence_set`: request witnesses plus a phantom HList of required handlers.
- `r_d_typed.ml` / `Scoped_token`: handler scopes create lexical tokens, and `ask` requires the token.

Positive command:

~~~sh
nix develop -c dune exec scratch/native_effects_research/runtime_smoke.exe
~~~

Result:

~~~text
native_effects_research runtime smoke passed
~~~

LOC comparison:

~~~text
   69 scratch/r_research/r_b_env_row.ml
   78 scratch/r_research/r_d_native_handlers.ml
   62 scratch/native_effects_research/r_d_raw.ml
  224 scratch/native_effects_research/r_d_typed.ml
~~~

### Negative tests

Presence-set missing handler:

~~~sh
nix develop -c env NATIVE_EFFECTS_NEG=presence_missing_handler \
  dune build scratch/native_effects_research/neg_presence_missing_handler.exe
~~~

Observed:

~~~text
File "scratch/native_effects_research/neg_presence_missing_handler.ml", line 11, characters 23-54:
11 |   run (HDb (db, HNil)) (a db_witness log_witness "42")
                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: This expression has type (both, [> `Db_err ], string) t
       but an expression was expected of type ((db_cap, nil) cons, 'a, 'b) t
       Type both = db_cap * (log_cap, nil) cons is not compatible with type
         (db_cap, nil) cons = db_cap * nil
       Type (log_cap, nil) cons = log_cap * nil is not compatible with type
         nil
~~~

Scoped-token ask outside handler:

~~~sh
nix develop -c env NATIVE_EFFECTS_NEG=token_ask_without_scope \
  dune build scratch/native_effects_research/neg_token_ask_without_scope.exe
~~~

Observed:

~~~text
File "scratch/native_effects_research/neg_token_ask_without_scope.ml", line 9, characters 12-14:
9 | let _ = ask Db
                ^^
Error: This variant expression is expected to have type 'a token
       There is no constructor Db within type token
~~~

### Cross-tabulation

| Property | R-B env-row | R-D raw | R-D presence-set | R-D scoped-token |
|---|:---:|:---:|:---:|:---:|
| A body mentions zero services | yes | yes | yes | yes |
| A argument list mentions zero services | yes | yes | no | no |
| Type carries transitive requirements | yes | no | yes | no |
| Missing handler compile-time failure | yes | no | yes, at run | yes, at ask |
| Handler/witness order leaks into user API | no | no | yes | no |
| Explicit token threading leaks into user API | no | no | no | yes |
| Runtime uses native effects | no | yes | yes | yes |

### Decision diary

#### V-RNv1 - Raw R-D remains rejected

Decision: raw OCaml 5 native effects do not satisfy the R-channel contract.

Rationale: `r_d_raw.ml` keeps the best R-D ergonomics, but `unsafe_boot_no_handler` compiles and raises `Effect.Unhandled` at runtime. This is the same safety failure V-R10 observed.

#### V-RNv2 - Presence-set R-D recovers safety but loses the dividend

Decision: the phantom presence-set design is type-safe but not competitive.

Rationale: `Presence_set` rejects a missing Log handler at compile time, but only after introducing capability tags, membership witnesses, an ordered handler HList, and explicit witness arguments to `a`. The user-visible signature is:

~~~ocaml
val a :
  (need, db_cap) has ->
  (need, log_cap) has ->
  string ->
  (need, [> `Db_err ], string) t
~~~

That is a second dependency language. It is more complex than object rows and does not preserve V-R10's "A argument list mentions zero services" property.

#### V-RNv3 - Scoped-token R-D makes ask safe by making dependencies explicit

Decision: lexical tokens are safe but collapse back into explicit dependency passing.

Rationale: `Scoped_token.ask Db` without a token fails to compile. That proves the "ask without handle" property can be enforced. The cost is that every service-using function accepts tokens:

~~~ocaml
val a :
  db_token token ->
  log_token token ->
  string ->
  ([> `Db_err ], string) t
~~~

This is not an R-channel replacement. It is explicit argument passing with native-effect implementation behind the token.

#### V-RNv4 - Hidden witnesses are the failing point

Decision: the lab did not find a way to hide request witnesses while retaining static handler installation.

Rationale: if witnesses are hidden, the program can describe a request but the boot boundary cannot prove that the matching native handler is installed. If witnesses are exposed, users manage HList order or token threading. Object rows avoid both costs because OCaml already has structural row inference for method requirements.

#### V-RNv5 - Final recommendation

Decision: keep R-D rejected, but refine the rationale.

The earlier rejection was too narrow if it only said "native handlers have no effect rows". A typed DSL can add static evidence. The reason not to adopt it is that the static evidence is worse than the current object-row R-channel: more LOC, more concepts, worse signatures, and no preservation of V-R10's zero service-argument property.

No live library code change is recommended.

### Artifacts

- `scratch/native_effects_research/r_d_raw.ml`
- `scratch/native_effects_research/r_d_typed.ml`
- `scratch/native_effects_research/neg_presence_missing_handler.ml`
- `scratch/native_effects_research/neg_token_ask_without_scope.ml`
- `scratch/native_effects_research/runtime_smoke.ml`

## Effet-hpt / Effet-yp5 / Effet-vp8 survival pass

### Why this entry exists

These three small review findings were API-width checks. Each asks whether a surface exists because it has a semantic job, or because it was copied from Effect-TS / early prototypes.

- Effet-hpt: `Sync` and `Async` leaves had identical runtime behavior.
- Effet-yp5: `Duration.t` needed justification over plain `int_ms`.
- Effet-vp8: `ppx_effet` needed evidence and edge-case coverage or removal.

### Effet-hpt - single leaf and final name

Lab artifact: `scratch/sync_async_survival/`.

Before the change, runtime interpretation of `EP.Sync` and `EP.Async` was identical: both called the callback in the current interpreter fiber, both auto-instrumented the same way, and neither introduced scheduling, yielding, cancellation, or blocking semantics.

Naming decision: `sync` and `async` are both the wrong axis for OCaml/Eio. Eio has no function-color split, and this leaf is not an async boundary. The chosen public name is:

~~~ocaml
val thunk : string -> ('env -> 'a) -> ('env, 'err, 'a) Effect.t
~~~

Rationale: `thunk` says exactly what is stored: a deferred OCaml callback. It does not imply a scheduler boundary, and it does not imply immediate evaluation. `leaf` remains the internal concept, but it is too AST-jargony for user code.

Implemented:

- internal constructor/view is `Thunk`;
- public `Effect.thunk` replaces `Effect.sync`;
- public `Effect.async` is removed, with no alias;
- `[%effet.thunk ...]` replaces `[%effet.sync ...]`;
- `[%effet.async ...]` is removed.

Negative PPX check from `scratch/ppx_survival/neg_async_removed.ml`:

~~~text
File "scratch/ppx_survival/neg_async_removed.ml", line 6, characters 10-21:
6 | let _ = [%effet.async "removed" ()]
              ^^^^^^^^^^^
Error: Uninterpreted extension 'effet.async'.
~~~

#### V-SAv1 - Collapse Sync and Async

Decision: collapse the leaves. There is only `Thunk`.

Rationale: no test or runtime branch could defend separate constructors. Keeping both would encode a semantic distinction the interpreter does not have.

#### V-SAv2 - Use thunk, not sync

Decision: expose `Effect.thunk`.

Rationale: `sync` is an Effect-TS/JavaScript-coloring word and `async` is worse. In OCaml/Eio the callback is ordinary OCaml code evaluated by the Effet interpreter in the current fiber. `thunk` is the strongest name because it describes the deferred callback without suggesting scheduling or immediate evaluation.

#### V-SAv3 - No compatibility alias

Decision: do not keep `Effect.async`, `Effect.sync`, `[%effet.async]`, or `[%effet.sync]` aliases.

Rationale: this project is still in design phase. Backward compatibility would preserve obsolete vocabulary and force future docs to explain names we already know are wrong.

### Effet-yp5 - Duration survival

Lab artifact: `scratch/duration_survival/`.

The lab implements the same small Schedule subset twice: once with a `Duration.t` newtype and once with plain `int` milliseconds.

Command:

~~~sh
nix develop -c dune exec scratch/duration_survival/runtime_smoke.exe
~~~

Result:

~~~text
duration_survival runtime smoke passed
~~~

LOC comparison:

~~~text
48 scratch/duration_survival/duration_keep.ml
51 scratch/duration_survival/int_ms_branch.ml
~~~

The int branch does not reduce complexity in Schedule. It does lose the public unit boundary: `delay 3 value` compiles in the int branch, while the current API requires `Duration.ms 3` or `Duration.seconds 3`.

#### V-Dv1 - Keep Duration.t

Decision: keep `Duration.t`.

Rationale: the type catches unit mistakes at the API boundary and keeps call sites readable. Schedule still needs add/scale/min/max either way, so replacing the module with bare `int` does not materially simplify the implementation.

#### V-Dv2 - Do not switch to Eio spans

Decision: do not expose Eio/Mtime span types in Effet's public core API.

Rationale: Effet's public time algebra is deliberately small and test-clock friendly. Eio integration remains inside Runtime/Capabilities; user code should not need to import Eio time types to express an Effet delay or schedule.

#### V-Dv3 - Keep algebra small

Decision: `Duration.t` survives, but it should remain a small nonnegative millisecond type.

Rationale: this lab does not justify adding Effect-TS Duration features. It only justifies retaining the unit-safe wrapper and the operations Schedule actually uses.

### Effet-vp8 - PPX survival

Lab artifact: `scratch/ppx_survival/`.

`explicit_idiom_fixture.ml` contains 27 representative definitions, including 20+ instrumented functions using explicit `Effect.fn __POS__ __FUNCTION__ body`. The explicit form is tolerable for occasional use but noisy when every leaf or public function is instrumented.

`runtime_smoke.ml` runs PPX-expanded cases under an in-memory tracer and checks the generated function names for:

- top-level function;
- nested function;
- anonymous lambda;
- partial application;
- local module;
- thunk leaf;
- env builder.

Command:

~~~sh
nix develop -c dune exec scratch/ppx_survival/runtime_smoke.exe
~~~

Result:

~~~text
ppx_survival runtime smoke passed
~~~

Observed lambda naming:

~~~text
Ppx_survival__Golden_cases.anonymous_lambda.(fun)
~~~

That is acceptable and explicit: PPX does not invent a nicer name for anonymous code.

#### V-Pxv1 - Keep ppx_effet

Decision: keep the optional PPX.

Rationale: the explicit idiom is mechanical but repetitive. The PPX expands to ordinary `Effect.fn`, `Effect.thunk`, and object expressions; it does not infer services or introduce hidden DI.

#### V-Pxv2 - Narrow the PPX surface

Decision: PPX keeps only `[%effet.fn]`, `[%effet.thunk]`, and `[%effet.env]`.

Rationale: `[%effet.async]` and `[%effet.sync]` carry the removed vocabulary. The negative test proves `[%effet.async]` is gone.

#### V-Pxv3 - Golden coverage becomes semantic coverage

Decision: use runtime semantic checks for the expansion edge cases.

Rationale: Dune's stored `.pp.ml` artifact is not a stable text golden in this setup, but the behavior we care about is stable: source location/function-name instrumentation and env binding. The smoke test checks those semantics directly.

### Verification

Focused commands run during this pass:

~~~sh
nix develop -c dune build packages/effet packages/effet-stream packages/effet-schema packages/effet-otel packages/ppx_effet scratch/ppx_survival scratch/duration_survival
nix develop -c dune exec scratch/duration_survival/runtime_smoke.exe
nix develop -c dune exec scratch/ppx_survival/runtime_smoke.exe
nix develop -c dune runtest packages/ppx_effet --force
nix develop -c env PPX_SURVIVAL_NEG=async_removed dune build scratch/ppx_survival/neg_async_removed.exe
~~~

## Effet-rmy / Effet-3z2 edge-case test pass

### Why this entry exists

Two review-remediation tasks asked for tests, not new API surface:

- Effet-rmy: establish the observable baseline for simultaneous child failures and finalizer failures during fail-fast cancellation in `par`, `all`, and `for_each_par`.
- Effet-3z2: establish the observable baseline for uninterruptible edge cases: nested masks, blocking finalizers, timeout inside a protected region, and race losers without cancellation checkpoints.

The purpose is regression coverage and semantic evidence for later runtime work. These tests deliberately assert observed behavior, including one behavior that is probably not the final desired design.

### Artifacts

All tests were added to `packages/effet/test/test_effet.ml`.

New failure-baseline tests:

- `test_par_simultaneous_failures_records_concurrent_baseline`
- `test_par_finalizer_failure_during_sibling_cancellation`
- `test_all_finalizer_failure_during_sibling_cancellation_baseline`
- `test_for_each_par_simultaneous_failures_baseline`
- `test_for_each_par_finalizer_failure_during_sibling_cancellation`
- `test_par_nested_race_all_failures_baseline`

New uninterruptible edge-case tests:

- `test_uninterruptible_nested_masks_wait_for_protected_loser`
- `test_uninterruptible_blocking_finalizer_delays_race_completion`
- `test_uninterruptible_timeout_inside_protected_still_fires`
- `test_uninterruptible_race_loser_without_checkpoints_returns`

### Observed baseline

Simultaneous failure behavior is observable today. `par` and `for_each_par` can return `Cause.Concurrent` when multiple children are released from a barrier and fail before cancellation collapses the group. A nested `race` whose branches all fail also propagates its `Cause.Concurrent` through `par`.

The first `all` finalizer fixture was under-specified: the fast body failure could win before the sibling had acquired its scoped resource, so there was no registered finalizer to preserve. The tightened fixture now gates the body failure on sibling acquisition. With that precondition, `par`, `all`, and `for_each_par` all preserve the cancelled sibling's failing finalizer as a suppressed failure under interrupt inside the returned `Cause.Concurrent`.

Uninterruptible behavior is stable under the new fixtures:

- nested `uninterruptible` regions compose; the protected loser completes before `race` returns the already-known winner;
- a blocking finalizer inside a protected loser delays `race` completion until the finalizer finishes;
- `timeout` inside an uninterruptible region still fires, because it is an internal timeout race rather than an external cancellation;
- a protected race loser without ordinary cancellation checkpoints can return without deadlocking, and the race winner remains preserved.

### Decision diary

#### V-Ecv1 - Concurrent child failures are reachable

Decision: keep tests that assert `Cause.Concurrent` is reachable from `par`, `for_each_par`, and nested `race`.

Rationale: this confirms the structured Cause algebra is not dead surface. Concurrent causes are observable when multiple child failures happen inside the cancellation window.

#### V-Ecv2 - Acquired sibling finalizer failures are preserved

Decision: guarantee the acquired-resource case with regression tests across `par`, `all`, and `for_each_par`.

Rationale: once the cancelled sibling has acquired and registered a finalizer, the runtime already waits for cleanup before returning and records the finalizer failure as `Suppressed { primary = Interrupt; finalizer = Fail "release" }` inside `Concurrent`. The apparent gap was a fixture bug, not a runtime bug.

#### V-Ecv3 - Uninterruptible masks compose by deferring external cancellation

Decision: keep the uninterruptible edge-case tests as regression coverage.

Rationale: nested masking, blocking protected finalizers, timeout inside protected work, and no-checkpoint losers all now have explicit behavioral assertions. This makes future runtime refactors safer.

### Verification

Focused commands run during this pass:

~~~sh
nix develop -c dune exec packages/effet/test/test_effet.exe -- test Effect 29-34 --show-errors
nix develop -c dune exec packages/effet/test/test_effet.exe -- test Effect 40-44 --show-errors
nix develop -c dune runtest --force
~~~

## V-Diag - Cause.Die diagnostic context

### Why this entry exists

Effet-tzj reopened unchecked defects. The structured Cause work made `Die` a real
leaf in the public failure tree, but its payload still only carried an exception and
optional raw backtrace. That was not enough for production debugging: a defect inside a
named and annotated effect should say where it happened in Effet terms, not only where
OCaml raised.

### Goal

Decide and implement the final diagnostic shape for `Cause.Die`: backtrace capture,
source/span context, annotation propagation, runtime cost control, and OTel exception
event mapping.

### Context read

Relevant current facts:

- V-RCv adopted structured `Cause.t`: `Fail`, `Die`, `Interrupt`, `Sequential`,
  `Concurrent`, and `Suppressed`.
- `Effect.fn` is defined as `here_attr __POS__` plus `named`, so source location is
  already represented as an annotation.
- `Runtime` already caught defects and used `Printexc.get_raw_backtrace`, but the public
  `Die` payload was anonymous and had no span/annotation context.
- Span attributes live in the tracer, but defects must remain inspectable even when the
  sampler is off or the tracer is noop.

### Evidence

The implementation pass used live runtime tests rather than a detached scratch model,
because the important question was whether diagnostics survive the real interpreter
boundaries where Eio fiber-local bindings unwind.

New focused fixtures:

- `die captures diagnostics`: a failing `Effect.thunk` wrapped in `Effect.fn` and
  `Effect.annotate`, with the sampler forced off, still returns `Cause.Die` with the
  active name, loc annotation, custom annotation, and backtrace.
- `die backtrace capture flag`: `Runtime.create ~capture_backtrace:false` returns a
  `Die` with `backtrace = None`.
- `run_exn preserves backtrace`: `Runtime.run_exn` re-raises a `Die` with the captured
  raw backtrace instead of creating a fresh raise site.
- `concurrent child die captures diagnostics`: two forked `par` children fail together
  and each `Die` keeps its child span name and branch annotation.
- `finalizer die captures diagnostics`: a failing scoped body plus a failing release
  effect preserves diagnostics on both the primary `Die` and suppressed finalizer `Die`.
- `auto instrument failure status`: an auto-instrumented failing thunk span now records
  an exception event with `exception.stacktrace`.
- `exception stacktrace` in `packages/effet-otel/test/run.ml`: OTLP/JSON export contains
  an exception event with an `exception.stacktrace` attribute and propagated Effet
  annotation attributes.

A useful bug surfaced during the first test run: capturing context in `Named` but then
re-raising the original exception was not enough. The outer `Runtime.run` caught the
exception after the diagnostic fiber-local context had unwound and recomputed a
context-free `Die`. The fix is to re-raise the captured cause via `Raised_cause` once
diagnostic context is attached.

### Decision diary

#### V-Diag1 - Make Die a record payload

Decision: replace `Die of exn * raw_backtrace option` with `Die of Cause.die`, where
`Cause.die` contains `exn`, `backtrace`, `span_name`, and `annotations`.

Rationale: this is an intentional API break during design phase. A named record is
clearer than an anonymous pair and gives diagnostic consumers a stable field-level
contract.

#### V-Diag2 - Diagnostics live on Cause, not only spans

Decision: `Cause.Die` owns diagnostic context. Tracer events are derived from the cause.

Rationale: sampler-off and noop-tracer runs still need debuggable `Runtime.run` output.
The `die captures diagnostics` test proves span name and annotations are present even
when no span is emitted.

#### V-Diag3 - Runtime owns a small diagnostic fiber context

Decision: `Runtime` keeps a fiber-local diagnostic context with the active Effet
`span_name` and accumulated `annotations`.

Rationale: `Tracer.inspect` cannot provide this reliably. Noop tracers cannot inspect
anything, sampler-off named effects do not open spans, and source locations are already
represented through `Effect.annotate`. A runtime-local diagnostic context follows the
same Eio fiber inheritance model as active span context, but does not depend on span
sampling.

#### V-Diag4 - Re-raise captured causes across context boundaries

Decision: once `Named`, `Annotate`, or an auto-instrumented leaf catches a defect and
attaches diagnostics, the interpreter raises `Raised_cause` instead of re-raising the
original exception.

Rationale: this preserves the captured `Die` after fiber-local context unwinds. The
first red test showed that re-raising the original exception loses `span_name` under
sampler off.

#### V-Diag5 - Backtrace capture is runtime-configurable

Decision: `Runtime.create` accepts `?capture_backtrace`, defaulting to `true`.

Rationale: defect diagnostics should be useful by default. Production runtimes that care
about defect-path allocation can disable raw backtrace capture, and the test pins that
the field becomes `None`.

#### V-Diag6 - run_exn preserves captured backtraces

Decision: `Runtime.run_exn` uses `Printexc.raise_with_backtrace` when a `Die` has a
captured raw backtrace.

Rationale: otherwise callers choosing the exception-raising API would lose the main
debugging value this task adds. The `run_exn preserves backtrace` test pins that a
re-raised defect has a non-empty raw backtrace.

#### V-Diag7 - OTel gets stacktrace through event attributes

Decision: runtime exception events include `exception.stacktrace` when a `Die` has a
backtrace. They also include `exception.type`, `effet.die.span_name`, and
`effet.annotation.<key>` attributes for diagnostic context.

Rationale: `effet-otel` already serializes span event attributes into OTLP/JSON. No
exporter-specific Cause dependency is needed; the runtime emits standard event
attributes and the exporter forwards them.

### Public surface

Changed public API:

~~~ocaml
type die = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
  span_name : string option;
  annotations : (string * string) list;
}

type 'err Cause.t =
  | Fail of 'err
  | Die of die
  | Interrupt of interrupt_id option
  | Sequential of 'err Cause.t list
  | Concurrent of 'err Cause.t list
  | Suppressed of { primary : 'err Cause.t; finalizer : 'err Cause.t }

val die_with_diagnostics :
  ?backtrace:Printexc.raw_backtrace ->
  ?span_name:string ->
  ?annotations:(string * string) list ->
  exn ->
  'err Cause.t

val Runtime.create : ... -> ?capture_backtrace:bool -> ...
~~~

### Verification

Focused commands run during this pass:

~~~sh
nix develop -c dune build packages/effet packages/effet-otel
nix develop -c dune exec packages/effet/test/test_effet.exe -- test Effect 19-24 --show-errors
nix develop -c dune exec packages/effet/test/test_effet.exe -- test Observability 23 --show-errors
nix develop -c dune exec packages/effet-otel/test/run.exe -- test encoder --show-errors
nix develop -c dune runtest --force
~~~

Full-suite result: `effet` 98 tests, `effet-otel` 20 tests, `effet-stream` 13 tests,
`ppx_effet` 3 tests, and `effet-schema` tests all passed.

## V-CD - Concurrency data primitives: Queue / Deferred / PubSub / Latch

### Why this entry exists

Effet-bl1 reopened a gap in the concurrency surface. Earlier decisions said to use
Eio.Stream, Eio.Promise, Eio.Condition, and related Eio primitives directly. The review
question is whether that forces every application to rebuild typed-error, tracing, env,
and cancellation wrappers at each call site.

### Goal

Test whether thin Effect-shaped wrappers for common Eio concurrency data primitives earn
public API space. Candidates: Queue, Deferred, PubSub, and Latch.

### Context read

Relevant inherited constraints:

- Public raw detach is gone; public child lifecycles go through Supervisor, par, all,
  all_settled, race, and bounded traversal.
- Eio.Stream was already accepted as an internal transport for effet-stream merge,
  flat_map_par, fanout, buffering, and interop. It was rejected as the core stream model.
- Resource.auto survives because it owns a nontrivial lifecycle protocol over an
  internal runtime daemon. That is the bar: a public module should own real protocol
  semantics, not just rename Eio operations.
- Tracing lives at the Runtime interpreter. Effect.thunk leaves can already be named and
  auto-instrumented.

### Lab

Artifacts live in scratch/concurrent_data_research/.

Files:

- wrappers.ml: minimal candidates for Queue, Deferred, PubSub, and Latch.
- fixtures.ml: paired wrapper-vs-direct Eio fixtures.
- runtime_smoke.ml: runnable assertions and tracing check.
- README.md: lab navigation.

Validation:

~~~sh
nix develop -c dune build scratch/concurrent_data_research
nix develop -c dune exec scratch/concurrent_data_research/runtime_smoke.exe
~~~

Observed output:

~~~text
ASSERT wrapper queue
ASSERT wrapper deferred
ASSERT wrapper pubsub fast
ASSERT wrapper pubsub slow
ASSERT wrapper latch
ASSERT direct queue
ASSERT direct deferred
ASSERT direct pubsub fast
ASSERT direct pubsub slow
ASSERT direct latch
ASSERT wrapper operations are traced by auto-instrumentation
concurrent_data_research smoke passed
~~~

### Fixtures

The lab implemented these paired behaviours:

- Queue: bounded producer/consumer with backpressure and graceful close.
- Deferred: one-shot config load with three readers awaiting the same value.
- PubSub: two subscribers, one fast and one slow, with drop-if-full policy.
- Latch: wait until three events complete.
- Tracing: wrapper operations are visible as auto-instrumented Effect.thunk spans.

### LOC and shape comparison

Fixture line counts from fixtures.ml:

| Fixture | Wrapper call site | Direct Eio call site |
|---|---:|---:|
| Queue | 23 | 19 |
| Deferred | 12 | 16 |
| PubSub | 44 | 30 |
| Latch | 7 | 19 |

Wrapper implementation size:

| Wrapper | Lines |
|---|---:|
| Queue | 45 |
| Deferred | 26 |
| PubSub | 59 |
| Latch | 29 |

The mixed result matters. Deferred and Latch make call sites smaller, but Queue is
neutral and PubSub is worse. The family is not uniformly a 5+ LOC win per use site.

### Evidence

Queue stopped being thin as soon as it gained close/fail state. Eio.Stream has no
close/end signal. The wrapper therefore had to add an Atomic state, a Stop marker, and
careful wakeup logic. The first tracing fixture deadlocked because Queue.close tried to
enqueue Stop into a full bounded queue with no consumer. The fix was nonblocking wakeup:
only enqueue Stop when there is capacity. That is protocol design, not a thin wrapper.

Deferred is genuinely thin. Eio.Promise plus a result gives a one-shot typed signal, and
multiple waiters work naturally. The wrapper improves the call site slightly by turning
Error err into Effect.fail err. But it adds only a small convenience; direct Eio.Promise
is already clear and idiomatic.

PubSub is the clearest rejection. There is no neutral broadcast wrapper: every design
must choose subscriber queue capacity, slow-consumer policy, close semantics, whether
close wakes or drops, and whether publish blocks, drops, or fails. The wrapper and the
direct Eio fixture both had to solve nonblocking close when a slow subscriber queue was
full. This belongs to application protocol or effet-stream, not a generic Effect.PubSub.

Latch is also thin, but too small. Eio.Condition plus Eio.Mutex is a direct OCaml/Eio
idiom. The wrapper saves lines at the use site, but it does not add typed failure,
resource ownership, or a reusable protocol beyond count-down-and-wait.

Tracing is not enough to justify modules. The wrapper operations become spans because
they are Effect.thunk leaves and the runtime has auto_instrument enabled. Direct Eio
operations can get the same treatment by placing the operation in a named Effect.thunk.

Cancellation semantics are inherited from Eio. The wrappers do not add a new
cancellation model; they block in Eio.Stream.take/add, Eio.Promise.await, and
Eio.Condition.await the same way direct Eio code does.

### Decision diary

#### V-CDv1 - Do not ship a generic Queue wrapper

Decision: no public Effect.Queue.

Rationale: a bounded queue with close and fail states is no longer a thin alias over
Eio.Stream. The lab needed wrapper-owned state and nonblocking close wakeup to avoid
deadlock when the queue is full. If an Effet module owns that much protocol, it should be
domain-specific like Resource or Stream, not a generic data primitive.

#### V-CDv2 - Do not ship Deferred as a standalone module yet

Decision: no public Effect.Deferred from this task.

Rationale: the candidate is viable and small, but the win is not large enough on its own.
Direct Eio.Promise is already idiomatic for one-shot signals. A future module can reopen
this only if several package-level protocols need the same typed result promise shape.

#### V-CDv3 - Reject generic PubSub

Decision: no public Effect.PubSub.

Rationale: PubSub is policy-heavy. Slow-consumer handling, queue capacity, close
delivery, backpressure, and drop accounting are semantic choices. The lab's drop-if-full
candidate worked, but it is one application protocol among many. For stream-shaped
broadcast, use or extend effet-stream; for app event buses, keep the protocol local.

#### V-CDv4 - Do not ship Latch

Decision: no public Effect.Latch.

Rationale: Latch saves lines, but it mostly renames Eio.Condition plus Eio.Mutex. It does
not integrate typed failures or resource ownership in a way direct Eio lacks. The
abstraction is too small for core Effet.

#### V-CDv5 - Keep Eio data primitives as the public guidance

Decision: document direct Eio.Stream, Eio.Promise, and Eio.Condition usage in README.

Rationale: this is consistent with Effet's boundary: applications own state and local
coordination; Effet owns effect description, interpretation, supervision, resources, and
stream protocols. Direct Eio primitives are the idiomatic OCaml answer for local
coordination.

#### V-CDv6 - Reopen only around a real protocol cluster

Decision: future work should not reopen generic wrappers because an app wrote two
Effect.thunk wrappers. Reopen only if multiple Effet packages need the same protocol.

Reopen triggers:

- effet-stream needs a reusable typed handoff queue with proven close/fail semantics;
- Resource or Supervisor needs a shared typed one-shot primitive;
- a real application repeats the same queue/deferred/latch wrapper in several modules
  and direct Eio code obscures failure handling.

### Public documentation update

README now has an Eio Concurrency Data section:

- Eio.Stream for bounded producer/consumer queues.
- Eio.Promise for one-shot signals.
- Eio.Condition with Eio.Mutex for countdown/wait conditions.
- Application-owned queues or effet-stream for broadcast depending on whether the shape
  is stream-like.

### Recommendation

Recommendation (a): skip generic wrappers and document direct Eio primitives.

Do not implement Effect.Queue, Effect.Deferred, Effect.PubSub, Effect.Latch, or a new
effet-concurrent package from this evidence. The right library shape is narrower:
promote focused protocols when they earn ownership, and keep local coordination in Eio.

### Artifacts

- scratch/concurrent_data_research/dune
- scratch/concurrent_data_research/wrappers.ml
- scratch/concurrent_data_research/fixtures.ml
- scratch/concurrent_data_research/runtime_smoke.ml
- scratch/concurrent_data_research/README.md
- README.md

### What we deliberately did not build

- No packages/effet Queue/Deferred/PubSub/Latch modules.
- No effet-concurrent package.
- No new runtime primitive.
- No new scheduler/cancellation model around Eio data structures.

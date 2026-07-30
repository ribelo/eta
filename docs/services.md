# Services Without Layer

Eta does not ship `Layer.t`, `Tag`, `Context`, `Effect.provide`, or a runtime
environment channel. Applications build service graphs with ordinary OCaml
values and functions.

The rule is simple:

- a service handle is an ordinary module-owned type;
- a service constructor is a function returning `Effect.t`;
- a `with_*` helper owns acquire/use/release when the service has a bounded
  lifetime;
- body-bounded lifetimes are managed with `Effect.with_resource`;
- wider lifetimes use `Effect.acquire_release` inside `Effect.with_scope`;
- dependencies are function arguments, records, modules, or closures;
- runtime services such as clock, tracing, logging, metrics, random, and Eio
  switch are interpreter configuration, not application dependency rows.

## Why This Exists

Effect-TS needs Layer because TypeScript needs a value-level service graph to
recover nominal service identity, scoped construction, and requirement tracking.
OCaml already covers most of that directly.

OCaml gives Eta:

- module-owned types for nominal service handles;
- functions and records for dependency injection;
- `Effect.with_resource`, `Effect.with_scope`, and `Effect.acquire_release` for
  resource lifetime;
- normal lexical captures for leaf effects.

The Layer research lab in `.scratch/research/evidence/layer_research/README.md` found that a restricted
merge helper compiles, but it is not better than ordinary OCaml. The
GADT/presence-set variants recreate a Tag/Context/HList system and still have
ordering and duplicate-service hazards.

## Pattern

Define handles in the service module. Keep constructors and cleanup local to
that module.

```ocaml
open Eta

type clock = { now : unit -> float }

module Db : sig
  type t

  val open_ : clock -> (t, string) Effect.t
  val close : t -> (unit, string) Effect.t
  val query : t -> string -> (string, string) Effect.t
end = struct
  type t = { dsn : string; clock : clock }

  let open_ clock =
    Eta_observability.named "db.open" (Effect.sync (fun () -> { dsn = "db://local"; clock }))

  let close _db =
    Eta_observability.named "db.close" (Effect.sync (fun () -> ()))

  let query db sql =
    Eta_observability.named "db.query" (Effect.sync (fun () -> db.dsn ^ ":" ^ sql))
end
```

Make dependencies explicit at the factory boundary.

```ocaml
let with_db clock =
  Effect.with_resource
    ~acquire:(Db.open_ clock)
    ~release:Db.close

let program ~db =
  Db.query db "select current_user"
```

Compose factories with `let@` so the resource lifetime remains visible without
manual `bind`.

```ocaml
let boot clock =
  let open Eta.Syntax in
  let@ db = with_db clock in
  program ~db
```

Run the final program with runtime services configured on the interpreter.

```ocaml
let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let eio_clock = Eio.Stdenv.clock stdenv in
  let clock = { now = fun () -> Eio.Time.now eio_clock } in
  let rt = Eta_eio.Runtime.create ~sw ~clock:eio_clock () in
  ignore (Runtime.run rt (boot clock))
```

## Leaf Effects

A leaf effect closes over the dependencies it needs. There is no ambient
`env` argument.

```ocaml
let current_user auth =
  Eta_observability.named "auth.current_user" (Effect.sync (fun () -> Auth.current_user auth))
```

If a leaf must run in a native island, make the pool, input, and callback
explicit. Under upstream OCaml, tests must cover cross-domain safety because the
compiler does not reject non-portable captures for this API.

```ocaml
let decode bytes = Schema.decode bytes

let decode_all pool buffers =
  Eta_par.Island.map ~pool ~f:decode buffers
```

## Failure Modes

Missing boot dependencies fail as ordinary OCaml errors:

```ocaml
let _ = boot
```

The compiler reports a partial application because `clock` was not supplied.

A service handle that escapes its intended scope is an application bug. Keep
body-bounded acquire/release pairs inside `Effect.with_resource`, use
`Effect.with_scope` plus `Effect.acquire_release` for wider lifetimes, and pass
handles only to the program that runs inside that scope.

Duplicate services should be solved by names and module boundaries. Do not
build anonymous bags of services with repeated keys. If two handles have the
same shape but different meaning, put them behind different module-owned types
or different record fields.

## Why No Environment Channel

Applications pass dependencies as ordinary OCaml values because the
alternatives were each built, measured, and found worse. The full record
is `.scratch/research/envless-verdict-2026-07-26.md`; the four lines of
evidence:

1. **OxCaml portability (decisive).** Object-row environments are not
   portable across domain boundaries; the env parameter was removed for
   exactly this reason (`7417b03b`, V-Recovery-R2). Eta's
   islands/portable direction is non-negotiable.
2. **The components were survival-tested.** `provide`, `Layer`, and the
   env row itself each got compiler-lab fixtures and each fell:
   identical behavior without `provide` (and shorter), no material win
   from restricted Layer merge, 2295-byte missing-capability errors at
   20 modules vs. 689 for arguments.
3. **The value restriction is structural.** Env-reading constructors
   force the parameter non-covariant; reusable values then need
   mandatory eta-expansion, and layer values cannot cross compilation
   units — the entire Layer algebra becomes thunk-passing, which
   destroys memoisation-by-identity.
4. **Object-row keys are global names.** Across libraries they silently
   collide and renames are breaking; nominal identity — the thing keys
   were for — is what OCaml modules already provide.

The in-repo `Reader` race (V-DX-E16) confirmed the same boundary at
service level: value-passing won 4-0-1, with the caveat that the
environment style strengthens with deeper graphs (~6+ dependencies
threaded across many layers). If your application lives there, read on.

## When Value-Passing Hurts: Composite Records

The one place an environment channel beats plain arguments: a leaf five
levels down gains a dependency, and every function on the path needs an
edit. Measured in-repo: 1 file touched with env rows, ~4 with plain
arguments, per leaf evolution.

Do not solve that with a global type parameter. Solve it locally with a
composite capability record per subsystem:

```ocaml
type billing_env = { db : Db.t; audit : Audit.t; metrics : Metrics.t }

val charge : billing_env -> order -> (receipt, billing_err) Effect.t
```

- Introduce the record where a subsystem's dependency set is deep
  (≥ ~4) *and* volatile (changes per quarter), not by default.
- The record is a deliberate, local trade: you lose per-function
  precision (functions see the bundle, not exactly what they use) and
  gain signature stability (adding a dependency touches the record type
  and its construction sites, not every intermediate signature).
- Keep it nominal and subsystem-scoped. The failure mode to avoid is the
  "one big env blob" for the whole application — that is the environment
  parameter returning through the back door.
- The DX lab's numbers: composite records give 88-byte hovers and ~2
  touched files per leaf evolution, versus ~4 for plain arguments and
  dense-row dumps for object rows.

If even that is not enough — repeated ≥5-intermediate-file churn in a
real application — that is one of the measured reopen conditions for the
environment question (verdict §7). Bring the evidence; the door is
closed, not welded shut.

## Decision

Eta keeps service construction in normal OCaml and does not add a Layer or
environment module.

The durable public style is:

- functions for service dependency injection;
- `Effect.with_resource` for body-bounded service lifetime;
- `Effect.with_scope` plus `Effect.acquire_release` for wider service lifetime;
- runtime-owned interpreter services for clock/tracing/logging/metrics/random;
- explicit portable inputs and callbacks at island boundaries;
- no mid-tree dynamic environment replacement.

This is less magical than Effect-TS Layer and matches the shipped envless
`('a, 'err) Effect.t` core.

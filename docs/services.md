# Services Without Layer

Eta does not ship `Layer.t`, `Tag`, `Context`, `Effect.provide`, or a runtime
environment channel. Applications build service graphs with ordinary OCaml
values and functions.

The rule is simple:

- a service handle is an ordinary module-owned type;
- a service factory is a function returning `Effect.t`;
- lifetimes are managed with `Effect.acquire_release` inside `Effect.scoped`;
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
- `Effect.scoped` and `Effect.acquire_release` for resource lifetime;
- normal lexical captures for leaf effects.

The Layer research lab in `scratch/layer_research/` found that a restricted
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
    Effect.sync "db.open" (fun () -> { dsn = "db://local"; clock })

  let close _db =
    Effect.sync "db.close" (fun () -> ())

  let query db sql =
    Effect.sync "db.query" (fun () -> db.dsn ^ ":" ^ sql)
end
```

Make dependencies explicit at the factory boundary.

```ocaml
let db_factory clock =
  Effect.acquire_release
    ~acquire:(Db.open_ clock)
    ~release:Db.close

let program ~db =
  Db.query db "select current_user"
```

Compose factories with `bind` inside one `Effect.scoped`.

```ocaml
let boot clock =
  Effect.scoped
    (db_factory clock
    |> Effect.bind (fun db -> program ~db))
```

Run the final program with runtime services configured on the interpreter.

```ocaml
let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let eio_clock = Eio.Stdenv.clock stdenv in
  let clock = { now = fun () -> Eio.Time.now eio_clock } in
  let rt = Runtime.create ~sw ~clock:eio_clock () in
  ignore (Runtime.run rt (boot clock))
```

## Leaf Effects

A leaf effect closes over the dependencies it needs. There is no ambient
`env` argument.

```ocaml
let current_user auth =
  Effect.sync "auth.current_user" (fun () -> Auth.current_user auth)
```

If a leaf must run in a portable island, make the input and callback explicit.
The compiler then rejects non-portable captures.

```ocaml
let (decode @ portable) bytes = Schema.decode bytes

let decode_all pool buffers =
  Effect.Island.map ~pool ~f:decode buffers
```

## Failure Modes

Missing boot dependencies fail as ordinary OCaml errors:

```ocaml
let _ = boot
```

The compiler reports a partial application because `clock` was not supplied.

A service handle that escapes its intended scope is an application bug. Keep
acquire/release pairs inside `Effect.scoped` and pass handles only to the
program that runs inside that scope.

Duplicate services should be solved by names and module boundaries. Do not
build anonymous bags of services with repeated keys. If two handles have the
same shape but different meaning, put them behind different module-owned types
or different record fields.

## Decision

Eta keeps service construction in normal OCaml and does not add a Layer or
environment module.

The durable public style is:

- functions for service dependency injection;
- `Effect.scoped` for service lifetime;
- runtime-owned interpreter services for clock/tracing/logging/metrics/random;
- explicit portable inputs and callbacks at island boundaries;
- no mid-tree dynamic environment replacement.

This is less magical than Effect-TS Layer and matches the shipped envless
`('a, 'err) Effect.t` core.

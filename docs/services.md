# Services Without Layer

Effet does not ship Layer.t, Tag, Context, or Effect.provide. Applications
build service graphs with ordinary OCaml values and functions.

The rule is simple:

- a service handle is an ordinary module-owned type;
- a service factory is a function returning Effect.t;
- lifetimes are managed with Effect.acquire_release inside Effect.scoped;
- dependencies are function arguments inside the application;
- the runtime env object is for outer-boundary capabilities and leaf effects.

## Why This Exists

Effect-TS needs Layer because TypeScript needs a value-level service graph to
recover nominal service identity, scoped construction, and requirement tracking.
OCaml already covers most of that directly.

OCaml gives Effet:

- module-owned types for nominal service handles;
- functions for dependency injection;
- object rows for effects that read runtime capabilities;
- Effect.scoped and Effect.acquire_release for resource lifetime.

The Layer research lab in scratch/layer_research/ found that a restricted
merge_explicit helper compiles, but it is not better than ordinary OCaml. The
GADT presence-set version recreates a Tag/Context/HList system and still has
ordering and duplicate-service hazards.

Run the complete compiling fixture with:

~~~sh
nix develop -c dune exec scratch/layer_research/runtime_smoke.exe
~~~

## Pattern

The snippets below are the shape to copy into real services. The full compiling
version is scratch/layer_research/no_layer_baseline.ml.

Define handles in the service module. Keep constructors and cleanup local to
that module.

~~~ocaml
module Db : sig
  type t

  val open_ : clock -> (<  >, string, t) Effect.t
  val close : t -> (<  >, string, unit) Effect.t
  val query : t -> string -> (<  >, string, string) Effect.t
end = struct
  type t = { dsn : string; clock : clock }

  let open_ clock =
    Effect.sync "db.open" (fun _ -> { dsn = "db://local"; clock })

  let close _db =
    Effect.sync "db.close" (fun _ -> ())

  let query db sql =
    Effect.sync "db.query" (fun _ -> db.dsn ^ ":" ^ sql)
end
~~~

Make dependencies explicit at the factory boundary.

~~~ocaml
let db_factory clock =
  Effect.acquire_release
    ~acquire:(Db.open_ clock)
    ~release:Db.close

let http_factory clock log =
  Effect.acquire_release
    ~acquire:(Http.start clock log)
    ~release:Http.stop
~~~

Compose factories with bind inside one Effect.scoped.

~~~ocaml
let boot clock log =
  Effect.scoped
    (db_factory clock
    |> Effect.bind (fun db ->
           http_factory clock log
           |> Effect.bind (fun http ->
                  program ~db ~http)))
~~~

Run the final program with the smallest runtime env it needs.

~~~ocaml
let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = { now = fun () -> Eio.Time.now (Eio.Stdenv.clock stdenv) } in
  let log = { info = fun msg -> Format.eprintf "%s@." msg } in
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() () in
  ignore (Runtime.run rt (boot clock log))
~~~

## Runtime Env

Use the runtime env object when an effect should demand a capability from its
caller without receiving it as a function argument.

~~~ocaml
let current_user =
  Effect.sync "auth.current_user" (fun env -> env#auth#current_user)
~~~

That function has an inferred requirement similar to:

~~~ocaml
(< auth : auth; .. >, 'err, user) Effect.t
~~~

Use this for leaf effects and boundary capabilities. Do not use it to model a
whole application dependency graph. For graph construction, pass values.

For exported or reusable env-row effects, prefer an explicit thunk:

~~~ocaml
let current_user () =
  Effect.sync "auth.current_user" (fun env -> env#auth#current_user)
~~~

The optional ppx_effet package makes leaf capability reads explicit and prevents
accidental env creep:

~~~ocaml
let current_user () =
  [%effet.sync "auth.current_user" (auth : auth)
    (auth#current_user)]
~~~

The body receives only the listed local variables. A direct `env#db` read in
that body is rejected by the PPX.

At the runtime boundary, ppx_effet can build the object without changing the
service-construction rule:

~~~ocaml
let env =
  [%effet.env { auth = (auth : auth); clock = (clock : clock) }]
~~~

## Failure Modes

Missing boot dependencies fail as ordinary OCaml errors:

~~~ocaml
let _ = boot clock
~~~

The compiler reports a partial application because log was not supplied.

Missing env methods fail as object-row errors:

~~~ocaml
Runtime.run rt current_user
~~~

If rt was created with env = object end, the compiler reports that the object
has no method auth.

Duplicate services should be solved by names and module boundaries. Do not
build anonymous bags of services with repeated keys. If two handles have the
same shape but different meaning, put them behind different module-owned types
or different field names.

## Decision

Effet keeps the object-row env channel but does not add a Layer module.

The durable public style is:

- functions for service dependency injection;
- Effect.scoped for service lifetime;
- object-row env only where an effect directly reads a runtime capability;
- no mid-tree dynamic env replacement.

This is less magical than Effect-TS Layer and more idiomatic for OCaml.

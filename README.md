# Effet

Effet is an OCaml effect library shaped by TypeScript Effect and Scala ZIO.
It keeps the useful axes: environment requirements, typed failures, and
success values.

It is not an Elm Architecture framework. There is no message loop, inbox,
subscription reconciler, or state container. Applications own their
state; Effet owns effect description and interpretation.

## Core Type

```ocaml
('env, 'err, 'a) Effect.t
```

- `'env` is the requirement channel. Structural object types work well for
  capabilities.
- `'err` is the typed failure channel. Polymorphic variants give precise,
  inferred error rows.
- `'a` is the success value.

## Example

```ocaml
open Effet

let program =
  Effect.pure 1
  |> Effect.map (fun n -> n + 1)
  |> Effect.bind (fun n ->
         if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.catch (fun `Too_small -> Effect.pure 3)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  match Runtime.run rt program with
  | Ok n -> Format.printf "%d@." n
  | Error `Too_small -> assert false
```

## Features

| Module | Purpose |
| --- | --- |
| `Effect` | GADT for pure values, typed failure, sync/async leaves, bind/map/tap, catch, timeout, race, repeat, retry, detach, scopes. |
| `Runtime` | Eio-backed interpreter for `Effect.t`. |
| `Duration` | Millisecond-precision durations. |
| `Schedule` | Pure recurrence descriptions for repeat and retry. |
| `Resource` | Cached effectful resources with explicit refresh. |
| `Capabilities` | Small object-type traits for capability-oriented environments. |

## Resource Scopes

`Effect.acquire_release` registers finalizers with the surrounding
`Effect.scoped`. Finalizers run on success, typed failure, and cancellation.

```ocaml
let with_db k =
  let acquire = Effect.sync "db.open" (fun env -> env#db#open_) in
  let release handle =
    Effect.sync "db.close" (fun env -> env#db#close handle)
  in
  Effect.scoped
    (Effect.acquire_release ~acquire ~release |> Effect.bind k)
```

## Development

Use the Nix shell when available:

```sh
nix develop -c dune runtest --force
```

Without Nix:

```sh
opam install . --deps-only --with-test
dune runtest --force
```

The research journal is intentionally ignored by Git. It records the full
project history and local design reasoning, but it is not part of the
published package.

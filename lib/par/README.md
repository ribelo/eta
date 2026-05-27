# par

Rayon-style data parallelism for OxCaml — fork-join on top of a heartbeat
work-stealing scheduler.

> Status: v1, single-domain entry, no nested `Pool.run`, no cancellation.
> Public API is stable enough to use; internals will keep moving.

## Quick start

```ocaml
open Eta_par

(* Top-level convenience: spin up a pool, run, tear down. *)
let () =
  let r = run (fun () ->
    let a, b = join
        (fun () -> heavy_compute_a ())
        (fun () -> heavy_compute_b ()) in
    a + b)
  in
  Printf.printf "%d\n" r
```

## Public API

```ocaml
val run    : ?n_workers:int -> ?heartbeat_interval_ns:int -> (unit -> 'a) -> 'a
val join   : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
val join3  : (unit -> 'a) -> (unit -> 'b) -> (unit -> 'c) -> 'a * 'b * 'c

val par_for    : start:int -> stop:int -> (int -> unit) -> unit
val par_iter   : 'a array -> ('a -> unit) -> unit
val par_iteri  : 'a array -> (int -> 'a -> unit) -> unit
val par_map    : 'a array -> ('a -> 'b) -> 'b array
val par_mapi   : 'a array -> (int -> 'a -> 'b) -> 'b array
val par_reduce :
  'a array ->
  init:'b ->
  map:('a -> 'b) ->
  combine:('b -> 'b -> 'b) ->
  'b
val par_sort   : 'a array -> ('a -> 'a -> int) -> unit

module Pool : sig
  type t
  val create    : ?n_workers:int -> ?heartbeat_interval_ns:int -> unit -> t
  val run       : t -> (unit -> 'a) -> 'a
  val run_on_worker : t -> (unit -> 'a) -> 'a
  val run_many_on_workers : t -> (unit -> 'a) list -> 'a list
  val shutdown  : t -> unit
  val with_pool : ?n_workers:int -> ?heartbeat_interval_ns:int -> (t -> 'a) -> 'a
end

val par_threshold : int ref  (* default 1024 *)
```

`join`, `par_*` must be called from inside a task running on a pool worker
(transitively from `run` or `Pool.run`); calling them from the main thread
without an enclosing `run` raises `Invalid_argument`.

## Where par fits

`par` is the structured CPU-parallelism layer.  If you need manual
fork-join, parallel-map, parallel-sort, or lazy iterator chains over arrays,
this is the package.

It shares the heartbeat scheduler implementation with `Effect.island`
(the typed-offload layer).  The public pool types remain separate.  The split
is:

| API | Lives in | Pool | Closures | Payloads |
|---|---|---|---|---|
| `Eta_par.join`, `par_*`, `Iter` | `par` | Heartbeat domain pool | untyped (`unit -> 'a`); can close over mutable arrays | unconstrained |
| `Effect.island`, `Island.map` | `eta` | Heartbeat domain pool | typed (`@ portable`); compiler-forbids shared mutable state | `: immutable_data` |

See [Concurrency Guide](../../docs/concurrency-guide.md) for the full
when-to-use-what decision flow.

## Implementation notes

The scheduler keeps a per-worker cactus stack of pending join frames.
Most joins run both branches inline with only a cheap heartbeat check.
A background heartbeat domain periodically marks workers; marked workers
promote their oldest queued frame into a stealable slot for idle workers.

`Pool.run` registers the caller as worker 0 and runs the root task on the
caller, which is the right shape for explicit fork/join. `Pool.run_on_worker`
submits a root task to a long-lived worker domain; Eta uses that entry point for
`Effect.island` so portable callbacks keep their offload semantics.

## Correctness

```bash
nix develop -c dune runtest lib/par --force
```

The test suite covers pool lifecycle, fork-join, nested joins, exception
propagation, par_for/par_map/par_reduce/par_sort, heartbeat fanout, and iterator
chains.

## Benchmark

```bash
nix develop -c dune exec bench/runtime_par/runtime_par.exe -- --quick
```

The benchmark suite validates each parallel checksum against the matching
serial implementation and reports per-kernel timing/allocation metrics.

## Roadmap

- Long-lived global default pool (so `join` can be called outside `run`
  via an implicit pool).
- `par_chunk` / chunked iteration with a stride.
- Cancellation (cooperative; via an atomic flag checked at task entry).

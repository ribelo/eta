# Concurrency primitives in Eta — when to use what

Eta provides four concurrency surfaces, each for a different shape of "work
that shouldn't block the current fiber."  They compose: a single application
may use all four without conflict.

This guide answers one question: **I have a piece of work.  Which primitive
do I use?**

---

## Decision flow

```
                         ┌─────────────────────────┐
                         │ Does the work involve   │
                         │ blocking I/O (syscall,  │
                         │ DB query, file read,    │
                         │ HTTP client call)?      │
                         └────────────┬────────────┘
                                      │
                         ┌────────────┼────────────┐
                         │ Yes                     │ No
                         ▼                         ▼
               Eta_blocking.run         ┌─────────────────────────┐
               (OS thread pool)         │ Is the work CPU-heavy   │
                                        │ AND you want structured │
                                        │ parallelism?            │
                                        │ (par_map, par_sort,     │
                                        │  fork-join over data?)  │
                                        └────────────┬────────────┘
                                                     │
                                        ┌────────────┼────────────┐
                                        │ Yes                     │ No
                                        ▼                         ▼
                                  Eta_par           Eta_par.Island.run
                                  (heartbeat            (domain pool,
                                  scheduler,            one native
                                  join/par_*)           callback)
```

Then there's `Effect.sync`, which keeps work on the current fiber's
domain.  You don't "choose" sync — it's the default you fall into when
no offload is needed.

Every box in the diagram:

| Primitive | What it does | Pool | Best for | Key constraint |
|---|---|---|---|---|
| `Effect.sync` | Runs on the current domain, same fiber | None | Anything not too heavy or blocking | Blocks the domain if the work is CPU-heavy |
| `Effect.par` / `Effect.map_par` | Runs child effects as Eio fibers on the current runtime | None | Concurrent effect workflows: overlapping sleeps, async I/O, queues, resources | `map_par` defaults to at most 8 fibers; neither API is CPU parallelism, and heavy sync work still blocks the domain |
| `Eta_par.Island.run` | Runs a single callback on a worker domain | Explicit domain pool (heartbeat) | One-shot CPU offload: parse JSON, hash a file, compress a chunk | Callback crosses a native domain boundary and must return on its own |
| `Eta_par.Island.map` | Runs N callbacks in parallel batch | Explicit domain pool (heartbeat) | Batch CPU offload with input-order results | Same constraints as island; started callbacks are not preempted by Eta cancellation |
| `Eta_blocking.run` | Runs a blocking call on an OS thread | OS thread pool | syscalls, DB queries, file I/O, third-party SDK calls | Work blocks the thread, not the domain; callback cannot hold domain-local resources |
| `Eta_par.join` | Forks two tasks; heartbeat scheduler distributes at runtime | Domain pool (heartbeat) | Recursive parallel algorithms, tree walks | Must be called from inside `Eta_par.run` or `Eta_par.Pool.run` |
| `Eta_par.par_for` / `.par_map` | Data-parallel combinators over arrays | Domain pool (heartbeat) | Structured CPU parallelism: parallel sort, parallel reduce, parallel map | Shapes are fixed; no per-element async decisions |
| `Eta_par.Iter` | Lazy iterator chains (map/filter/reduce/collect) | Domain pool (heartbeat) | Rayon-style pipelines over arrays | Indexed sources only; consumer wraps the chain |

---

## Where heartbeat fits

**Heartbeat is the domain-pool scheduler inside `eta_par`.**

You never call "heartbeat" directly.  You call:

- `Eta_par.join` / `Eta_par.par_for` / `Eta_par.par_sort` /
  `Eta_par.Iter` — the
  structured-parallelism API, which uses heartbeat's work-stealing to distribute
  nested fork-join tasks across domain workers.
- `Eta_par.Island.run` / `Eta_par.Island.map` — the native offload API,
  which uses an explicit heartbeat-backed island pool for single and batch
  worker-domain offload.

Both APIs share the same scheduler implementation.  The public pool types stay
separate: use `Eta_par.Island.Pool.t` for offload callbacks and
`Eta_par.Pool.t` for explicit CPU-parallel code.

```
       ┌──────────────────────────────────┐
       │      Heartbeat domain pool       │
       │   (Eta_par.Pool.t underneath)│
       └────────────┬─────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
  Eta_par.join         Eta_par.Island.run
  Eta_par.par_for      Eta_par.Island.map
  Eta_par.par_sort     Eta_par.Island.map_result
  Eta_par.Iter         Eta_par.Island.all_settled
  (CPU-parallel,           (typed offload,
   untyped closures,        native callbacks,
   mutable arrays OK)       explicit pool)
```

The split is deliberate: CPU-parallel code often closes over mutable arrays,
while island code is an explicit native boundary where callers must avoid unsafe
shared mutable state. Keeping the scheduler shared and the public APIs separate
keeps each use case honest.

---

## Concrete recipes

### "I have a heavy pure computation (SHA-256 a file, parse 50 MB of JSON)"

```ocaml
let island_pool = Eta_par.Island.Pool.create ~domains:2 ()

let hash_file path =
  Eta_par.Island.run ~name:"hash" ~pool:island_pool
    (fun () -> sha256_of_file path) ()
```

One-shot callback, runs on its own domain. Your event loop stays responsive.
For a batch of files, use `Eta_par.Island.map`.

### "I need to sort 10 million records"

```ocaml
Eta_par.run (fun () ->
  Eta_par.par_sort arr compare_my_records)
```

Structured parallelism with the heartbeat scheduler.  `par_sort` is a
quicksort implementation that uses `Eta_par.join` for recursive halving.
Heartbeat distributes the partitions across domain workers without you
manually chunking anything.

### "I need to do parallel map-reduce over a large array"

```ocaml
Eta_par.run (fun () ->
  Eta_par.Iter.(
    of_array data
    |> map (fun x -> heavy_per_element x)
    |> reduce ~init:0 ~combine:(+)))
```

Or use `par_reduce` for the direct combinator.  `Iter` chains are lazy:
adapters don't run until a consumer (`reduce`, `collect_array`, `for_each`,
etc.) is called.

### "I need to call a blocking C library"

```ocaml
Eta_blocking.run ~name:"legacy_parse" (fun () ->
  C_lib.parse_binary buf)
```

OS thread pool.  The thread blocks on C code; your Eta fiber is suspended and
resumed when the result is ready.  Use a separate pool per resource class (DB,
filesystem, third-party SDK) so saturation in one doesn't starve the others.

When the blocking callback returns expected typed failures, use
`Eta_blocking.run_result`:

```ocaml
Eta_blocking.run_result ~name:"legacy_parse" (fun () ->
  C_lib.parse_binary_result buf)
```

```ocaml
let db_pool = Eta_blocking.Pool.create ~name:"db" {
  max_threads = 32; max_queued = 64;
  queue_policy = Wait; shutdown_policy = Drain
}
```

### "I need to do all three: read a file, parse it, then parallel-process the results"

Compose them:

```ocaml
let process path =
  let* raw = Eta_blocking.run ~name:"read" (fun () -> read_file path) in
  let* parsed =
    Eta_par.Island.run ~name:"parse" ~pool:island_pool
      (fun () -> parse_json raw) in
  let results =
    Eta_par.run ~n_workers:4 (fun () ->
      Eta_par.par_map parsed (fun record -> heavy_per_record record))
  in
  Effect.pure results
```

File read → OS thread pool.  Parse → domain pool (island).  Process batch →
domain pool (`Eta_par`).  The blocking pool is separate from both domain-pool
surfaces because OS threads and domain workers solve different problems.

---

## Pool sizing

| Primitive | Pool type | Default size | Guidance |
|---|---|---|---|
| `Effect.sync` | None | — | — |
| `Eta_par.Island.run` / `Eta_par.Island.map` | Domain pool (heartbeat) | 2 domains | Increase if you regularly have >=2 concurrent island calls. Decrease if you're GPU- or I/O-bound. |
| `Eta_par.join` / `par_*` | Domain pool (heartbeat) | `core_count` | `Eta_par.run` defaults to `Domain.recommended_domain_count()`. Use `Eta_par.Pool` when you want explicit reuse. |
| `Eta_blocking` | OS thread pool | configurable; typically 32-128 | One pool per resource class. DB pool != filesystem pool. |

`Eta_par.Island.Pool` wraps `Eta_par.Pool` internally but does not expose it.
Keep island pools and explicit `Eta_par.Pool` values separate unless Eta grows an
intentional sharing API.

---

## Cheat-sheet

| You want to... | Use | Lives in |
|---|---|---|
| Run normal OCaml code without blocking the fiber | `Effect.sync` | `eta` (the base effect library) |
| Run CPU-heavy callback on a separate domain | `Eta_par.Island.run` | `eta_par` |
| Run batch callbacks in parallel, get results in order | `Eta_par.Island.map` | `eta_par` |
| Call a blocking C/OS function (DB, syscall, third-party SDK) | `Eta_blocking.run` / `run_result` | `eta_blocking` |
| Fork-join two recursive subproblems | `Eta_par.join` | `eta_par` |
| Parallel map/reduce/sort over arrays | `Eta_par.par_map` / `par_reduce` / `par_sort` | `eta_par` |
| Lazy iterator chains (map/filter/reduce/collect) | `Eta_par.Iter` | `eta_par` |
| Create a reusable domain pool, shut it down manually | `Eta_par.Pool.create` / `shutdown` | `eta_par` |
| Create a reusable OS thread pool for blocking I/O | `Eta_blocking.Pool.create` / `shutdown` | `eta_blocking` |

---

## What not to do

- **Don't put CPU work on the blocking pool.**  The blocking pool's threads
  share one runtime lock per domain; CPU work on them serialises, defeating
  parallelism. Use `Eta_par.Island.run` or `Eta_par`.
- **Don't put blocking I/O on the island pool.**  Island workers are domains;
  a blocked syscall blocks the entire domain until it returns.  Use
  `Eta_blocking`.
- **Don't use islands for unbounded or non-cooperative loops.**  Eta
  cancellation and timeouts can stop waiting for an island result, but they do
  not safely stop worker-domain code that is already running.
- **Don't call `Eta_par.join` / `par_*` / `Iter` outside
  `Eta_par.run` / `Eta_par.Pool.run`.**  These require a running heartbeat
  pool.  Calling them from a raw fiber raises `Invalid_argument`.
- **Don't assume `Eta_par.Island.run` will silently fall back to same-domain
  execution.**  It won't. Pass an explicit island pool.

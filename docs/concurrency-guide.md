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
               Effect.Blocking.submit   ┌─────────────────────────┐
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
                                  Par               Effect.island
                                  (heartbeat            (domain pool,
                                  scheduler,            one portable
                                  join/par_*)           callback)
```

Then there's `Effect.sync`, which keeps work on the current fiber's
domain.  You don't "choose" sync — it's the default you fall into when
no offload is needed.

Every box in the diagram:

| Primitive | What it does | Pool | Best for | Key constraint |
|---|---|---|---|---|
| `Effect.sync` | Runs on the current domain, same fiber | None | Anything not too heavy or blocking | Blocks the domain if the work is CPU-heavy |
| `Effect.island` | Runs a single portable callback on a worker domain | Domain pool (heartbeat) | One-shot CPU offload: parse JSON, hash a file, compress a chunk | Callback must be `@ portable`, payloads `: immutable_data` |
| `Effect.Island.map` | Runs N portable callbacks in parallel batch | Domain pool (heartbeat) | Batch CPU offload with input-order results | Same constraints as island; schedules batch jobs on worker domains |
| `Effect.Blocking.submit` | Runs a blocking call on an OS thread | OS thread pool | syscalls, DB queries, file I/O, third-party SDK calls | Work blocks the thread, not the domain; callback cannot hold domain-local resources |
| `Par.join` | Forks two tasks; heartbeat scheduler distributes at runtime | Domain pool (heartbeat) | Recursive parallel algorithms, tree walks | Must be called from inside `Par.run` or `Par.Pool.run` |
| `Par.par_for` / `.par_map` | Data-parallel combinators over arrays | Domain pool (heartbeat) | Structured CPU parallelism: parallel sort, parallel reduce, parallel map | Shapes are fixed; no per-element async decisions |
| `Par.Iter` | Lazy iterator chains (map/filter/reduce/collect) | Domain pool (heartbeat) | Rayon-style pipelines over arrays | Indexed sources only; consumer wraps the chain |

---

## Where heartbeat fits

**Heartbeat is the domain-pool scheduler inside both Par and Effect.Island.**

You never call "heartbeat" directly.  You call:

- `Par.join` / `Par.par_for` / `Par.par_sort` / `Par.Iter` — the
  structured-parallelism API, which uses heartbeat's work-stealing to distribute
  nested fork-join tasks across domain workers.
- `Effect.island` / `Effect.Island.map` — the typed offload API, which uses
  a heartbeat-backed island pool for single and batch worker-domain offload.

Both APIs share the same scheduler implementation.  The public pool types stay
separate: use `Effect.Island.Pool.t` for runtime-owned portable callbacks and
`Par.Pool.t` for explicit CPU-parallel code.

```
       ┌──────────────────────────────────┐
       │      Heartbeat domain pool       │
       │   (Par.Pool.t underneath)    │
       └────────────┬─────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
  Par.join             Effect.island
  Par.par_for          Effect.Island.map
  Par.par_sort         Effect.Island.submit
  Par.Iter             Effect.Island.all_settled
  (CPU-parallel,           (typed offload,
   untyped closures,        @portable callbacks,
   mutable arrays OK)       :immutable_data payloads)
```

The split is deliberate: CPU-parallel code wants to close over mutable arrays;
island code wants the compiler to forbid shared mutable state across domains.
Keeping the scheduler shared and the public APIs separate gives each use case
the type guarantees (or freedom) it needs.

---

## Concrete recipes

### "I have a heavy pure computation (SHA-256 a file, parse 50 MB of JSON)"

```ocaml
let hash_file path =
  Effect.island ~name:"hash" (fun () -> sha256_of_file path) ()
```

One-shot, portable callback, runs on its own domain.  Your event loop stays
responsive.  For a batch of files, use `Effect.Island.map`.

### "I need to sort 10 million records"

```ocaml
Par.run (fun () ->
  Par.par_sort arr compare_my_records)
```

Structured parallelism with the heartbeat scheduler.  `par_sort` is a
quicksort implementation that uses `Par.join` for recursive halving.
Heartbeat distributes the partitions across domain workers without you
manually chunking anything.

### "I need to do parallel map-reduce over a large array"

```ocaml
Par.run (fun () ->
  Par.Iter.(
    of_array data
    |> map (fun x -> heavy_per_element x)
    |> reduce ~init:0 ~combine:(+)))
```

Or use `par_reduce` for the direct combinator.  `Iter` chains are lazy:
adapters don't run until a consumer (`reduce`, `collect_array`, `for_each`,
etc.) is called.

### "I need to call a blocking C library"

```ocaml
Effect.Blocking.submit ~name:"legacy_parse" (fun () ->
  C_lib.parse_binary buf)
```

OS thread pool.  The thread blocks on C code; your Eta fiber is suspended and
resumed when the result is ready.  Use a separate pool per resource class (DB,
filesystem, third-party SDK) so saturation in one doesn't starve the others.

```ocaml
let db_pool = Effect.Blocking.Pool.create ~name:"db" {
  max_threads = 32; max_queued = 64;
  queue_policy = Wait; shutdown_policy = Drain
}
```

### "I need to do all three: read a file, parse it, then parallel-process the results"

Compose them:

```ocaml
let process path =
  let* raw = Effect.Blocking.submit ~name:"read" (fun () -> read_file path) in
  let* parsed = Effect.island ~name:"parse" (fun () -> parse_json raw) in
  let results =
    Par.run ~n_workers:4 (fun () ->
      Par.par_map parsed (fun record -> heavy_per_record record))
  in
  Effect.pure results
```

File read → OS thread pool.  Parse → domain pool (island).  Process batch →
domain pool (Par).  The blocking pool is separate from both domain-pool
surfaces because OS threads and domain workers solve different problems.

---

## Pool sizing

| Primitive | Pool type | Default size | Guidance |
|---|---|---|---|
| `Effect.sync` | None | — | — |
| `Effect.island` / `Island.map` | Domain pool (heartbeat) | 2 domains | Increase if you regularly have >=2 concurrent island calls. Decrease if you're GPU- or I/O-bound. |
| `Par.join` / `par_*` | Domain pool (heartbeat) | `core_count` | `Par.run` defaults to `Domain.recommended_domain_count()`. Use `Par.Pool` when you want explicit reuse. |
| `Effect.Blocking` | OS thread pool | configurable; typically 32-128 | One pool per resource class. DB pool != filesystem pool. |

`Effect.Island.Pool` wraps `Par.Pool` internally but does not expose it.  Keep
island pools and explicit `Par.Pool` values separate unless Eta grows an
intentional sharing API.

---

## Cheat-sheet

| You want to... | Use | Lives in |
|---|---|---|
| Run normal OCaml code without blocking the fiber | `Effect.sync` | `eta` (the base effect library) |
| Run CPU-heavy callback on a separate domain, compiler-checked safety | `Effect.island` | `eta` |
| Run batch of portable callbacks in parallel, get results in order | `Effect.Island.map` | `eta` |
| Call a blocking C/OS function (DB, syscall, third-party SDK) | `Effect.Blocking.submit` | `eta` |
| Fork-join two recursive subproblems | `Par.join` | `par` |
| Parallel map/reduce/sort over arrays | `Par.par_map` / `par_reduce` / `par_sort` | `par` |
| Lazy iterator chains (map/filter/reduce/collect) | `Par.Iter` | `par` |
| Create a reusable domain pool, shut it down manually | `Par.Pool.create` / `shutdown` | `par` |
| Create a reusable OS thread pool for blocking I/O | `Effect.Blocking.Pool.create` / `shutdown` | `eta` |

---

## What not to do

- **Don't put CPU work on the blocking pool.**  The blocking pool's threads
  share one runtime lock per domain; CPU work on them serialises, defeating
  parallelism.  Use `Effect.island` or `Par`.
- **Don't put blocking I/O on the island pool.**  Island workers are domains;
  a blocked syscall blocks the entire domain until it returns.  Use
  `Effect.Blocking`.
- **Don't call `Par.join` / `par_*` / `Iter` outside
  `Par.run` / `Par.Pool.run`.**  These require a running heartbeat
  pool.  Calling them from a raw fiber raises `Invalid_argument`.
- **Don't assume `Effect.island` will silently fall back to same-domain
  execution.**  It won't.  Provide an island pool at runtime creation or
  per-run override.

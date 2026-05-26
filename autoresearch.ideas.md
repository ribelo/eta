# Deferred Fanout Optimization Ideas

## Already tried and discarded
- Lazy task construction in worker loop (cache thrashing, -8%)
- Obj.t array for results instead of Some wrapping (Obj overhead, -2.5%)
- Shared `for_each_par_impl` helper function (OxCaml doesn't inline it, -40% regression)
- Extraction micro-optimization (noise)
- 4 internal workers (under-parallelizes, -10% regression vs 8)

## Promising but not pursued

### Reduce the number of array allocations
Both `for_each_par` and `for_each_par_bounded` currently allocate 3 arrays per call:
1. `Array.of_list xs` — input array
2. `Array.map f xs_arr` — task array (effects)
3. `Array.make n None` — result array
The input and task arrays could potentially be merged if `f` is inlined, but OCaml doesn't fuse array operations.

### OxCaml `[@unboxed]` for `Exit.t`
The `Exit.t` type is a 2-case sum: `Ok of 'a | Error of 'err`. Each bind step pattern-matches on this. If `Exit.t` were unboxed, the pattern match would be eliminated. Requires broader refactoring of the Effect representation.

### Zero-allocation bind chains
The `Effect.bind` implementation creates a new `make` record per step. For tight bind chains, a fused representation (similar to a list of continuations) could eliminate intermediate allocations. Would require adding `BindChain of ('a -> 'b) list * effect` variant to the effect type. Large, risky change.

### Domain-level parallelism
All current workloads run single-threaded (Eio fibers on one domain). Using `Eio.Fiber.fork` on multiple domains with `Eio.Domain_manager` could parallelize task execution. But Eta's runtime assumes single-domain fiber coordination.

### Eliminate inner `Eio.Switch.run` in worker pool
The worker pool creates an inner switch for fiber lifecycle. If fibers could be forked on the caller's switch (passed through the frame), one switch allocation per evaluation would be saved. Requires plumbing the switch through Runtime/Effect.

### Session results
- Baseline: 330,234 ns
- Experiment #2 (worker pool bounded): 241,184 ns (-27.0%)
- Experiment #5 (worker pool unbounded): 225,925 ns (-31.6%)
- Experiment #7 (cap workers at 8): **220,799 ns (-33.1%)**
- Key wins: worker pool for bounded (-36%), inline for unbounded (-10%), worker cap (-7%)

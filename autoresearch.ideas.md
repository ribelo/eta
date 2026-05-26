# Deferred Fanout Optimization Ideas

## Already tried and discarded
- Lazy task construction in worker loop (cache thrashing, -8%)
- Obj.t array for results instead of Some wrapping (Obj overhead, -2.5%)
- Shared `for_each_par_impl` helper function (OxCaml doesn't inline it, -40% regression)
- Extraction micro-optimization (noise)

## Promising but not pursued

### Reduce the number of array allocations
Both `for_each_par` and `for_each_par_bounded` currently allocate 3 arrays per call:
1. `Array.of_list xs` — input array
2. `Array.map f xs_arr` — task array (effects)
3. `Array.make n None` — result array
The input and task arrays could potentially be merged if `f` is inlined, but OCaml doesn't fuse array operations.

### Eliminate `Eio.Fiber.fork` overhead for small n
For `for_each_par` with n < ~16, fiber creation overhead dominates. A fast path that runs tasks sequentially (no fibers) could win for small n. But it changes semantics for cancellation. Not worth the risk for the current benchmark (n=64).

### OxCaml `[@unboxed]` for `Exit.t`
The `Exit.t` type is a 2-case sum: `Ok of 'a | Error of 'err`. Each bind step pattern-matches on this. If `Exit.t` were unboxed, the pattern match would be eliminated. Requires broader refactoring of the Effect representation.

### Zero-allocation bind chains
The `Effect.bind` implementation creates a new `make` record per step. For tight bind chains, a fused representation (similar to a list of continuations) could eliminate intermediate allocations. Would require adding `BindChain of ('a -> 'b) list * effect` variant to the effect type. Large, risky change.

### Domain-level parallelism
All current workloads run single-threaded (Eio fibers on one domain). Using `Eio.Fiber.fork` on multiple domains with `Eio.Domain_manager` could parallelize task execution. But Eta's runtime assumes single-domain fiber coordination.

### Session results
- Baseline: 330,234 ns
- Best: 225,925 ns (-31.6%)
- Key wins: worker pool for bounded (27%), inlined worker pool for unbounded (+6%)

# Eta Signal dynamic-switch allocation ideas

## Retained allocation findings

- OxCaml `or_null` raw values made changed/cutoff allocation depth independent
  and dropped dynamic words from 322 to 290.
- Empty timer-root descendant unlinking now returns immediately.
- The stabilize and delivery pass bodies are stack allocated through local-mode
  `Execution.sync` and `with_phase` parameters; dynamic words are now 273.
- Duplicate-dependency freshness uses a generation-safe candidate registry.
- Successful passes without checkpoints no longer scan all graph slots to clear
  drained queues.
- Timer-free graphs bypass timer discovery and refresh planning.
- Zero or one observer bypasses dependency sorting.
- Empty stale-freshness registries bypass repair setup.

## Dynamic-switch work

- Profile `eta_signal.dynamic.switch` with the bench-identical memtrace probe
  (`.scratch/allocprobe` plus a temporary workspace copy of
  `bench/signal_compare/compare.ml`); attribute every steady-state word.
- Dynamic bind creates and retires a scope per switch; measure scope records,
  the inner-graph node set, and the topology repair pass.
- Measure bind `compute` re-evaluation, the selector `selected`/`inner` refs,
  and `enqueue_stale_freshness` when the inner graph is rebuilt.
- Test OxCaml `local_`/`stack_` on measured per-switch closures and `or_null`
  on measured per-switch options, then guard changed leaves with
  `[@zero_alloc]`.

## Dynamic-switch progress (runs 37-46)

- 273 -> 145 words (-46.9%); dynamic wall 737 -> 590 ns.
- Leaf fast paths for owner-reachability and uninitialized-topology walks (212).
- Stack-allocated Post_commit claim closures, bind validate/retire closures,
  const pass closure; local-mode iter consumers (175 -> 161 area).
- Hoisted recursive retire walks to module-level functions.
- replace_dependency mutates the bind dependency array in place (155 -> 145).

## Remaining measured dynamic sites (145 words)

- make_node node record (25) + signal record (5).
- Rollback capsule closure + record (14).
- Ancestry List.filter (6), enqueue_stale_freshness Hashtbl closure (6).
- Scope record (3) + ancestry cons cells (6).
- Escaping const compute closure (4), change-listener closure (7), initializer
  closures (7), Post_commit event/cursor data (12).
- Candidate: convert the bind rollback capsule to a structured variant; shrink
  the 24-field node record via bool packing (54 access sites); or reuse the
  owner dependency array capacity instead of reallocating on rollback.

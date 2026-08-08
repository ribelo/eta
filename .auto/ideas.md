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

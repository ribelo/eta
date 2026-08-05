# Ideas

- Measure transaction planning, commit, and observer delivery allocation
  separately with scratch-only probes before redesigning their shared state.
- Compare keyed child-only reconciliation with `Incr_map.mapi'` source around
  affected-child notification and output patching.
- After child-only reconciliation reaches a floor, rotate to membership churn,
  retained-data updates, then scalar depth one.
- For graph-construction and retained-memory work, follow
  `.scratch/research/eta-signal-incremental-audit/graph-construction-comparison.md`:
  shared empty topology vectors, lazy dynamic-edge tables, fixed-arity
  constructors, a private keyed-data node, and construction-time scope
  ownership proofs. These do not directly target the current steady-state
  child-only metric.

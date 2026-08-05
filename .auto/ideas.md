# Ideas

- Measure transaction planning, commit, and observer delivery allocation
  separately with scratch-only probes before redesigning their shared state.
- Compare keyed child-only reconciliation with `Incr_map.mapi'` source around
  affected-child notification and output patching.
- After child-only reconciliation reaches a floor, rotate to membership churn,
  retained-data updates, then scalar depth one.

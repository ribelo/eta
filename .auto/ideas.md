# Ideas

## Architectural levers vs the Incremental gap

Final shape before the architecture effort (approx):
- depth 1: ~5.4k words / ~6.6us fixed stabilize floor
- depth 100: ~12.1k words = fixed floor + ~68 words/node
- Incremental depth 1/100: 6 words; map child 10k: 84 words / 121ns

The construction comparison is real, but most of the comparison-table gap is
**stabilization architecture**, not constructor allocation.

### What construction fixes can improve in the table

From `graph-construction-comparison.md`:

1. Shared empty topology vectors + lazy dynamic-edge Hashtbl
   - Helps retained memory and GC/cache.
   - Helps construction and membership/keyed add paths.
   - Does **not** remove the ~5.4k-word stabilize floor.

2. Fixed-arity constructors without temp dependency lists
   - Construction only, unless paired with fixed-arity **execution** (already
     started for unary Map).

3. Compact / deferred reverse edges (report #5, larger redesign)
   - Can make dirty propagation and necessity like Incremental.
   - Touches invalidation, inspection, and demand.
   - Worth a dedicated prototype; not a local patch.

4. Private keyed data node + cheaper scope proof (report #6)
   - Directly targets map membership / data_change rows.
   - Second priority after a stabilize fast path.

### Bigger refactors that can move the table by orders of magnitude

A. **In-place stabilize fast path for static pure graphs**
   - Today every change stages `Signal_snapshot` cells, builds a commit plan,
     and commits through transaction machinery.
   - Incremental writes node fields in place during stabilize.
   - A proven-safe path (no bind switch, no timer refresh, no rollback observers)
     that mutates current value/version/dirty in place would attack every scalar
     and cutoff row and most of the fixed floor.

B. **Collapse the Effect/lane shell for graph-local ops**
   - Depth-1 memtrace is dominated by `Eta_signal_lane.with_sync`, Effect bind
     trees, and non-Eta runtime frames.
   - Incremental has no effect interpreter around stabilize/set.
   - Need an expert/internal entry that preserves cancellation and reentry
     fences without allocating a full effect tree per stabilize.

C. **Edge-local dependency versions instead of snapshot lists**
   - Unary Map still allocates publish snapshot + `[ (id, version) ]` per node.
   - Incremental keeps child versions on the edge/node.
   - Removes a large fraction of the remaining ~74 words/node.

D. **Reusable stabilize protocol state**
   - `begin_stabilize` rebuilds pending/observer/commit/rollback ops records and
     empty bind-timer Hashtables every run.
   - Cache or specialize the no-bind/no-timer shape.

E. Then construction report 1–4 and keyed report 6.

### Recommended order

1. Prototype A+C together on scalar depth-1/100 (biggest table impact).
2. Prototype B only if A still leaves a multi-microsecond floor.
3. Construction 1–2 and keyed 6 for map membership/retained memory.
4. Deferred reverse edges as a separate design spike.

## Smaller leftovers

- Measure transaction planning, commit, and observer delivery allocation
  separately with scratch-only probes before redesigning their shared state.
- Compare keyed child-only reconciliation with `Incr_map.mapi'` source around
  affected-child notification and output patching.
- Skip empty `Hashtbl.create` in `preflight_staged_bind_timers` /
  `timer_demand_plan_unlocked` when registries are empty.
- Avoid `mark_timer_refresh_dirty` closure/list work when no timer refresh
  context is active (CPU; allocation often already optimized away).

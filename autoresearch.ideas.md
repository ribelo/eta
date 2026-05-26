# Deferred Fanout Optimization Ideas

## Proven winners (KEPT)
1. Worker pool (atomic counter) for bounded — eliminates 504 excess fiber creations (-36%)
2. Worker pool for unbounded — bypasses par_collect overhead (-10%)
3. Cap workers at 8 — cache locality from tight loops (-7%)
4. Per-worker frame binding — saves 512 Eio.Fiber.with_binding calls (-2.3%)

## Oracle round 1 results
- ✅ #1: Per-worker frame binding — KEPT (-2.3%)
- ❌ #2: Plain ref instead of atomic — lock xadd faster than split read-write
- ❌ #3: [@inline always] on hot constructors — code bloat regression
- ❌ #4: Direct list-to-task array — traversal overhead > saved allocation
- ⏸️ #5: Remove inner Eio.Switch.run — deprioritized by oracle round 2

## Oracle round 2 — ranked suggestions
1. ❌ Remove per-task inner try/with — prevents bad inlining interaction
2. 📋 Batched atomic counter (sweep 2/4/8/16) — reduces 512 RMWs to ~128
3. 📋 Array.unsafe_set in hot loop — eliminates bounds checks
4. 📋 Short-circuit noop tracer dispatch
5. 📋 Direct map constructor (skip preserve)
6. ⏸️ Switchless success-only prototype (high risk, high complexity)

## Session results
- Baseline: 330,234 ns
- **Best: 215,697 ns (-34.7%)**
- 13 experiments, 4 kept, 9 discarded

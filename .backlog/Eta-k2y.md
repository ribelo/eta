---
id: Eta-k2y
title: "P1: Effect.Island uses real indexed batch executor, not pairwise fork_join2"
status: closed
priority: 1
issue_type: task
created_at: 2026-05-24T09:05:13.684Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — island_runtime.ml uses indexed batch executor, not
  pairwise fork_join2 (44f46a7)
---

# P1: Effect.Island uses real indexed batch executor, not pairwise fork_join2

## description

Bug: packages/eta/effect.ml Island_runtime.map_outcomes_with_parallel and result_outcomes_with_parallel (line ~69) recursively process inputs in pairs via Parallel.fork_join2 (1-or-2 jobs at a time, then recurse on the rest). A pool created with ~domains:N for N>2 only runs two callbacks concurrently per recursive step — pool fanout >2 is unused. Branch research (V-Islands) committed to bounded indexed batch submission.

Location: packages/eta/effect.ml Island_runtime (map_outcomes_with_parallel, result_outcomes_with_parallel)

## design

RED test (write first):
1. Create an island pool with ~domains:8.
2. Submit 8 inputs via Effect.Island.map. Each callback records an entry timestamp (Mtime_clock or equivalent) and then sleeps ~50 ms.
3. Assert the spread between min and max entry timestamps is < 4 * the per-callback sleep (e.g., < 200 ms). On true parallelism the spread is small; with pairwise fork_join2 and N=8 the spread approaches ~200 ms because pairs run sequentially.
4. Tolerance must be loose enough not to flake on slow CI; pick 4x sleep.
5. Regression: assert output ordering matches input ordering (Island.map [a;b;c;d] returns [f a; f b; f c; f d]).

Fix shape:
- Replace pairwise fork_join2 with an indexed work-queue / chunked batch scheduler. Submit up to 'domains' jobs in parallel, collect outcomes by index, reassemble in input order.
- Keep the explicit finite-batch boundary; do not reroute ordinary Effect.all through islands.

## acceptance criteria

RED parallelism test fails on current code and passes after the fix. Output ordering is preserved. Single-input edge case still works.

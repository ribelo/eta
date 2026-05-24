---
id: Eta-0m2
title: "P2: Capabilities.random uses CAS update for shared portable use (no red
  test — race)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:06:46.887Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — part of code review remediation commit (44f46a7)
---

# P2: Capabilities.random uses CAS update for shared portable use (no red test — race)

## description

Bug: packages/eta/capabilities.ml line 7 declares 'type random : value mod portable contended = { seed : int P_atomic.t }'. random_float (lines 110–115) does 'let seed = next_seed (P_atomic.get random.seed) in P_atomic.set random.seed seed; ...' — read/compute/write, not CAS. The type advertises portable contended; concurrent updates can lose increments. Affects Schedule.jittered under concurrent retry/repeat policies (jitter slightly biased under contention).

Location: packages/eta/capabilities.ml random_float (lines 110–115)

## design

No straightforward red test. Race conditions on lost updates are probabilistic and would be flaky in CI; an explicit stress test would have to be probabilistic with thresholds. We do not add such a test to the default suite. Verify by code review.

(Optional, not part of acceptance: a stress fixture in a manual bench dir that spawns N domains, each calling random_float K times, asserts the seed advances at least N*K * 0.99 times. Excluded from dune runtest.)

Fix shape:
- Replace get/compute/set with a CAS loop:
    let rec advance random =
      let old = P_atomic.get random.seed in
      let next = next_seed old in
      if P_atomic.compare_and_set random.seed old next then next
      else advance random
- Or downgrade the kind annotation to single-domain if portable contended is not actually needed by current consumers.

## acceptance criteria

Either the seed update is atomic via CAS, or the kind is narrowed and that narrowing is documented. Existing schedule jitter tests pass (regression check). No flaky stress test added to the default suite.

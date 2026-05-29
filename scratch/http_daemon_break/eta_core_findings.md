# Eta Core Break Session - Additional Findings

## Bug C: Effect.retry does NOT scope per-attempt finalizers

**Root cause:** `Effect.retry` calls `effect.eval()` directly without
`Runtime_core.with_finalizers` wrapping each attempt. Compare with
`Effect.repeat` which creates a fresh `finalizers` ref per iteration.

**Impact:** Resources acquired via `acquire_release` inside a retried effect
are NOT released between attempts. They accumulate and are only released when
the outer scope exits.

**Red test:** `test_effect_retry_releases_resources_each_failed_attempt`
- 3 attempts (2 failed + 1 success)
- Expected: max 1 concurrent resource
- Actual: 3 concurrent resources (all accumulated)

**Reproduction:**
```sh
nix develop -c dune runtest test/eta --force
# → 1 failure! in 1.4s. 251 tests run.
```

## Areas Explored (no bugs found)

- Effect.race: correct exception semantics with Eio.Fiber.any
- Effect.all/par/for_each_par: correct fail-fast with switch cancellation
- Effect.timeout_as: sophisticated token-based exception matching, correct
- Effect.scoped: proper finalizer isolation with with_finalizers
- Effect.uninterruptible: correct cancel_protect wrapping
- Pool: thorough cancellation safety with acquire guards
- Channel: proper deliver/cancel race handling
- PubSub: correct entry lifecycle with remaining counts
- Semaphore: correct state machine for Waiting/Resolved_unclaimed/Claimed
- Par scheduler: heartbeat-based work stealing, correct within single-domain
- run_finalizers: catches individual finalizer exceptions, all finalizers run

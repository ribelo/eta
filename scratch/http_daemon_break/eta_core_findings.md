# Eta Core Break Session - Additional Findings

## Bug C: Effect.retry does NOT scope per-attempt finalizers

**Root cause:** `Effect.retry` calls `effect.eval()` directly without
`Runtime_core.with_finalizers` wrapping each attempt. Compare with
`Effect.repeat` which creates a fresh `finalizers` ref per iteration.

**Impact:** Resources acquired via `acquire_release` inside a retried effect
are NOT released between attempts. They accumulate and are only released when
the outer scope exits. With long retry schedules and expensive resources
(connections, file handles), this causes sustained resource pressure.

**Red tests:**
- `test_effect_retry_releases_resources_each_failed_attempt` (Effect #77)
- `test_retry_resource_accumulation_systematic` (Stress #3)

**Reproduction:**
```sh
nix develop -c dune runtest test/eta --force
# → 2 failures! in 1.4s. 256 tests run.
```

**Workaround:** Wrap the retried effect body in `Effect.scoped`:
```ocaml
(* BAD: resources accumulate *)
Effect.retry schedule pred (acquire_release ~acquire ~release |> bind body)

(* GOOD: resources released per attempt *)
Effect.retry schedule pred (Effect.scoped (acquire_release ~acquire ~release |> bind body))
```

## Green Tests Added

- Pool stress: concurrent acquire/release (no resource leak) ✓
- Semaphore stress: permit accounting under concurrent access ✓
- Channel stress: no lost messages with concurrent senders/receivers ✓
- Nested scope+catch+retry: demonstrates correct scoped-inside-retry pattern ✓

## Areas Explored (no bugs found)

- Effect.race: correct exception semantics with Eio.Fiber.any
- Effect.all/par/for_each_par: correct fail-fast with switch cancellation
- Effect.timeout_as: sophisticated token-based exception matching, correct
- Effect.scoped: proper finalizer isolation with with_finalizers
- Effect.uninterruptible: correct cancel_protect wrapping
- Effect.repeat: correctly scopes each iteration (unlike retry)
- Effect.finally: correct isolated cleanup scope
- Effect.catch: only one accumulation (bounded, by design)
- Pool: thorough cancellation safety with acquire guards
- Channel: proper deliver/cancel race handling
- PubSub: correct entry lifecycle with remaining counts
- Semaphore: correct state machine for Waiting/Resolved_unclaimed/Claimed
- Par scheduler: heartbeat-based work stealing, correct within single-domain
- Supervisor: proper child cancellation and finalizer ordering
- Blocking runtime: proper thread lifecycle with cancellation
- run_finalizers: catches individual finalizer exceptions, all finalizers run
- AI SSE stream: correctly catches body errors (affected by Bug A/B indirectly)

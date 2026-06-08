# P0-T4 Supervisor State Probe

Status: final for Effet-OxCaml-r18.

Question: should supervisor failure state use Capsule-protected mutable state or a Portable.Atomic immutable list?

## Artifacts

- capsule_state_positive.ml: Capsule.Expert.Data plus Capsule.Blocking_sync.Mutex supervisor state.
- atomic_state_positive.ml: Portable.Atomic supervisor state over immutable failure list plus count.
- atomic_payload_negative.ml: nonportable closure failure payload rejected at the Parallel boundary.
- results/compile.out and per-fixture logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/supervisor_state_probe/run.sh

Last result:

    summary: pass=3 fail=0

## Evidence

Both candidate implementations pass a two-domain stress fixture. Each appends 500 integer failures from two Parallel workers, verifies count 500, verifies the checksum 125250, and verifies max_failures threshold behavior.

Capsule is viable but heavier. The working Capsule branch uses Capsule.Expert to create a branded capsule, Capsule.Expert.Data to hold mutable supervisor state, and Capsule.Blocking_sync.Mutex to serialize access. It is 71 lines in the fixture and returning aliased data directly out of the capsule hit uniqueness friction, so the fixture computes count/sum/threshold inside the lock instead of returning the failure list.

Portable.Atomic is also viable and simpler. The working atomic branch is 53 lines, uses an immutable list in Portable.Atomic.t plus an atomic count, and directly snapshots List.rev (Atomic.get failures). This shape matches the current supervisor API, which needs append, failures, and check only.

The nonportable-payload negative fails at compile time when a closure capturing int ref is appended from Parallel. This is the same static boundary Phase 3/5 need for portable supervisor failures.

## Comparison

| Criterion | Capsule + mutex | Portable.Atomic list |
| --- | --- | --- |
| Stress append | Pass | Pass |
| max_failures check | Pass | Pass |
| Read failures list | Possible, but aliased return is awkward | Direct snapshot |
| Fixture size | 71 lines | 53 lines |
| Runtime protocol fit | Best for complex mutable state/invariants | Best for append-only immutable snapshots |
| API complexity | Brand/key/password/mutex ceremony | Ordinary record with atomic fields |
| Failure payload safety | Indirect through Parallel closure boundary | Direct negative fixture |

## Decision diary

- V-P0T4-1 - Use Portable.Atomic for supervisor failures.
  Decision: Phase 3 / Phase 5 should represent supervisor failure history as a Portable.Atomic immutable list plus a count.
  Rationale: it satisfies append/read/check under Parallel stress with less ceremony and matches the existing append-only contract.

- V-P0T4-2 - Keep Capsule for richer mutable runtime state.
  Decision: use Capsule when runtime state has multiple mutable fields that must be read/written under one lock, needs condition variables, or requires a nontrivial invariant across fields.
  Rationale: the Capsule branch works and is the right abstraction for guarded mutable protocols, but supervisor failures do not need that machinery.

- V-P0T4-3 - Do not return capsule-owned mutable lists as the normal supervisor API.
  Decision: if a future capsule-backed structure must expose state, materialize an immutable snapshot under the lock.
  Rationale: directly returning the aliased list from Capsule.Expert.Data.extract hit uniqueness friction; computing or copying inside the lock is the safer API shape.

## Deferred

- Phase 3 should update supervisor internals to use the atomic shape once Cause.Portable is implemented.
- If supervisor state grows beyond append/read/check, re-run the Capsule branch with the real invariant before promoting it.


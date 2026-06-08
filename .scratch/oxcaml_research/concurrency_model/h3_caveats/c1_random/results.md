# C1 Random Capability Verdict

## Question

Can Schedule.jittered avoid global Random.float during worker-side schedule
interpretation without moving jitter entirely back to the coordinator?

## Candidates

| Candidate | Evidence | Verdict |
| --- | --- | --- |
| Object-method capability, matching Logger/Tracer/Meter shape | object_capability_probe fails: OxCaml reports the object value is nonportable when captured by a parallel worker. | Rejected for H3 portable boundary. |
| Portable RNG token backed by Portable.Atomic seed | portable_rng_token_positive passes across Parallel.fork_join2. | Chosen. |
| Coordinator-materialized delays | coordinator_delays_positive passes for finite batches, but coordinator_delays_finite_negative shows worker-side interpretation runs out of delay data. | Valid only for finite batch reductions; rejected for Phase 6 worker-side schedule interpretation. |
| Global Random.float in worker | global_random_negative compiles, so compiler alone will not reject it. The C5 policy gate must reject it by code review/grep. | Rejected by policy and shipped code. |
| Captured Random.State.t or mutable ref seed | Negative fixtures fail at compile time. | Rejected by compiler. |

## Decision

Use a portable random token: Capabilities.random.

Schedule.next_delay accepts an explicit optional random token, and Runtime.create
owns one token per runtime. H3 worker runtimes must receive explicit
coordinator-provided seeds or worker-local tokens. Schedule.jittered no longer
calls Random.float, and core scheduling code no longer calls stdlib Random.

## Latest Run

summary: pass=7 fail=0

# H3 Implementation Acceptance Checklist

## Verdict

H3 is ready to guide Effet-OxCaml-7dp Phases 5-8, with the conditions below. H4 does not reopen from this hardening pass. H5 does not reopen from observability cost.

The accurate model name is per-domain local execution with explicit portable handoff and coordinator-owned reassembly.

## Gate Command

nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/run.sh

Latest probe summaries:

| Probe | Summary |
| --- | --- |
| T1 inbox | pass=6 fail=0 |
| T2 cancellation | pass=2 fail=0 |
| T3 ordered results | pass=3 fail=0 |
| T4 supervisor order | pass=3 fail=0 |
| T5 Cause.Portable | pass=8 fail=0 |
| T6 observability | pass=3 fail=0 |
| T7 timeout/clock | pass=3 fail=0 |
| T8 Eio non-leakage | pass=12 fail=0 |
| T9 skew benchmark | pass=2 fail=0 |

## Checklist

| Invariant | Required condition | Proved by | Follow-up if broken |
| --- | --- | --- | --- |
| Inbox ownership | Coordinator is the only producer; it closes the inbox before worker drain. No concurrent push/drain in H3. | T1 Effet-OxCaml-8cx | Replace inbox with a real linearizable bounded queue. |
| Task identity | Every dispatched child has a stable input index. | T3 Effet-OxCaml-nbb | Runtime cannot ship ordered combinators. |
| Result ordering | all, for_each_par, and all_settled reassemble by input index, never completion order. | T3 Effet-OxCaml-nbb | Keep runtime same-domain or add indexed result store first. |
| Failure ordering | Cross-domain Supervisor.failures returns task-index order; max_failures thresholds use that order. | T4 Effet-OxCaml-xbw | Split portable supervisor API or document weaker ordering. |
| Cancellation | Workers poll Portable.Atomic cancel at Bind/Map boundaries and at least every 4096 pure-core loop iterations. | T2 Effet-OxCaml-3ik | Phase 6 cancellation cannot ship. |
| Timeout/clock | Coordinator sends int64 monotonic-ns deadlines; workers compare locally at T2 polling points. | T7 Effet-OxCaml-09k | Keep timeout/delay/retry on same-domain runtime. |
| Observability | Workers emit portable events keyed by task_id/event_index; coordinator owns export and mutable collectors. | T6 Effet-OxCaml-5ab | Reopen H5 if reassembly exceeds 30 percent. |
| Eio non-leakage | Eio handles, Runtime.t, raw Cause.t, tracer/logger/meter collectors do not cross worker boundary. | T8 Effet-OxCaml-cex | Boundary is policy-only and must not ship. |
| Backpressure | Bounded inbox capacity applies during coordinator push phase; closed inbox rejects late pushes. | T1 Effet-OxCaml-8cx | Replace with linearizable bounded queue before Phase 8 transport. |
| Dispatch under skew | Coordinator uses explicit least-loaded assignment; Portable_ws_deque remains reserved for future H4. | T9 Effet-OxCaml-rdr | Reopen H4 steal-on-empty design. |

## Phase Impact

| Phase | Impact |
| --- | --- |
| Phase 5 capsule runtime state | Runtime mutable state stays coordinator/same-domain owned unless represented by portable atomics. |
| Phase 6 domain-parallel runtime | Runtime.run follows the H3 protocol: phase-separated inboxes, indexed results, task-index failures, Cause.Portable, deadline payloads, and least-loaded dispatch. |
| Phase 7 portable Resource | Auto-refresh uses H3 dispatch and Cause.Portable failures; Resource state remains Portable.Atomic. |
| Phase 8 Stream/exporter | Online cross-domain transport requires a real linearizable bounded queue per V-CM-H2-C2. H3 close-before-drain inboxes remain batch-only and are not valid for live producer/consumer transport. Exporter sinks remain coordinator-owned. |

## Closed Caveat

Effet-OxCaml-jak closed the Schedule.jittered caveat. Core scheduling code no
longer calls stdlib Random. H3 worker runtimes must pass explicit
Capabilities.random tokens seeded by the coordinator or created per worker.

# Effet Blocking I/O Decision

Status: accepted for downstream implementation design.

Scope: research only. This file records the `Effet-OxCaml-5hk` verdict and does
not ship package code.

## Decision

Effet should add a bounded blocking I/O boundary for legacy blocking work:

```ocaml
Effect.Blocking.submit :
  ?pool:Blocking.Pool.t ->
  ?name:string ->
  (unit -> 'a) ->
  ('a, 'err) Effect.t
```

The default implementation should be a bounded pool with:

- a hard active-worker limit,
- a hard queued-job limit,
- `Wait` and `Reject` full-queue policies,
- pending-job cancellation,
- nonpreemptive started-job semantics,
- labels,
- counters,
- job timing summaries,
- explicit shutdown.

Effet should also expose an explicit domain-isolated escape hatch for bindings
that hold the OCaml runtime lock:

```ocaml
Blocking.Pool.create_domain_isolated : config -> Blocking.Pool.t
```

This API must be opt-in and documented as advanced. It exists because
lock-holding C cannot be repaired by a systhread pool.

Resource isolation should be solved by manual named pools in v1:

```ocaml
let db_pool = Blocking.Pool.create ~name:"db" ...
let fs_pool = Blocking.Pool.create ~name:"fs" ...
```

Do not ship built-in DB/FS/SDK resource-class sugar until production users need
that extra API. The evidence supports the capability, not the convenience layer.

## Candidate Verdicts

| Candidate | Verdict | Reason |
| --- | --- | --- |
| B0 direct blocking inside Eio | Reject | A 50 ms blocking call reduced heartbeat to one sample with p99 near 49 ms. |
| B1 raw `Eio_unix.run_in_systhread` | Reject as public API | It preserves heartbeat for ordinary blocking work but created 102 threads for 100 jobs and has no Effet admission policy. |
| B2 bounded blocking pool | Accept | It bounded active work at 4, bounded queue at 64, kept heartbeat p99 near 11-12 us in stress probes, and exposed stats/cancellation labels. |
| B2 plus B3 | Accept | B2 does not save lock-holding C; B3 restored heartbeat p99 to 3-8 us for hold-lock probes. |
| B4 resource-class pools | Accept as manual pools | Shared pool delayed a DB probe by 503 ms; separate or limited pools completed DB work in 2 ms. |
| CPU through blocking pool | Reject | Blocking CPU work was same-order as same-domain CPU and delayed an I/O probe by 47 ms; island finished the same fixture in 29 ms. |

## Gates

### Gate 1: B1 Is Not Enough

`Eio_unix.run_in_systhread` is responsive for simple sleeps:

| Probe | Result |
| --- | --- |
| smoke | p99 heartbeat 14 us |
| 10 jobs | 12 threads after run |
| 100 jobs | 102 threads after run |
| 1000 jobs | 551 threads after run, RSS 12 MB to 28 MB, p99 heartbeat 3779 us |

Gate result: B1 can be an implementation substrate, but not the Effet API.

### Gate 2: B2 Must Bound Admission

The B2 stress run with 100 jobs, `max_threads=4`, and `max_queued=64` completed
with:

| Metric | Value |
| --- | --- |
| threads after run | 6 |
| peak active threads | 4 |
| peak queued jobs | 64 |
| completed jobs | 100 |
| heartbeat p99 | 12 us |

The B2 matrix was slower than B1 for 100 short jobs:

| Mode | Elapsed | Threads after | Heartbeat p99 |
| --- | --- | --- | --- |
| B1 raw systhread | 4899 us | 102 | 20 us |
| B2 bounded pool | 76967 us | 6 | 11 us |

Gate result: B2 trades raw burst latency for bounded resource use. That is the
right default for a library API.

### Gate 3: B2 Plus B3 Is Required For Lock-Holding C

Systhread offload works only when the C binding releases the runtime lock.

| Probe | Mode | Heartbeat p99 |
| --- | --- | --- |
| release-lock sleep | `run_in_systhread` | 11 us |
| hold-lock sleep | `run_in_systhread` | 49188 us |
| hold-lock CPU | `run_in_systhread` | 52217 us |
| hold-lock sleep | domain isolated | 8 us |
| hold-lock CPU | domain isolated | 3 us |

Gate result: normal blocking I/O uses B2. Known or suspected lock-holding C uses
the explicit B3 pool.

### Gate 4: CPU Rejection

| Probe | Elapsed | Heartbeat / contention |
| --- | --- | --- |
| same-domain CPU | 57606 us | heartbeat p99 56623 us |
| blocking-pool CPU | 63432 us | I/O probe waited 47 ms |
| island CPU | 29444 us | fastest fixture |

Gate result: blocking pools are for blocking I/O. CPU work stays with islands.

## Measured Default Configuration

Use these as the first implementation defaults because they are the values
covered by this lab, not because they are globally optimal:

| Setting | Recommendation | Evidence |
| --- | --- | --- |
| `max_threads` | 4 | B2 stress completed 100 jobs with p99 heartbeat 12 us and `threads_after=6`. |
| `max_queued` | 64 | B2 stress reached `peak_queued_jobs=64` without losing responsiveness. |
| full-queue policy | `Wait` by default; `Reject` available | Wait preserved completion; Reject reported 4 rejected jobs deterministically. |
| cancellation | cancel pending; do not preempt started | Pending cancellation incremented `cancelled_before_start`; started job still finished after about 40 ms. |
| resource pools | named manual pools | Separate DB/FS pools reduced DB latency from 503 ms to 2 ms. |
| labels | required `?name` or inherited operation name | Trace-label probe recorded `pg.query,legacy.fs.read,aws-sdk.put`. |
| shutdown | stop accepting, drain or detach started work explicitly | Started jobs finished after shutdown; detached jobs returned in 45 us and completed later. |

Do not bake a larger default such as 32 threads or 1024 queued jobs from this
ticket. That scale needs a separate implementation benchmark.

## Production API Notes

The public API should prefer ordinary OCaml dependency passing. Do not re-add an
Effet environment type parameter for blocking pools.

Worker callbacks must not call Eio operations, run nested Effet runtimes, submit
nested blocking work, or resolve parent-domain promises. Some simple probes
appeared to work, but they are not a stable contract.

Worker exceptions should surface as defects in normal `submit` calls. Typed
business errors should use ordinary `result` values returned by the callback.

Detached jobs need production-grade logging or metric emission for exceptions.
The scratch prototype records detached completion, but does not provide a real
tracer.

## Open Implementation Questions

- Whether production B2 owns `Thread.create` workers directly or keeps
  `Eio_unix.run_in_systhread` behind Effet admission.
- How to implement and test idle worker teardown if that behavior is part of
  the public pool contract.
- How much load matrix is needed before increasing the default from the measured
  `max_threads=4`, `max_queued=64` seed.
- Whether domain-isolated pools should use raw `Domain.spawn`, a scheduler
  abstraction, or a dedicated internal worker service. The probe triggered
  OxCaml domain-spawn safety alerts, so this surface must stay explicit.

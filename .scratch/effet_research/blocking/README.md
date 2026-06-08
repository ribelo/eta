# Blocking I/O Research Lab

This lab is the evidence bundle for `Effet-OxCaml-5hk`. It tests whether Effet
should add a blocking I/O boundary, what runtime substrate that boundary needs,
and which work must stay out of that boundary.

The lab is research-only. It does not change `packages/effet`.

## Quick Start

Run the full evidence gate from the repository root:

```sh
nix develop -c bash scratch/effet_research/blocking/run.sh
```

The runner writes the latest measurements to:

```text
scratch/effet_research/blocking/run.out
```

## What Was Tested

| Area | Files | Question |
| --- | --- | --- |
| Baselines | `baselines/` | Does direct blocking freeze Eio, and is raw `Eio_unix.run_in_systhread` enough? |
| C stubs | `c_stubs/` | Does systhread offload save us when a C binding holds the OCaml runtime lock? |
| Bounded pool | `bounded_pool/` | Can Effet bound thread creation and queue pressure while preserving responsiveness? |
| Cancellation | `cancellation/` | What can cancellation do before and after a blocking job starts? |
| Resource classes | `resource_classes/` | Do DB and FS style blocking calls need independent capacity? |
| Domain isolation | `domain_isolated_optional/` | Is a domain-isolated escape hatch required for lock-holding C bindings? |
| CPU rejection | `api_ergonomics/cpu_vs_island/` | Should blocking pools run CPU work? |
| Error model | `api_ergonomics/error_model/` | How should worker returns, exceptions, and typed errors surface? |
| Worker restrictions | `api_ergonomics/worker_restrictions/` | Which same-domain/Eio operations must be forbidden inside workers? |
| Observability | `api_ergonomics/observability/` | Are labels, stats, and timings sufficient for the first API? |

## Decision Summary

Use a bounded Effet-owned blocking pool for normal legacy blocking I/O.

Add a domain-isolated escape hatch for C bindings that hold the OCaml runtime
lock. Do not hide it as the default; the domain API should be explicit and
treated as advanced.

Expose manual named pools or pool overrides for resource classes. DB-like work
and FS/SDK-like work must not be forced through one global queue.

Reject raw `Eio_unix.run_in_systhread` as the public Effet API. It is useful as
a substrate, but the direct baseline created 102 threads for 100 short jobs and
has no Effet-owned queue, labels, stats, or admission policy.

Reject CPU work on the blocking pool. CPU work belongs in the island path.

## Important Limits

The B2 prototype is a bounded admission layer over `Eio_unix.run_in_systhread`.
It proves queueing, cancellation boundaries, resource isolation, and observability
shape. It is not a final custom worker implementation.

The prototype does not prove an idle-timeout worker lifecycle. If the production
API requires exact Tokio-style worker reuse and idle teardown, the implementation
epic must either own system threads directly or prove the Eio substrate provides
the needed behavior.

Started blocking jobs are not preemptively cancelled. Pending work can be
cancelled before start; started work can only finish normally, raise, or observe
an explicit user-provided cooperative cancel handle.

## Result Files

- `baselines/results.md`
- `c_stubs/results.md`
- `bounded_pool/results.md`
- `cancellation/results.md`
- `resource_classes/results.md`
- `domain_isolated_optional/results.md`
- `api_ergonomics/cpu_vs_island/results.md`
- `api_ergonomics/error_model/results.md`
- `api_ergonomics/worker_restrictions/results.md`
- `api_ergonomics/observability/results.md`
- `legacy_use_cases/results.md`
- `decision.md`

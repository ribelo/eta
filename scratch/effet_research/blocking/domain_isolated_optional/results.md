# Domain-Isolated Results

Status: B3 accepted as an explicit escape hatch.

## What Was Tested

The domain-isolated probe runs lock-holding C stubs away from the main Eio
domain and measures main-domain heartbeat responsiveness.

## Evidence

| Variant | Elapsed | Heartbeat samples | Heartbeat p99 |
| --- | --- | --- | --- |
| hold-lock sleep | 50279 us | 50 | 8 us |
| hold-lock CPU | 53112 us | 53 | 3 us |

The same stubs through `Eio_unix.run_in_systhread` had heartbeat p99 around
49-53 ms.

## Consequence

Domain isolation is required for lock-holding C. It should not be the normal
blocking path because it carries a stronger safety story than normal systhreads.

The build prints OxCaml domain-spawn safety alerts around `Domain.spawn`. Treat
that as supporting evidence for a deliberately explicit API, not as a reason to
hide the behavior.

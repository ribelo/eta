# CPU vs Island Results

Status: CPU work rejected for blocking pools.

## What Was Tested

The same CPU fixture ran same-domain, through the blocking pool, and through the
existing island path.

## Evidence

| Mode | Elapsed | Responsiveness / contention |
| --- | --- | --- |
| same-domain thunk | 57606 us | heartbeat p99 56623 us |
| blocking pool | 63432 us | I/O probe waited 47 ms |
| island pool | 29444 us | fastest fixture |

## Consequence

Blocking pools are for blocking I/O, not CPU parallelism.

The implementation should document this boundary and avoid naming that suggests
general-purpose parallel compute. CPU work remains an island concern.

# Baseline Results

Status: B0 rejected. B1 rejected as the public Effet API.

## What Was Tested

The baseline probes compare direct blocking inside an Eio fiber with raw
`Eio_unix.run_in_systhread`.

Run through:

```sh
nix develop -c bash scratch/effet_research/blocking/run.sh
```

## Evidence

Direct blocking froze the scheduler for the whole 50 ms sleep window:

| Variant | Elapsed | Heartbeat samples | Heartbeat p99 |
| --- | --- | --- | --- |
| Unix sleep | 50062 us | 1 | 49082 us |
| release-lock C sleep | 50074 us | 1 | 49093 us |
| hold-lock C sleep | 50069 us | 1 | 49092 us |

Raw `Eio_unix.run_in_systhread` preserved responsiveness for ordinary blocking
sleep, but it did not bound thread creation:

| Jobs | Elapsed | Threads before | Threads after | Heartbeat p99 |
| --- | --- | --- | --- | --- |
| smoke | 50153 us | n/a | 3 | 14 us |
| 10 | 2482 us | 1 | 12 | 30 us |
| 100 | 6878 us | 12 | 102 | 233 us |
| 1000 | 21234 us | 102 | 551 | 3779 us |

The 1000-job run also grew RSS from 12760 KB to 28152 KB.

## Consequence

Effet must not run blocking calls directly inside Eio fibers.

`Eio_unix.run_in_systhread` is acceptable as a low-level substrate for normal
blocking I/O, but not as the public Effet API. Effet needs its own admission
policy, queue bounds, labels, stats, and cancellation contract.

# DX-E11 red-team packet

Run both adversarial fixtures:

```sh
.scratch/research/dx/e11/redteam/run.sh
```

The script succeeds only when the daemon fixture passes and the deliberately
broken retry golden check fails.

## Broken retry

`test/test/dx_e11_broken_retry.ml` substitutes a linear 10/20/30 schedule for
the canonical exponential 10/20/40 schedule. `broken-output.txt` preserves the
complete failing Alcotest output. The output shows both complete executions and
localizes the only difference to sleep `[2]`.

## Pending daemon

`test/test/dx_e11_daemon_pending.ml` leaves an owned daemon blocked forever.
`daemon-output.txt` preserves its complete outcome. The pending entry is
classified `daemon(runtime-owned)`; `daemon-pending.md` explains why that is
owned work rather than a leak and how structured pending work would differ.

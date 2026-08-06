# Eta Signal edge-seam probe

This throwaway probe runs the selected timer and observer protocol through the
issue 09 `Execution.run` seam and an Eta/Eio runtime.

It compares three matched operation tapes with the pinned Signal engine:

- observer failure and retry
- observer registration and disposal
- timer start, wake, stabilization, and stop

Run all checks and measurements:

```sh
.scratch/research/eta-signal-execution-model/edge-seam-probe/run.sh
```

The probe does not implement the public Signal API. It tests the private
composition that issues 09 and 10 select.

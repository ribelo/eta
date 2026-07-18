# DX-E24 blinded review packet

Two independent A/B pairs, each preserving behavior while changing only the
public call shape:

| Pair | Old | New | Scenario |
|---|---|---|---|
| Parallel map | `par-old.ml` | `par-new.ml` | Fetch IDs with a cap of four; collect in input order; fail fast |
| Retry fallback | `retry-old.ml` | `retry-new.ml` | Retry typed unavailability, then change the error type in a fallback |

The old files are historical syntax fixtures and are intentionally not compiled
against the new tree. The new files use the final amended E24 contract.

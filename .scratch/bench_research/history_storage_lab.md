# Bench History Storage Lab

## Candidates

| Storage | Result |
| --- | --- |
| Committed JSON under `bench/results/` | Chosen. Fresh clones get the history, diffs are reviewable, and no extra Git transport setup is required. |
| Git notes | Rejected for v0. Cleaner commit history, but notes are easy to forget to fetch and push. |
| External sink | Rejected for v0. Better for dashboards later, but it adds an operated service before the project has baseline data. |

## Decision

Use committed JSON files named `bench/results/<timestamp>-<sha>.json`.
Each file records the commit, commit time, run time, dirty flag, machine fingerprint,
and benchmark measurements. Cross-machine comparison stays a human decision; the
fingerprint is present so obviously mismatched results are not mistaken for regressions.

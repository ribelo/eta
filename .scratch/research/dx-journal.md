# DX programme journal (V-DX-*)

Programme log for DX-PRD-0001 (`dx-prd-0001.md`, same directory). Append-only:
corrections are new entries referencing old ones. Orchestrator-sealed
predictions land here on master before each experiment branch is cut;
executors seal their own predictions in their branch journals. The legacy
`.scratch/research/journal.md` is frozen history; this file is the live
record. Durable curated conclusions land in `docs/research/dx.md`.

## Dashboard (copy of DX-PRD-0001 §6; both updated after every experiment)

| ID | Title | Phase | Effort | Risk | Status | SC | Branch | Evidence |
|----|-------|-------|--------|------|--------|----|--------|----------|
| E23 | Error channel mirrors Result | A | M | low | in-progress | | research/dx-e23-result-error-channel | V-DX-E23-001 |
| E24 | Iteration mirrors List; slim Schedule | A | M | low-med | proposed | | | |
| E25 | Family consistency renames | A | S-M | low | proposed | | | |
| E1 | sync_result / sync_option | B | S | low | proposed | | | |
| E2 | discard / ignore_errors | B | S | low | proposed | | | |
| E3 | race_either | B | S | low | proposed | | | |
| E4 | Cause rendering corpus | B | M | low | proposed | | | |
| E5 | Type-error translations | B | S | low | proposed | | | |
| E6 | Scoped.with_2/3 (kills and@) | B | M | low | proposed | | | |
| E7 | Error-pp deriver | C | M | low | proposed | | | |
| E8 | [%eta.result] sugar | C | S | low | proposed | | | |
| E9 | Syntax.Parallel/Applicative | C | M | med | proposed | | | |
| E10 | let%eta function sugar | C | M | med | proposed (hold default) | | | |
| E26 | Effect.fresh | D | S | low | proposed | | | |
| E19 | Scoped capability override | D | M | med | proposed | | | |
| E20 | intercept_log/metric | D | M | low-med | proposed | | | |
| E11 | Eta_test.run golden record | D | L | med | proposed | | | |
| E12 | audit / describe | D | M | low | proposed | | | |
| E13 | Effect.async | D | M-L | med | proposed | | | |
| E14 | Eta.Promise | D | M | med | proposed (hold-gated) | | | |
| E22 | Law-property policy | E (flex) | M | low | proposed | | | |
| E15 | interruptible / restore | E | M | high | proposed | | | |
| E16 | Reader validation race | E | S | low | proposed (expected kill) | | | |
| E21 | Resumable probe (.scratch) | E | S | contained | proposed (expected kill) | | | |
| E17 | Capability phantom rows | E | L | high | proposed (gated) | | | |
| E18 | Simulation testing | E | L | med | proposed | | | |

---

## V-DX-000 — 2026-07-18 — programme start

DX-PRD-0001 adopted from the executor-facing draft with Amendment 1:
human-relayed topology (orchestrator / intermediary / executor), three-tier
journal architecture, dual-sealed predictions, oracle-based blind review with
a fixed persona (P-OCaml default per experiment, others per one-pager),
sequential execution with orchestrator-discretion batching. The human's
instructions outrank the plan. Taste constitution §2 and stop conditions §4.6
unchanged. Git: orchestrator manages master, branches, and pushes.

Protocol notes for future readers: agent-run persona evidence is labelled
`[agent-sim]`; promote decisions resting solely on it are flagged
`spot-check`. Blind-review packets are assembled and randomized by the
orchestrator from executor-labeled material; the oracle never sees labels,
goals, or implementations.

# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **B** (hygiene)
- In flight: **batch 2 — E4 (Cause rendering corpus) + E5 (type-error
  translations)**
  - Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e4e5`
  - Branch: `research/dx-e4e5-cause-corpus-type-errors`
  - Stage: predictions sealed (V-DX-E4-001, V-DX-E5-001); objective.md
    written; awaiting executor
- Done: Phase A complete (E23/E24/E25 promoted) · Phase B batch 1 landed —
  **E1** `sync_result` promoted (`sync_option` killed, no usage) ·
  **E2** `discard`/`ignore_errors` promoted · **E3** `race_either` killed
  (named variants beat either tags) — master `9ce618ac`
- Queue: E4+E5 → E6 (`Scoped.with_2/3`, kills `and@`) → Phase B synthesis →
  Phase C (E7–E10)
- Backlog: E24b hook-ownership; retry cause-alignment; F1 signal_jsoo;
  F2 `fold ~ok:Fun.id` noise; F3 `catch_recovery.ml` filename; F4 `map_par`
  omission misreading; F5 `Supervisor.scoped` vocabulary; candidate:
  `map_par` default-8 bench experiment
- Pending decisions: none
- Last update: 2026-07-18 — Phase B batch 2 staged

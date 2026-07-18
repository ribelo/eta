# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **B** (hygiene)
- In flight: **Batch 1 — E1 sync_result/sync_option · E2
  discard/ignore_errors · E3 race_either**
  - Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e1e2e3`
  - Branch: `research/dx-e1e2e3-hygiene`
  - Stage: predictions sealed (V-DX-E1/E2/E3-001); objective.md written;
    awaiting executor
- Done: Phase A complete — E23/E24/E25 promoted (V-DX-PHASE-A)
- Queue: Phase B — E1+E2+E3 batched (one worktree, per-experiment
  sections) → E4+E5 → E6; E2 extends the CHANGELOG idiom-pass entry
- Backlog: E24b hook-ownership; retry cause-alignment; F1 signal_jsoo;
  F2 fold ~ok:Fun.id noise; F3 catch_recovery.ml; F4 map_par omission
  misreading; F5 Supervisor.scoped vocabulary; candidate: map_par
  default-8 bench experiment
- Pending decisions: none
- Last update: 2026-07-18 — Phase B batch 1 launched

# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: A (idiom pass)
- In flight: **E25 — Family consistency** (`with_scope`, `named ?kind`,
  `now_ms`, `error_pp`)
  - Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e25`
  - Branch: `research/dx-e25-family-consistency`
  - Stage: predictions sealed (V-DX-E25-001); objective.md written; awaiting executor
- Done: **E23 promoted** (`66bad437`) · **E24 promoted** (`29bd23e9`,
  amended contract; Schedule slimming held → E24b)
- Queue: **E25** (family consistency: `with_scope`, `named ?kind`, `now_ms`,
  `error_pp`) → Phase A synthesis (V-DX-PHASE-A, incl. E24b + retry
  cause-alignment backlog) → Phase B
- Open follow-ups: F1 signal_jsoo JS bit-rot; F2 `fold ~ok:Fun.id` noise;
  F3 `catch_recovery.ml` filename; F4 omission-vs-unbounded misreading
  (mitigated; watch); E24b hook-ownership; retry cause-alignment decision
- Pending decisions: none
- Last update: 2026-07-18 — E25 launched

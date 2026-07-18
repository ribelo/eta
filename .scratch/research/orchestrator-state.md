# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: A (idiom pass)
- In flight: nothing
- Done: **E23 promoted** (`66bad437`) · **E24 promoted** (`29bd23e9`,
  amended contract after oracle consensus; Schedule slimming held → E24b)
- Queue: **E25** (family consistency: `with_scope`, `named ?kind`, `now_ms`,
  `error_pp`) → Phase A synthesis (V-DX-PHASE-A, incl. E24b + retry
  cause-alignment backlog) → Phase B
- Open follow-ups: F1 signal_jsoo JS bit-rot; F2 `fold ~ok:Fun.id` noise;
  F3 `catch_recovery.ml` filename; F4 omission-vs-unbounded misreading
  (mitigated; watch); E24b hook-ownership; retry cause-alignment decision
- Pending decisions: none
- Last update: 2026-07-18 — E24 promoted

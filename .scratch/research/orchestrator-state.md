# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **B** (hygiene) — final experiment
- In flight: **E6 — `Effect.Scoped.with_2`/`with_3` (kills `and@`)**
  - Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e6`
  - Branch: `research/dx-e6-scoped-with-helpers`
  - Stage: predictions sealed (V-DX-E6-001); objective.md written; awaiting executor
- Done: Phase A complete (E23/E24/E25 promoted) · Phase B — **E1**
  `sync_result` promoted (`sync_option` killed) · **E2** promoted · **E3**
  killed (named variants) · **E4** promoted (kill gate fired, rework
  passed) · **E5** promoted — master `f7395b0f`
- Queue: E6 → **Phase B synthesis** →
  Phase C (E7–E10)
- Backlog: E24b hook-ownership; retry cause-alignment; **same-domain
  runtime fence for Channel/Pubsub/Pool** (silent hang → named error);
  dead PPX rejections ×2 (delete candidates); resource/pool escape-fence
  question; `Supervisor.Scope.start` first-contact error; compact `die`
  terminology watch; F1 signal_jsoo; F2 `fold ~ok:Fun.id` noise; F3
  `catch_recovery.ml`; F4 `map_par` omission misreading; F5
  `Supervisor.scoped` vocabulary; candidate: `map_par` default-8 bench
- Pending decisions: none
- Last update: 2026-07-19 — E6 launched

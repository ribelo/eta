# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **C** (syntax & PPX) — E7 promoted
- In flight: nothing
- Done (Phase C): **E7 promoted** (`df55d1df`) · **E8 promoted** (merged
  `--no-ff`, master gates green, pushed; worktree removed)
- Done: Phase A (E23/E24/E25) · Phase B (E1/E2/E3-k/E4/E5/E6-k) ·
  **E7 promoted** (`df55d1df`) — `[@@deriving eta_error]`, zero hand-written
  telemetry printers in examples
- Queue: **E9** (Syntax.Parallel/Applicative split) → E10 (hold default)
  → Phase C synthesis; share `ppx_eta.ml`, strictly sequential
- Backlog: E24b hook-ownership; retry cause-alignment; **same-domain
  runtime fence for Channel/Pubsub/Pool** (silent hang → named error);
  dead PPX rejections ×2 (delete candidates); resource/pool escape-fence
  question; `Supervisor.Scope.start` first-contact error; compact `die`
  terminology watch; ~~F1 signal_jsoo~~ **closed 2026-07-19** (`077f763e`);
  F2 `fold ~ok:Fun.id` noise; F3
  `catch_recovery.ml`; F4 `map_par` omission misreading; F5
  `Supervisor.scoped` vocabulary; candidate: `map_par` default-8 bench
- Pending decisions: none — E23b declined (F2 accepted as idiom)
- Last update: 2026-07-19 — F1 + F2 closed

# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **C** (syntax & PPX) — E7 promoted
- In flight: nothing
- **BLOCKED EXTERNAL**: master is red from programme-external merge
  `9e2e3be1` (ladybug read-only classifier — OCaml binding without the
  mock symbol `lbug_prepared_statement_is_read_only`; 8 failures in
  `test/connectors` + `test/ladybug_leak`). Master push withheld; options
  reported to human 2026-07-19. Isolated verification worktree:
  `/tmp/eta-master-gate` (at the E9b merge; identical 8 failures, zero
  from E9b).
- Done (Phase C): **E7 promoted** (`df55d1df`) · **E8 promoted** (`0644da2e`)
  · **E9 held** (branch kept/pushed) · **E9b promoted** (`006c2572`,
  push pending master-green)
- Done (Phase C): **E7 promoted** (`df55d1df`) · **E8 promoted** (merged
  `--no-ff`, master gates green, pushed; worktree removed)
- Done: Phase A (E23/E24/E25) · Phase B (E1/E2/E3-k/E4/E5/E6-k) ·
  **E7 promoted** (`df55d1df`) — `[@@deriving eta_error]`, zero hand-written
  telemetry printers in examples
- Queue: E10 (hold default) → Phase C synthesis (covers E7/E8/E9-hold/E9b/E10); then Phase D
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

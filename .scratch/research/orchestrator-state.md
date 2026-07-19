# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **B complete** — synthesis V-DX-PHASE-B written
- In flight: nothing
- Done: Phase A complete (E23/E24/E25) · Phase B complete — **E1**
  `sync_result` promoted (`sync_option` killed) · **E2** promoted · **E3**
  killed · **E4** promoted (gate fire + rework) · **E5** promoted · **E6**
  helpers killed, recipe promoted — master `123872bc` + bookkeeping
- Queue: **Phase C** — E7 (error-pp deriver) → E8 (`[%eta.result]`) → E9
  (Syntax.Parallel/Applicative) → E10 (hold default); E7/E8/E10 share
  `ppx_eta.ml`, strictly sequential
- Backlog: E24b hook-ownership; retry cause-alignment; **same-domain
  runtime fence for Channel/Pubsub/Pool** (silent hang → named error);
  dead PPX rejections ×2 (delete candidates); resource/pool escape-fence
  question; `Supervisor.Scope.start` first-contact error; compact `die`
  terminology watch; ~~F1 signal_jsoo~~ **closed 2026-07-19** (`077f763e`);
  F2 `fold ~ok:Fun.id` noise; F3
  `catch_recovery.ml`; F4 `map_par` omission misreading; F5
  `Supervisor.scoped` vocabulary; candidate: `map_par` default-8 bench
- Pending decisions: E23b fold-shorthand — awaiting your (a)/(b) pick
  from the grill round (your 👍 anchored on (a) accept; my rec was (b))
- Last update: 2026-07-19 — F1 (signal_jsoo) fixed directly; JS gates now
  use `_build-mainline` (track separation, RPC poisoning solved)

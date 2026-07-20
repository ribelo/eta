# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **C** (syntax & PPX)
- In flight: nothing
- Done (Phase C): E7 promoted (`df55d1df`) · E8 promoted (`0644da2e`) ·
  E9 held (branch kept/pushed) · E9b promoted (`006c2572`) ·
  E10 **held** (`let%eta` killed; `[@@eta.trace]` pre-selected, promote
  trigger defined; branch kept/pushed)
- Done (Phase A): E23 promoted (`66bad437`) · E24 promoted (`29bd23e9`) ·
  E25 promoted
- Done (Phase B): E1 promoted (sync_option killed) · E2 promoted ·
  E3 killed · E4 promoted · E5 promoted · E6 killed (helpers; recipe kept)
- RESOLVED 2026-07-19: ladybug ABI fix `7a16e6fb`; master gates green.
- Queue: **Phase C synthesis** (E7/E8/E9-hold/E9b/E10; orchestrator's own
  work, no executor) → Phase D
- Backlog: E24b hook-ownership; retry cause-alignment; **same-domain
  runtime fence for Channel/Pubsub/Pool** (silent hang → named error);
  dead PPX rejections ×2 (delete candidates); resource/pool escape-fence
  question; `Supervisor.Scope.start` first-contact error; compact `die`
  terminology watch; ~~F1 signal_jsoo~~ **closed 2026-07-19** (`077f763e`);
  F2 `fold ~ok:Fun.id` noise (**closed — accepted as idiom**, E23b
  declined); F3 `catch_recovery.ml`; F4 `map_par` omission misreading; F5
  `Supervisor.scoped` vocabulary; candidate: `map_par` default-8 bench
- Pending decisions: none
- Last update: 2026-07-19 — E10 held; Phase C synthesis next

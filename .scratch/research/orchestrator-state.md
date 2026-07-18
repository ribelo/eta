# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: A (idiom pass)
- In flight: nothing
- Done: **E23 — promoted** (merged `66bad437`, master gates green, pushed;
  worktree removed; branch kept as provenance)
- Queue: **E24** (iteration mirrors `List`; slimmer `Schedule.t`) → E25
  (Phase A, strictly sequential) → Phase B batching per plan
- Open follow-ups: F1 signal_jsoo JS-track bit-rot (pre-existing on
  master); F2 `fold ~ok:Fun.id` noise (watch); F3 `examples/catch_recovery.ml`
  filename (cosmetic)
- Pending decisions: none
- Last update: 2026-07-18 — E23 promoted

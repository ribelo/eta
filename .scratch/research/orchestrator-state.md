# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, the tail of `.scratch/research/dx-journal.md`, and
the dashboard in `.scratch/research/dx-prd-0001.md` §6, then continue the
per-experiment loop (plan §4.2 as amended by Amendment 1).

- Current phase: **D** (runtime & model)
- In flight: nothing
- Done (Phase D): E26 promoted (`dfe5f904`) · E19 promoted (`42d6a4d2`,
  flagship) · E20 promoted (`6deb7694`, as E20b) · **E12 promoted**
  (`dbd51ff6`; API only — manifest role killed, evidence kept for E17)
- Done (Phase D): E26 promoted (`dfe5f904`) · E19 promoted (`42d6a4d2`,
  flagship) · **E20 promoted** (`6deb7694`, as E20b `Keep|Drop|Replace`;
  E20 option-repr held → redesigned on evidence)
- Done (Phase D): E26 promoted (`dfe5f904`) · E19 promoted (`42d6a4d2`,
  flagship) · **E20 promoted** (`6deb7694`, as E20b `Keep|Drop|Replace`;
  E20 option-repr held → redesigned on evidence)
- Done (Phase D): E26 promoted (`dfe5f904`) — `Effect.fresh`/`fresh_named`
- Done (Phase A): E23 promoted (`66bad437`) · E24 promoted (`29bd23e9`) ·
  E25 promoted
- Done (Phase B): E1 promoted (sync_option killed, then **promoted by
  human authority** V-DX-E1-003/004) · E2 promoted · E3 killed ·
  E4 promoted · E5 promoted · E6 killed (helpers; recipe kept)
- Done (Phase C): E7 promoted (`df55d1df`) · E8 promoted (`0644da2e`) ·
  E9 held (branch kept/pushed) · E9b promoted (`006c2572`) ·
  E10 **held** (`let%eta` killed; `[@@eta.trace]` pre-selected, promote
  trigger defined; branch kept/pushed)
- RESOLVED 2026-07-19: ladybug ABI fix `7a16e6fb`; master gates green.
- Queue: **Phase D** — **E11** (Eta_test.run) → E13 (async) → E14
  (Promise, hold-gated)
- Backlog: E24b hook-ownership (context complete after E19/E20); retry
  cause-alignment; **same-domain runtime fence for Channel/Pubsub/Pool**
  (silent hang → named error); dead PPX rejections ×2 (delete candidates);
  resource/pool escape-fence question; `Supervisor.Scope.start`
  first-contact error; compact `die` terminology watch; ~~F1
  signal_jsoo~~ **closed 2026-07-19** (`077f763e`); F2 `fold ~ok:Fun.id`
  (**closed — accepted as idiom**, E23b declined); F3
  `catch_recovery.ml`; F4 `map_par` omission misreading; F5 span-status
  typed-vs-defect encoding (otel/E4-adjacent); `map_par` default-8 bench;
  `[@@eta.trace]` promote trigger; `[%eta.option]` stays excluded
  (substrate exists again, frequency rule still gates); E9 split →
  parking lot (superseded by E9b); F6 `fresh` cold-read scope assumption
  (watch); F7 scoped-stage active cost ~10.5 words/record (allocation-free
  lookup?; benefits ALL scoped stages)
- Pending decisions: none
- OPS RULE: all master merges in isolated temp worktrees, never the main
  checkout (V-DX-E12-002a — the print-then-chain guard failed twice)
- RESOLVED 2026-07-21: erg-v1-ocaml54 integrated to master (`91441653`,
  26 linear commits, gates verified green, pushed)
- Last update: 2026-07-21 — E12 promoted (two-part decision)

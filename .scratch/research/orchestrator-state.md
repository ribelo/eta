# Orchestrator state — DX-PRD-0001

Updated at every transition. Resume protocol for any future orchestrator
session: read this file, **`docs/research/dx-ledger.md`** (the programme
map: what / rationale / decision / decision rationale), the tail of
`.scratch/research/dx-journal.md`, and the dashboard in
`.scratch/research/dx-prd-0001.md` §6, then continue the per-experiment
loop (plan §4.2 as amended by Amendment 1).

- Current phase: **D** (runtime & model)
- In flight: **E39 — E12 audit-slim race** (remove vs. slim)
  - Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e39`
  - Branch: `research/dx-e39-audit-slim-race`
  - Stage: endpoints S+R verified; review demanded changes — S' (R + describe) registered (V-DX-E39-002); followup-1.md written; awaiting executor rework
- Done (recent): **E38 promoted** (`Fail { error; rendered }`;
  render-at-capture design; two rework rounds)
- Done (recent): **E37 promoted** (`acquire_all_par`; transactional
  staging; mechanism cleared first-pass, evidence repaired in one round)
- Done (recent): **E36 promoted** (fail-fast `with_background` +
  `with_supervised_background`; two deep review rounds)
- Done (recent): **E35 promoted** (stack safety established: 1M under
  documented defaults; no interpreter rewrite)
- Wave: **EOP-audit hardening wave registered** (V-DX-EOP-AUDIT) —
  E35 → E36 → E37 → E38 → E39 → E40 → E42a → E41 → E42b → E44 → E21 →
  E33 → E18 → E43 → end items → `Effect.t`→`Eta.t` final replacement
- Done (recent): **E16 KILLED — no-`R` boundary now rests on evidence**
  (value-passing 4-0-1; breaking condition documented: deep graphs,
  ~6+ deps across layers)
- Done (recent): **E32 complete — verdict holds, `recover` stays
  deleted, F2 closed** (naming gate failed by two independent reviews)
- Done (recent): **E31 complete — E10 KILLED** (trigger unfired, cohort
  NO-FIRE; evidence record merged)
- Done (recent): **E29 promoted** (`par3`/`par4`; review verdict promote,
  one mechanical rework round)
- Done (recent): **E28 promoted** (`2edda44b`, unified admission;
  one rework round after review)
- Done (recent): **E30 promoted** (`7d0f462e`, three review rounds;
  both gate tracks green on master)
- Done (queued candidates): **E27 promoted** (`logf`; format4 pitch
  rejected on evidence → closure API; deferral complete + measured)
- Done (Phase E, cont.): **E15 promoted** (`interruptible`; kill →
  kill-rejected → 4 review rounds → shipped; deepest experiment yet)
- Done (Phase E, cont.): **E24d promoted** (retry aligned to the shared
  catchability boundary; divergence proven accidental; prediction sweep)
- Done (Phase E, cont.): **E24c promoted** (hook channel deleted:
  `Schedule.t` 3→2 params, engine rewritten law-preserving, 8 operations
  retyped; Phase A's slimming question CLOSED by implementation)
- Done (Phase E): E22 promoted · **E24b promoted** (hook ownership decided:
  A correct interim model, **deletion proposed** — E24c registered;
  verdict flipped twice on evidence)
- Done (Phase E): **E22 promoted** (law-property policy; 3 oracle rounds,
  10 findings closed; 63 properties, 5 census-complete modules)
- Done: **Phases A–D complete.** Phase D synthesis V-DX-PHASE-D landed
  (`e510aa3a`): 7 promotes, kills honored (E12 manifest, E11
  finalizer_events, E20 option-repr), five durable laws.
- Done (Phase D, cont.): **E13 promoted** (`async`; correctness-reviewed,
  jsoo retention leak found + fixed pre-merge; oracle-closed)
- Done (Phase D): E26 promoted (`dfe5f904`) · E19 promoted (`42d6a4d2`,
  flagship) · E20 promoted (`6deb7694`, as E20b) · E12 promoted
  (`dbd51ff6`) · **E11 promoted** (`41f9eac9`; finalizer_events killed
  per zero-cost gate)
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
- Queue: E21 → E17 (gated) → E18 → end items. Proposed (undecided): E33.
  hold-gated)
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
  lookup?; benefits ALL scoped stages); F8 golden failure output should
  cite user-code location (E11 "where" rated 3)
- Pending decisions: none
- OPS RULE: ALL master writes (commits, merges, bookkeeping) in dedicated
  temp worktrees; main checkout is READ-ONLY for the orchestrator
  (V-DX-E11-001a — third violation; subsumes V-DX-E12-002a)
- OPS RULE 2: agent_spawn worktree isolation bases on the CHECKOUT's
  current HEAD, not master — when the checkout sits on a foreign branch,
  spawned agents inherit stale state (E19b retro rework needed a re-port).
  Verify the base before spawning, or re-base the agent's work.
- RESOLVED 2026-07-21: erg-v1-ocaml54 integrated to master (`91441653`,
  26 linear commits, gates verified green, pushed)
- OPS RULE 3 (staging order): after pushing bookkeeping from a temp
  worktree, integrate/ff LOCAL master to origin/master BEFORE cutting the
  experiment branch, and verify the branch base contains the predictions
  commit (E30 staging cut twice from stale/diverged local master; foreign
  schema commit needed temp-worktree merge `5ce0aa6e`)
- STANDING RULE (V-DX-PRINC-1, human 2026-07-25): Eta is consumed
  primarily by EXTERNAL consumers. In-repo unusedness is not evidence of
  unnecessity. Every objective.md carries the consumption-model block;
  frequency gates apply only absent a structural need.
- 2026-07-26: independent envless verdict ADOPTED
  (.scratch/research/envless-verdict-2026-07-26.md). User-facing docs
  updated (zio-boundaries, services, README); E17 note + E34/DAG
  backlog registered in the ledger; falsification conditions (verdict
  §7) are the standing R-reopen criteria.
- Last update: 2026-07-28 — E40 launched

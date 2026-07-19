# Human spot-check packet 0001 — Phases A & B

Assembled at Phase C start per the Phase B grill (Q3). Every promote/kill
below rests partly on `[agent-sim]` evidence (oracle reviews, persona
cohorts) and is flagged `SC` in the dashboard. This packet is your
~30-minute pass over them. For each: what was decided, what the agent-sim
evidence claimed, where the artifacts live, and what to eyeball if you want
to challenge it. Mechanical evidence (gates, probes, censuses) is not
flagged — only the taste-bearing parts.

How to read: picks are ordered by "most worth your eye" first. If you
overturn one, say so — reversal is cheapest now, and the journal records
evidence, not sentiment (R3).

---

## 1. E24 — `map_par` default cap 8 documented as contract · low controversy

- **Claim:** omission = 8 (today's hidden `min n 8`) is the honest default;
  the mli sentence carries the weight since the call site can't.
- **Agent-sim evidence:** review cohort rated `map_par` 5 vs
  `for_each_par_bounded` 3; the same review guessed omission = *unbounded*
  — the misreading the docs now counter (watch item F4).
- **Eyeball:** `lib/eta/effect.mli` `map_par` doc block; ask yourself
  whether "the default is 8" would stop *you* mid-PR.
- **Artifacts:** V-DX-E24-001..004; `.scratch/research/dx/e24/`.

## 2. E23 — error channel mirrors `Result` · the programme's foundation

- **Claim:** `bind_error`/`fold`/`to_*` beat `catch`/`recover`/bare nouns;
  the old API's invited bug died by construction.
- **Agent-sim evidence:** new naming 4,4,4 vs old 3,3,**1**; cold read of
  `catch` produced "strongly suggests `try...with`" — the invited bug on
  demand. `to_result`/`to_exit` distinction read correctly from names
  alone.
- **Eyeball:** the review pairs at
  `.scratch/research/dx/e23/review/` (w1-old vs w1-new is the whole
  argument in 16 lines).
- **Artifacts:** V-DX-E23-001..002.

## 3. E2 — `ignore` split into `discard`/`ignore_errors` · footgun deletion

- **Claim:** old `Effect.ignore` (discards value AND suppresses typed
  failures) was the most misleading name in the surface; the split forces
  intent.
- **Agent-sim evidence:** old `ignore` rated **1**; split rated 5.
- **Eyeball:** any migrated call site where `ignore_errors` now appears —
  does the explicitness read as noise or as honesty?
- **Artifacts:** V-DX-E2-001..002; branch `research/dx-e1e2e3-hygiene`.

## 4. E6 — `Scoped.with_2`/`with_3` helpers **killed** · your protocol kills

- **Claim:** labelled-boilerplate helpers rated worse than the nested-`let@`
  ladder they were meant to replace (cohort 3,3,3 vs ladder 5,5,4); the
  recipe alone promoted. Standing criterion registered: helper names must
  carry execution strategy, not just cardinality.
- **Eyeball:** if you ever wanted `with_2` to exist, this is the one to
  challenge — the kill rests on one cohort's ratings.
- **Artifacts:** V-DX-E6-001..002; `.scratch/research/dx/e6/`.

## 5. E4 — `pp_compact` kill gate fired, then rework passed · trust the loop?

- **Claim:** first notation lost the finalizer role label (board fired the
  pre-registered kill on 2 of 6 cases); one bounded rework
  (`p | suppressed: finalizer(f)`) passed a double re-review (continuity
  board + cold reviewer).
- **Eyeball:** the before/after corpus renderings in
  `.scratch/research/dx/e4/` — is the final notation readable at 3am?
- **Artifacts:** V-DX-E4-001..002.

## 6. E1 — `sync_result` promoted, `sync_option` killed · both directions

- **Promote:** `sync_result` survived a provisional kill-gate fire — full
  cohort (3 passes) showed 0/3 wrong exception-routings; protocol upgraded
  (gates evaluate only on complete cohorts).
- **Kill:** `sync_option` had zero usage evidence (`from_option` ×7
  repo-wide, sync+option leaf ×0) — symmetry furniture, removed on master.
- **Eyeball:** `Effect.sync_result` mli doc (exceptions-stay-defects
  sentence) — the thing that saved it.
- **Artifacts:** V-DX-E1-001..002.

## 7. E3 — `race_either` **killed** · named tags beat positional

- **Claim:** domain-tagged variants (`` `Timeout ``/`` `Done ``) rated 5
  vs `` `Left ``/`` `Right `` 4; pre-registered gate fired.
- **Eyeball:** quick one — the two call sites in the evidence bundle
  (`.scratch/research/dx/e3/`).
- **Artifacts:** V-DX-E3-001..002.

## 8. E25 — family consistency (`with_scope`, `named ?kind`, `now_ms`,
  `error_pp`) · lowest controversy

- **Claim:** one name per verb family; Format-culture `error_pp` socket
  (which E7 now builds on).
- **Artifacts:** V-DX-E25-001..002; branch `research/dx-e25-family-consistency`.

## 9. E5 — type-error translation page · docs-only promote

- **Claim:** oracle solved 92% without the page, rated it 9/10, passed the
  rank-2 teach-back; negative-compile snapshots now fail CI on message
  drift.
- **Eyeball:** `docs/type-errors.md` — would it have saved you an hour the
  first time you hit a skolem-escape?
- **Artifacts:** V-DX-E5-001..002.

---

## Standing notes

- Review protocol after your "blindness" critique: reviews are framed as
  association-alignment probes against the OCaml/FP prior (fixed P-OCaml
  persona), with orchestrator-sealed predictions as the second independent
  read. Cohort-gates evaluate only on complete cohorts (E1 lesson).
- Kills so far: E1 `sync_option`, E3 `race_either`, E6 helpers — plus the
  E24 `retry_or_else`-absorption reversal and the E24 slimming hold. The
  process is not rubber-stamping.
- Overturn procedure: tell the orchestrator which decision and why; the
  journal gets a correction entry referencing this packet, and the revert
  happens on master with evidence.

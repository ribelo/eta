# Follow-up 1: DX-E29 — three mechanical pre-merge fixes

Verdict from the review: **promote** — the design stands (kill case
weighed and rejected). Three mechanical items to close before merge.
`objective.md` still applies.

## M1 — stale LAWS.md totals

You added rows M119–M122 and 4 properties but left the summary table at
its pre-E29 counts. Correct totals (verified by the review): effect.mli
direct claims 55 → **59**, total covered 108 → **112**, covered registry
rows 236 → **240**, unique properties 69 → **73**.

## M2 — fail-fast properties must enumerate every winner position

The registered fail-fast qcheck properties for par3/par4 generate the
failing position randomly. The repo's exact-branch law policy requires
deterministic coverage of every documented branch: make the properties
enumerate each winner position (par3: 3 cases; par4: 4 cases — e.g., a
list-of-positions driver or separate named cases), so a regression in
position 2/3/4 cannot hide behind a lucky seed.

## M3 — footprint aggregation test must discriminate every child position

The audit/introspection test's names discriminate all children, but the
capability footprint flags don't: a footprint flag dropped from child
position 2 or 3 would pass. Strengthen so distinct footprint-originating
capabilities come from EVERY child position (e.g., clock from child 1,
logs from child 2, metrics from child 3 — and assert the union).

## Protocol

Journal note, implement, re-run native trio + `test/laws`, update report
+ registry, usual signal. Same scope fence. This file stays uncommitted.

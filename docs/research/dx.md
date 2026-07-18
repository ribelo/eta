# Eta DX research — conclusions

Curated, durable conclusions of the DX-PRD-0001 programme
(`.scratch/research/dx-prd-0001.md`). This document exists so that a year
from now anyone can answer "why is the API shaped like this?" without living
memory. Protocol records (predictions, gates, ratings, decisions) live in
`.scratch/research/dx-journal.md`; per-experiment evidence lives on the
`research/dx-e*` branches.

Guiding star: *`Effect` is `Result` with concurrency and spans — `map`/
`map_error` on values, `bind`/`bind_error` on sequences, `fold` on both
channels.* Every conclusion here is judged by whether it moved Eta toward
that sentence.

**Status:** programme started 2026-07-18. Two experiments promoted.

## E24 — Iteration mirrors `List` (promoted 2026-07-18)

`map_par ?max_concurrent f xs` absorbs `for_each_par` and
`for_each_par_bounded` (both deleted): function-first like `List.map` and
`Effect.map`, results in input order, fail-fast, and a **documented default
cap of 8** — what used to be a hidden `min n 8` is now an explicit, tested
contract. `retry`, `retry_or_else`, and `repeat` are labeled and data-last
(`eff |> retry ~schedule ~while_`).

Two findings changed the plan en route, and are the real conclusions:

1. **The proposed signatures were unwritable in OCaml** — trailing optional
   arguments cannot be erased (`map_par ids ~f` would return a partial
   application, not an effect). Caught by the executor with a reproducible
   probe before any code was written; fixed by putting optionals before a
   trailing mandatory argument.
2. **Absorbing `retry_or_else` into `retry` was a misdiagnosis.** Its
   two-error form (`'err1 → 'err2`) is genuine typed-error expressiveness
   that `map_error` cannot recover (the schedule would see the wrong error
   type; the fallback would lose the schedule output). The two operations
   also already differ in cause semantics (`retry`: bare `Cause.Fail` only;
   `retry_or_else`: composite causes) — now documented in the mli as a
   *current limitation*, with alignment deferred to a registered decision.

`Schedule.t` slimming is **held**: `Resource.auto` and `Eta_stream` (×4)
publicly drive hook-bearing schedules, and `Schedule.step_plan` is public —
so hook ownership (policy vs. driver) is an architectural question, not a
rename. Registered as experiment **E24b** with "keep hooks permanently" as
a live outcome.

Evidence: parity suite incl. default-cap-8 proven with 9 inputs;
construction-time `Invalid_argument` red-team; independent review rated the
new shapes 5 and 4 against 3 and 3 for the old. Provenance:
`.scratch/research/dx/e24/`, V-DX-E24-001..004, branch
`research/dx-e24-iteration-mirrors-list`.

## E23 — Error channel mirrors `Result` (promoted 2026-07-18)

The handle cluster now mirrors `Stdlib.Result`: `bind_error` (was `catch`),
`fold ~ok ~error` (replaces `recover` and `or_else_succeed`), and
`to_result` / `to_option` / `to_exit` (were the bare nouns `result` /
`option` / `exit`). `catch_some` and `or_else` kept. Handle cluster: 11 vals
→ 10, 10 concepts → 8.

Why, in one sentence: OCaml already owns this mental model — `Result` has
`map`/`map_error` and `bind`/`bind_error` — so the whole error channel
became teachable as "`Effect` is `Result` with concurrency and spans".

Evidence: blind review (fresh-context reviewer, OCaml-native persona) rated
the new naming 4,4,4 against 3,3,1 for the old, and produced the old API's
invited bug on demand ("`catch` strongly suggests `try ... with`"). The
`to_*` prefix was validated from names alone. Red-team probe: `bind_error`
cannot swallow exceptions — defects surface as `Cause.Die`.

Accepted tradeoff: pure recovery-only sites are noisier (`fold ~ok:Fun.id`
where `recover f` used to do) — flagged by both the executor and the blind
reviewer. Accepted deliberately: one both-channel fold beats two extra
near-duplicate combinators. If usage data shows the pattern is hot, revisit
with evidence (follow-up F2 in the journal).

Provenance: `.scratch/research/dx/e23/` (executor journal, report, red-team,
review packet), journal entries V-DX-E23-001/002, branch
`research/dx-e23-result-error-channel`.

# Follow-up 1: DX-E6 — kill gate fired; excise helpers, keep the recipe

The pre-registered kill gate fired. Independent cohort, three passes,
blinded packet: ladder 5/5/4 (median 5) vs `with_3` 3/3/3 (median 3);
preference to the ladder in 2 of 3 (the third preferred `with_3` for
scanning but still rated it lower). Consistent diagnosis: the name carries
cardinality, not execution strategy — concurrency and release order are
invisible at the call site, while the ladder's semantics are structural.

Per the one-pager: **kill `with_2`/`with_3`, keep the recipe.** `and@` stays
killed on your independent red-team evidence. No rename rescue — a
strategy-carrying name is a different experiment, noted as backlog.

## What to do

1. **Excise the helpers.** Remove `module Scoped` from `lib/eta/effect.ml`
   and `lib/eta/effect.mli`, and delete the 11 helper tests from
   `test/core_common/effect_resource_timeout_common_suites.ml`.
2. **Port the proof to the recipe.** Rewrite 3 of those tests against the
   documented recipe spelling (the `with_scope` + acquire-in-child /
   register-in-owner bridge), naming them for the recipe
   (`test_parallel_acquire_recipe_*`): (a) partial-acquire failure releases
   the registered resource once; (b) reverse release order on success AND
   on typed failure; (c) recipe vs nested-ladder exit parity. They become
   the recipe's regression tests — the evidence outlives the API.
3. **Rework `docs/api-dx.md`.** Remove `Scoped.with_2`/`with_3` references.
   The section becomes: the nested `with_resource` ladder is the default
   (its lifecycle semantics are visible at the call site — no need to cite
   the review, docs state current contract only); when acquisition
   concurrency matters, use the recipe (bridge via `Effect.Expert`), with
   the worked example. Progressive disclosure: ladder first, recipe second,
   no third thing.
4. **Update journal + report.** Record: the kill decision and cohort
   evidence (the 3-pass table), both prediction sets scored (your 65%-better
   prior = miss; your counterprediction about label boilerplate = hit),
   what survives (recipe docs + ported tests + all research artifacts), and
   the generalizable finding for future naming work: *helper names must
   carry execution strategy, not just cardinality* — that sentence is the
   experiment's most valuable output.
5. **Re-run the four gates** (native trio + mainline `test/js_jsoo`).

## What stays untouched

All of `.scratch/research/dx/e6/` — journal, report, red-team, review
packet, INFERRED — it is the kill's evidence bundle and merges with the
branch as provenance.

## Done means

`E6 READY FOR REVIEW` / `E6 BLOCKED: <reason>` / `E6 STOP: <§4.6>`.
The orchestrator verifies the excision is complete (zero `Scoped`
references outside `.scratch`), the ported tests pass, and the docs read
ladder-first. This file stays uncommitted.

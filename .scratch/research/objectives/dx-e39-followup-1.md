# Follow-up 1: DX-E39 — request changes; build the third endpoint (S′ = R + `describe`)

Your dossier went through independent PR-style review. Verdict: **request
changes** — with a better endpoint than either S or R. The review's
reasoning, which the orchestrator adopts:

1. **`collect_names` is where S becomes sentimentality.** Zero non-test
   consumers, 12 storage sites, a field on every `Custom`, `with_names`
   with zero callers — and an inconsistency your dossier did not confront:
   S removed `all`'s name aggregation but kept it in `race`/`par`/`par3`/
   `par4`/`all_settled`, so `collect_names (all [named "a" …])` loses `"a"`
   while sibling combinators keep it. That seam is arbitrary and
   indefensible.
2. **`describe`'s justification is T5, not the consumer map.** The dossier
   overstated the teaching/demand case (no production consumer, no docs
   section, snapshot = self-test, parity proves stability not demand). But
   T5 ("the blueprint is a value — inspectable, printable, auditable") is a
   governing principle, and `describe` is its minimal honest implementation:
   it walks constructors and `leaf_name` only — both of which R keeps.
3. Consumer map missed `bench/effect_construction/construction_sink.ml`'s
   `Effect.describe` call (bench anti-elision; doesn't strengthen S, but
   the map claims exhaustiveness — correct it).

## The third endpoint: S′ = R + `describe`

Starting from the current tip (`82d17297`, R), build S′:

- **Restore `describe`** exactly as master has it: `val describe` in
  `lib/eta/effect.mli` with its contract (opaque `Custom` leaf, `<bind …>`
  unforced), the implementation (walks constructors + `leaf_name` — no
  `names` field, so it must need none), and the snapshot test in
  `test/effect_introspection/`.
- **Keep everything else R**: no `collect_names`, no `Custom.names`, no
  `Expert.make ?names`, no `~names` producers, no `with_names`, two-field
  `Custom`. Do not resurrect any of it.
- **Benchmark sink**: restore `bench/effect_construction/construction_sink.ml`
  to use `Effect.describe` (cross-tree comparability with the BEFORE/S
  measurements).
- **Law registry, third pass**: R's dispositions already removed the
  `collect_names` rows; S′ must restore the `describe`-related rows
  (CD-E22-014's deterministic-snapshot contract and any `describe` row R
  removed) while keeping every `collect_names`/audit/footprint/assertion
  removal. Dispositions must read as one coherent S′ story.
- **Dossier addendum** (`dossier/addendum-sprime.md`): answer the review's
  three findings point by point; correct the consumer map
  (`construction_sink`); record the S′ census (Custom fields 2,
  introspection vals 1 = `describe` only, assertions 0, Expert metadata
  params per your final shape); include the new diff stats
  (`f136a68d..S′` and merge-base..`S′`).
- **Journal**: new `Amendment predictions (sealed)` section committed
  BEFORE the restore code — predicted snapshot parity outcome, predicted
  law-row restorations, predicted census. Do not edit prior entries.

## Proof obligations

- **Snapshot parity, again:** the restored `describe` corpus output must be
  byte-identical to `evidence/describe-master.txt`. Commit the comparison
  as `evidence/snapshot-parity-sprime.txt`.
- **`describe` needs no `names`:** the implementation must compile against
  the two-field `Custom` — this is the proof that the review's core claim
  (representation-free) holds. If it turns out `describe` secretly reads
  `Custom.names`, STOP and report — the endpoint design is wrong.
- **Gates on S′**, same set as before (native trio + mainline JS targets
  with `--build-dir=_build-mainline`), status files under
  `evidence/gates-sprime/`.

## Report

Update `report.md` with an S′ section: what was restored, the parity proof,
law dispositions, gates, amended prediction scores, and your final
recommendation.

## Done means

Same signals: `E39 READY FOR REVIEW` / `E39 BLOCKED: <reason>` /
`E39 STOP: <§4.6 condition>`. Same scope fence as objective.md. This file
stays uncommitted.

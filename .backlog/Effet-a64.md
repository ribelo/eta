---
id: Effet-a64
title: "Research: Json.Number representation (collapse vs Int/Intlit/Float)"
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T20:50:16.093Z
created_by: backlog
updated_at: 2026-05-19T21:09:40.971Z
dependencies:
  - issue_id: Effet-a64
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:09:40.971Z
    created_by: backlog
---

# Research: Json.Number representation (collapse vs Int/Intlit/Float)

## description

packages/effet-schema/effet_schema.ml ships Json.Number of float as the only numeric case. Yojson distinguishes Int / Intlit (bignums) / Float because real-world JSON producers emit values that do not fit OCaml int or IEEE 754 float without precision loss: Snowflake IDs, blockchain amounts, Twitter IDs.

Current Schema.int decoder uses Float.equal n (Float.round n) and int_of_float to recover an int — losing precision above 2^53 silently.

The collapse to float was inherited from m_a_pure_schema_effect_policy.ml's lab fixture without testing real-world numeric inputs. The schema research session never round-tripped a bigint or a value > 2^53 through the package.

Hypothesis to test: Json.t should have a richer numeric variant. Candidates:
- N0 keep Number of float (current); document the precision loss
- N1 Number of [ `Int of int | `Float of float | `Intlit of string ] (Yojson-shaped)
- N2 Number of string (raw JSON token, parse on demand at decoder boundary)
- N3 Number of (int64 option * float) — fast path int64 with float fallback

## design

scratch/json_number_research/ with each candidate as a self-contained module decoding the same fixture set:
- 0
- 1
- -1
- 9007199254740993 (2^53 + 1, first integer not representable as double)
- 18446744073709551615 (uint64 max, > int63 on 64-bit OCaml)
- 1e100
- 0.1 + 0.2 (precision)
- NaN, Infinity (must reject)

For each candidate: implement Schema.int and Schema.int64 and Schema.string_of_number; show what each fixture decodes to; show what Schema.encode round-trips back as.

Compare against Yojson's behaviour as the OCaml-ecosystem reference. If our representation cannot round-trip a value Yojson can, that's evidence the collapse is too aggressive.

Coupled with Effet-tkw audit: the JSON_ADAPTER work (Effet-vtj-equivalent below) needs to know what shape internal Json.t has before the adapter contract can be stable.

## acceptance criteria

scratch/json_number_research/ contains candidates N0..N3 with the fixture set passing or producing documented precision-loss markers. journal.md gains a V-Jnv1..V-JnvN decision diary recording per-candidate behaviour and the recommendation. Recommendation: (a) keep float-only with documented loss; (b) flip to a richer numeric variant — capture as migration task. 2h time budget.

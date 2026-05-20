# effet-schema package backlog

## Epic: `effet-schema` companion package

Description: build a companion package that gives Effet applications the
runtime contract layer that Effect-TS apps get from Schema, without copying the
TypeScript API shape. The package owns pure schema/codec values, structured
decode issues, JSON Schema metadata, examples/equivalence hooks, nominal
validated values as OCaml modules, recursive schemas, tagged unions, and
Effet-shaped decode effects.

Design:

- Follow `scratch/schema_research/STUB_schema.mli`.
- Keep `Schema.t` pure and env-free.
- Put effectful checks at decode boundaries with `decode_with_policy`.
- Prefer module-first OCaml usage: domain modules expose `type t`,
  `val schema`, `val decode`, `val encode`.
- Defer ppx generation until the manual v0 surface is proven.

Acceptance:

- Replays the migration fixture in `migration_smoke.ml`.
- Preserves env-row requirements for effectful policies.
- Nominal validated values cannot be forged as plain strings.
- Accumulates multiple issues for nested records and arrays.
- Supports tagged unions, recursion, transform, JSON Schema, samples, and
  equality hooks.

## First slices

1. Package skeleton and JSON abstraction
   - Create `packages/effet-schema/` without changing `packages/effet/`.
   - Add abstract `json`, `issue`, `error`, and Yojson adapter plan.
   - Acceptance: package builds and exposes only the documented minimal types.

2. Pure schema core
   - Implement primitives, array, option, refine, transform.
   - Acceptance: decode/encode roundtrips and nominal newtype negative tests pass.

3. Product and sum builders
   - Implement `recordN`, `field`, `tagged_union`, and `lazy_`.
   - Acceptance: migrated config/event/menu fixture passes.

4. Effet integration
   - Implement `decode` and `decode_with_policy`.
   - Acceptance: env-row negative test matches the lab failure mode.

5. Derived helpers
   - Add JSON Schema emission, `samples`, and equality hooks.
   - Acceptance: fixture has non-empty JSON Schema docs and equality checks.

6. Developer-experience review
   - Re-evaluate manual `recordN` boilerplate after one real migrated app.
   - Acceptance: decide whether a `ppx_effet_schema` follow-up is justified.

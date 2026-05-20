---
id: Effet-jv3
title: "Survival lab: Schema.json_schema — make it real or remove it"
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T20:56:19.487Z
created_by: backlog
updated_at: 2026-05-19T21:10:47.257Z
dependencies:
  - issue_id: Effet-jv3
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:10:47.257Z
    created_by: backlog
---

# Survival lab: Schema.json_schema — make it real or remove it

## description

packages/effet-schema/effet_schema.ml — Schema.t.json_schema is fabricated in each constructor but:

- lazy_'s schema is {"$ref": "#/recursive"} — not a valid JSON Pointer, doesn't resolve
- transform's schema is {"allOf": [inner], "description": name} — wraps the predecessor without expressing the transformation
- refine's schema is the same allOf wrap — JSON Schema doesn't have refinement; the constraint is lost
- No $schema declaration, no $id, no draft version
- Not loadable by any standard JSON Schema validator

Nothing in the package consumes schema.json_schema. It's exposed via Schema.json_schema but no test asserts the output validates correctly under ajv or jsonschema-py.

Two options:

A) Implement real JSON Schema generation. Choose a draft (Draft 2020-12 likely), add $schema header, resolve $refs through a definition table, encode refinements as 'pattern'/'minimum'/'maximum' where mappable, document where they aren't. This is meaningful work — JSON Schema is its own surface area.

B) Remove json_schema from Schema.t. Move it to a separate Effet_schema_jsonschema module / companion package. Schemas become smaller, the package no longer pretends to do JSON Schema generation.

## design

Survival test using ajv (Node.js JSON Schema validator) or python jsonschema as oracle:

1. Take a representative fixture (record with refined string fields, optional fields, tagged union, array of records).
2. Generate the json_schema output.
3. Submit several JSON values to ajv with that schema; assert which pass and which fail.
4. Verify the validations match what Schema.decode would do for the same inputs.

If most fixtures pass an external validator with output close to what decode does, (A) is feasible. If outputs are unusable (no $schema, broken $refs, lost refinements), (B) is the honest choice.

Tie-breaker: do any current users (downstream packages, OpenAPI generation, documentation tooling) depend on Schema.json_schema? If no, default to (B). If yes, scope (A) as a multi-session implementation task.

## acceptance criteria

scratch/schema_jsonschema_survival/ contains a fixture set, generated outputs, and validation results from an external JSON Schema validator. journal.md gains a V-Jsv decision diary recording per-constructor json_schema behaviour and the chosen direction. Recommendation: (a) implement real JSON Schema generation — capture as multi-session epic; (b) remove json_schema from Schema.t — capture as small migration task. The package stops shipping a placeholder. 2h time budget.

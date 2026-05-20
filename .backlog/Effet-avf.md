---
id: Effet-avf
title: "Survival lab: Schema.samples — implement properly or remove"
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T20:53:34.121Z
created_by: backlog
updated_at: 2026-05-19T21:10:29.168Z
dependencies:
  - issue_id: Effet-avf
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:10:29.168Z
    created_by: backlog
---

# Survival lab: Schema.samples — implement properly or remove

## description

packages/effet-schema/effet_schema.ml — Schema.t.samples is in every schema, but the derivations are placeholders:

- array: samples = [ []; item.samples ] — only 2 elements, mixing empty array with one full sample list
- tagged_union: samples = []
- lazy_: samples = []
- record1..6: defaults to [] if the user doesn't supply
- transform: filters predecessor's samples through decode, often producing []

The README claims schemas 'provide samples', but for half the constructor shapes there's no real derivation — the user has to hand-supply samples on every record. This is a write-only field that exists because Effect-TS Schema has Arbitrary derivation.

Two options:

A) Implement real samples derivation. For array, derive a power-set-like sample from item samples. For tagged_union, gather one sample per case. For lazy_, force the thunk and use its samples. For record, cross-product field samples (capped at N). For transform, apply decode to predecessor samples and keep Ok values.

B) Remove samples from Schema.t entirely. Move it to a separate Effet_schema_arbitrary module that pattern-matches on a public Schema.t structure (requires exposing constructors) or is built per-application by users who want property-test generators.

## design

Survival test: write a representative fixture set (array of records, tagged_union, recursive tree, transform on a refinement). For each constructor:
- record what samples currently produces
- record what a 'reasonable' derivation would produce
- compare cost of (A) full derivation vs (B) removal

If (A): the lab implements derivations for array/tagged_union/lazy_/record/transform, and asserts each produces non-empty representative samples. Cap samples at N elements per layer to avoid exponential blow-up.

If (B): drop samples from Schema.t. Document the migration path: users wanting Arbitrary derivation use qcheck combinators directly, or wait for a future effet-schema-arbitrary companion package.

Tie-breaker: do any current users (test fixture, tests in run.ml, downstream code) actually consume Schema.samples? If no consumers exist, default to (B). If consumers exist, evaluate whether their needs justify (A)'s implementation cost.

## acceptance criteria

scratch/schema_samples_survival/ contains a fixture set and both branches. journal.md gains a V-Sav decision diary recording per-constructor sample behaviour and the chosen direction. Recommendation: (a) implement real samples derivation across all constructors; (b) remove samples from Schema.t and document the alternative. Either way, the package no longer ships a half-implemented field. 2h time budget.

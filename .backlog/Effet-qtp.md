---
id: Effet-qtp
title: "Research: applicative-style record builder vs arity ceiling at record6"
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T21:07:14.617Z
created_by: backlog
updated_at: 2026-05-19T21:12:02.438Z
dependencies:
  - issue_id: Effet-qtp
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:12:02.438Z
    created_by: backlog
---

# Research: applicative-style record builder vs arity ceiling at record6

## description

packages/effet-schema/effet_schema.mli ships record1, record2, ..., record6 — six hand-written builders. The .mli says 'a PPX can later generate these calls'. Two issues:

1. A user with a 7-field record is stuck. There's no record_n / applicative-style chain available. They have to either decompose their record across two schemas or wait for the PPX.

2. The applicative-style alternative was never labbed:
     let* a = field 'a' string in
     let* b = field 'b' int in
     ...
     let* g = field 'g' bool in
     return (make a b c d e f g)
   with a Schema-as-applicative-functor. That's a few extra primitives and avoids the arity ceiling entirely. data-encoding's `obj7..objN` approach works the same way. Effect-TS's Schema.Struct({...}) works because TS objects are polymorphic in arity; OCaml records aren't, but the applicative pattern is the standard escape.

Choosing arity-specific builders without comparing the applicative alternative was an Effect-TS API copy, not an OCaml-native decision.

## design

scratch/record_builder_research/ with three candidates building the same 8-field record schema:

R0 record1..record8: extend the existing pattern by hand. Cost: 8 functions in the .mli, more boilerplate to maintain. No ceiling escape — at record9 the same problem repeats.

R1 applicative-style:
  type ('record, 'partial) builder
  val start : 'record -> ('record, 'record) builder
  val ( +> ) :
    ('record -> 'a) ->
    'a t ->
    string ->
    ('record, 'partial -> 'record) builder ->
    ('record, 'record) builder
  val build :
    name:string ->
    equal:('record -> 'record -> bool) ->
    ('record, 'record) builder ->
    'record t

Test by writing the same 8-field schema with R0, R1, plus a 3-field schema for compactness comparison.

R2 GADT field list:
  type _ fields =
    | [] : record fields  (* terminator *)
    | (::) : ('record, 'a) field * 'a fields -> ('record, 'a -> 'rest) fields

This is heavier to write but gives full type-safe variadic record building.

Compare:
- LOC per call site
- type-error quality on missing/extra/mistyped field
- IDE / merlin support (does hover give useful signatures mid-build?)
- whether a PPX could replace all three uniformly later

## acceptance criteria

scratch/record_builder_research/ contains R0/R1/R2 candidates building the same 8-field test schema. journal.md gains a V-Rbv decision diary. Recommendation: (a) keep record1..record6 ceiling, document escape hatch (split records into nested schemas); (b) extend to record1..record12 to push the ceiling; (c) ship applicative-style builder; (d) ship GADT field-list builder. If a builder is recommended, capture as implementation task. 2h time budget.

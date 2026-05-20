---
id: Effet-ut6
title: Remove Stdlib.( = ) default from Schema.transform's ?equal
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T20:51:36.170Z
created_by: backlog
updated_at: 2026-05-20T19:21:25.000Z
dependencies:
  - issue_id: Effet-ut6
    depends_on_id: Effet-tkw
    type: parent-child
    created_at: 2026-05-19T21:10:03.421Z
    created_by: backlog
---

# Remove Stdlib.( = ) default from Schema.transform's ?equal

## description

packages/effet-schema/effet_schema.ml — Schema.transform exposes ?equal:('a -> 'a -> bool) defaulting to Stdlib.( = ):

  let transform ~name ?(equal = Stdlib.( = )) ~decode ~encode schema = ...

Polymorphic equality is OCaml's textbook footgun:
- raises Invalid_argument 'compare: functional value' on values containing functions
- gives wrong answers on abstract types where representation differs from intent
- behaviour is not stable across OCaml versions for some shapes
- silently compares cyclic/lazy values incorrectly

Defaulting to it means every transformed schema in the codebase silently inherits these hazards. The user has to know to override. The research labs never tested a transform with values containing functions or abstract types — so the default has no evidence behind it.

The fix is to remove the default and force the user to write ~equal explicitly. transform is uncommon enough (compared to record1..6) that the explicitness cost is low.

## design

Change the signature:
  val transform :
    name:string ->
    equal:('a -> 'a -> bool) ->        (* required *)
    decode:('encoded -> ('a, issue list) result) ->
    encode:('a -> 'encoded) ->
    'encoded t ->
    'a t

Update brand to pass ~equal:(Brand.equal schema.equal) (already does this). Update any other in-tree callers to provide ~equal explicitly.

If the migration cost is high (many call sites in tests rely on the default), introduce an explicit Schema.unsafe_polymorphic_equal value users can pass with eyes open, rather than silently defaulting:

  let unsafe_polymorphic_equal a b = Stdlib.( = ) a b

That keeps the escape hatch but makes its usage visible in grep.

## acceptance criteria

Schema.transform's ?equal becomes a required ~equal: argument. No call site in packages/effet-schema/ relies on the implicit Stdlib.( = ) default. If Schema.unsafe_polymorphic_equal escape hatch is added, it is documented as 'use at your own risk' and exists only for the cases where the user knowingly accepts the hazard. Existing tests pass after explicit ~equal is added at the call sites that previously relied on the default.

## resolution

`Schema.transform` now requires `~equal`; no escape hatch was needed for
in-tree callers. Package implementation/interface search has no remaining
`Stdlib.( = )` default.

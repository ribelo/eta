# Registered contracts and guidance

## Public contract (`lib/eta/effect.mli:210-229`)

```ocaml
val all : ('a, 'err) t list -> ('a list, 'err) t
(** Run every prebuilt effect concurrently, collecting results in input order.
    Every child is admitted immediately, so admission cannot deadlock a
    coordination group by withholding one of its children.

    Fail-fast: the first child failure cancels its siblings; the cause of the
    first observed failure propagates. *)

val all_bounded : max_concurrent:int -> ('a, 'err) t list -> ('a list, 'err) t
(** Run prebuilt effects with at most [max_concurrent] children admitted at
    once, collecting results in input order. Fail-fast like {!all}.
    A bound smaller than a coordination group can stall when every admitted
    child waits for work from a child that has not been admitted.

    @raise Invalid_argument if [max_concurrent <= 0]. *)

val all_settled :
  ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
(** Run every effect concurrently and collect every child outcome in input order.
    Failures become [Error cause] values; every child is admitted as in {!all}. *)
```

## When to choose `all_bounded`

`docs/api-dx.md:80-84` gives the review rule:

> Reach for `all_bounded` only when the children are independent of unadmitted
> siblings and the caller owns a concrete resource or load limit. A bound smaller
> than a coordination group can stall when every admitted child waits for an
> unadmitted sibling; use `all` for barriers and coordinator shapes because it
> admits every prebuilt child immediately.

The task-shape table distinguishes all three choices:

| Task shape | Form | Admission |
| --- | --- | --- |
| Prebuilt effects; every child must start | `Effect.all effects` | Every child |
| Independent prebuilt effects; concrete cap required | `Effect.all_bounded ~max_concurrent effects` | Required positive bound |
| Function plus collection | `Effect.map_par f inputs` | Default eight |

`map_par` is unchanged. No `all_settled_bounded` was added because no structural
need surfaced.

## Surface deltas

- Concurrency cluster: **+1 val** (`all_bounded`).
- `all`: optional `?max_concurrent` removed.
- `all_settled`: signature unchanged; admission documentation aligned.
- Footguns: **-1/+0**. Hidden-eight liveness disappears; bounded coordination
  remains a named, required-argument caveat.

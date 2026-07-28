# Registered contracts and guidance

## Public contract (`lib/eta/effect.mli:210-229`)

```ocaml
val all : ('a, 'err) t list -> ('a list, 'err) t
(** Run every prebuilt effect concurrently, collecting results in input order.
    [all] forks one fiber per input and registers every child fiber before any
    child body starts, so no coordination child can be withheld by admission.
    Fail-fast: the first child failure cancels siblings and propagates its cause.
    Reserve [all] for finite groups requiring full admission; use {!all_bounded} for large or
    data-derived independent prebuilt effects and {!map_par} for lazy mapping. *)

val all_bounded : max_concurrent:int -> ('a, 'err) t list -> ('a list, 'err) t
(** Run prebuilt effects with at most [max_concurrent] children admitted at
    once, collecting results in input order. Fail-fast like {!all}.
    A bound smaller than a coordination group can stall when every admitted
    child waits for work from a child that has not been admitted.

    @raise Invalid_argument if [max_concurrent <= 0]. *)

val all_settled :
  ('a, 'err) t list -> (('a, 'err Cause.t) result list, 'outer_err) t
(** Collect every child outcome in input order; failures become [Error cause].
    As in {!all}, every child fiber is registered before any child body starts. *)
```

## When to choose `all_bounded`

`docs/api-dx.md:63-89` gives the review rule:

> `Effect.all` is for a finite group requiring full admission and forks one fiber
> per input. Use `all_bounded` for a large or data-derived group of independent
> prebuilt effects, and `map_par` when lazily mapping. Full admission is not
> scheduler preemption: a body that never yields can still prevent sibling bodies
> from running on a single-domain backend.

The task-shape table distinguishes all three choices:

| Task shape | Form | Admission |
| --- | --- | --- |
| Finite prebuilt group requiring full admission | `Effect.all effects` | One fiber per input; all registered before bodies start |
| Large/data-derived independent prebuilt group | `Effect.all_bounded ~max_concurrent effects` | Required positive bound |
| Lazy function mapping over a collection | `Effect.map_par f inputs` | Default eight |

`map_par` is unchanged. No `all_settled_bounded` was added because no structural
need surfaced.

## Surface deltas

- Concurrency cluster: **+1 val** (`all_bounded`).
- `all`: optional `?max_concurrent` removed.
- `all_settled`: signature unchanged; admission documentation aligned.
- Footguns: **-1/+1**. Hidden-eight liveness disappears; unbounded `all` adds a
  visible fan-out risk because 10,000 inputs fork approximately 10,000 fibers.
  Bounded coordination remains a named, required-argument caveat.

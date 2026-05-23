# Borrow API Freeze

## Scope

This note freezes G5/G6 for Eta-t59. It does not reopen the local-unique borrow
API and does not reopen portable Effect.t.

## Compile-Fail Fixtures

### Direct local-unique connection

Fixture: scratch/eta_research/pool_survival/oxcaml_conn_unique_negative.ml

Relevant shape:

    type conn = { id : int }
    type t = { mutable slot : conn option }

    let with_connection (pool : t)
        (f : conn @ local unique -> (unit, [> `No_conn ]) eff) =
      match pool.slot with
      | Some conn -> f conn
      | None -> Fail `No_conn

Why it fails: a connection read from aliased pool storage is not unique. The
compiler is right to reject handing it to a callback as local unique.

### Local borrow captured by lazy Effect.t

Fixture: scratch/eta_research/pool_survival/oxcaml_borrow_effect_capture_negative.ml

Relevant shape:

    type borrow

    val with_borrow :
      t -> (borrow @ local unique -> ('a, 'err) Effect.t) -> ('a, 'err) Effect.t

    let bad_capture pool =
      Pool.with_connection pool (fun borrow ->
          Effect.named "captures-local-borrow"
            (Effect.sync (fun () -> Pool.id borrow)))

Why it fails: Effect.sync stores a closure in Effect.t, and that closure must be
global. Effect.named owns instrumentation around that leaf; it does not change
the closure's mode. Capturing a local borrow into Effect.sync would let the
local value escape.

## Frozen Decision

Eta-t59 must use the conservative callback API from V-Pool-Choice:

    with_resource :
      pool ->
      (conn -> (a, err) Effect.t) ->
      (a, err) Effect.t

Do not expose:

- conn @ local unique callbacks
- abstract local borrow handles in the public Pool API
- a portable/cross-domain Pool promise

The Pool is same-domain v1 and stores ordinary Eio-shaped connection values.

## Reopen Criteria From V-Pool-Survival-3

Reopen local/unique borrow only with new evidence, specifically one of:

- Eta gains a local-aware effect representation that can store a computation
  using a local borrow without letting it escape.
- Eta adds a synchronous borrow callback API that still expresses real network
  operations needed by eta-http or eta-sql.
- A shipped consumer demonstrates a measurable bug or performance ceiling that
  the conservative callback API cannot address.

Compiler curiosity is not enough.

## V-Island-Impl Candidate C Cross-Link

The same family of evidence would reopen the deferred portable/local-aware
Effect.t design sometimes described as V-Island-Impl candidate C:

- a real cross-domain or island use case requires carrying effect descriptions,
  not just immutable callback input/output
- the mode annotations can be expressed without making ordinary same-domain Eta
  code worse
- negative fixtures for capturing runtime state, Eio handles, loggers, meters,
  tracers, and raw causes remain rejected

Until those conditions hold, Eta's shipped runtime model remains:

- same-domain Eio runtime for Effect.t
- Eta.Island for finite portable CPU callbacks
- Effect.Blocking for legacy blocking IO

## Future Evidence Checklist

Before reopening, answer yes to all of these:

- Is there a named shipped consumer, not only a scratch hypothesis?
- Does the consumer require effectful work while holding the borrow?
- Can the proposed API prevent the borrow from escaping through Effect.t?
- Does the proposal keep Eio handles out of portable/cross-domain storage?
- Do the existing negative fixtures still fail for the right reasons?
- Is the benefit larger than the extra mode burden on ordinary Pool users?

If any answer is no, keep the freeze.

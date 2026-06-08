# P5 Multi-Binder Callback Shape

Question: should downstream `with_*` functions take a single binder so `let@ x = with_thing in` always applies?

## Fixtures Considered

| Surface | Natural callback values | Single-binder shape | Impact |
| --- | --- | --- | --- |
| Consumer `with_record_stream` | `info`, `recv` | `{ info; recv }` stream record | Recommended. The pair has a domain name and travels through PTT loop code as one stream capability. |
| Existing `Pool.with_resource` | `conn` | `conn` | Already single binder. No change. |
| Hypothetical `with_request` | request, response writer | `{ request; respond }` only if that bundle is a real session/request context | Conditional. Record packing is good when it names an owned protocol, bad when it hides unrelated values. |

## Search Evidence

Current Eta core surfaces requiring no change:

- `Pool.with_resource : pool -> (conn -> effect) -> effect` is single-binder.
- `Effect.with_background : background -> (unit -> effect) -> effect` is unit-binder.
- `Semaphore.with_permits : sem -> int -> (unit -> effect) -> effect` is unit-binder.

No existing `lib/eta` public `with_*` resource function has a multi-argument callback. Therefore the convention forces 0 cascading API changes inside `lib/`, below the objective pause threshold of >5.

## Verdict

Recommend, but do not make it a mechanical law: downstream Eta-owned `with_*` functions should expose one callback binder. Use a record when the callback receives multiple fields that form one resource/session concept. Do not allocate a record just to satisfy `let@` when the values are unrelated or hot-path allocation is known to matter.

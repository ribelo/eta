# Record Builder Research

Backlog: Effet-qtp.

Fixture: an 8-field record schema, beyond the current `record6` ceiling.

| Candidate | Shape | Call-site cost | Type-error quality | Recommendation |
|---|---|---|---|---|
| R0 `record1..record8` | extend current arity functions | familiar but grows linearly | good, direct field positions | reject as default; ceiling repeats at 9 |
| R1 applicative builder | accumulate fields, then `build` | more API to learn | depends on builder encoding | research further before shipping |
| R2 GADT field list | typed heterogeneous field list | heaviest call site | best invariant potential, worse errors | too heavy for v0 |

Decision:

- Do not add a new builder in this pass. The shipped API keeps `record1..record6`.
- Record the arity ceiling as a known limit in docs/journal.
- Prefer a future applicative builder only after a compiled prototype proves that
  Merlin hovers and type errors are acceptable.

Why not implement now:

- `Schema.t` just lost placeholder metadata fields; adding a new builder surface
  in the same pass would mix cleanup with a new API.
- The right builder has user-experience risk, not runtime risk. It needs a
  focused prototype with negative compile fixtures.

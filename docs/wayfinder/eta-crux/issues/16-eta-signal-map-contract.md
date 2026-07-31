# eta_signal_map and minimal eta_signal hook contract

Type: grilling
Status: open
Blocked by: 01

## Question

In scope as a **contract only**: pin what eta_crux needs from the keyed-collection substrate
and from the graph engine. Redesigning or implementing either package is a separate effort.

Open:

- The exact `eta_signal` hook that `eta_signal_map` requires for efficient keyed diffing and
  stable per-key scopes, without opening a broad expert surface.
- The comparator and key-module discipline for `eta_signal_map`.
- Whether timer wake is exposed as a next deadline, a condition signal, or both.

Also settle a requirements-ownership problem surfaced while fixing duplicate IDs:
`engine-strategy.md` states obligations on `eta_signal_map` and on `eta_signal` from inside
the eta_crux bundle, and those obligations would be verified by those packages' own test
suites. Decide whether they move to their own requirement note.

Under plain-state V1 this constrains only the later graph backend, so it is off V1's
implementation critical path.

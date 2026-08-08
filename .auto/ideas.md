# Eta Signal dynamic-switch wall time ideas

## Wall-time work

- Profile `eta_signal.dynamic.switch` with `perf` (release symbols) and compare
  against Incremental's bind path. The allocation session removed ~70% of the
  per-switch heap cost; wall time may now be dominated by scheduling, scope
  invalidation, or the deferral protocol rather than allocation.
- Measure dynamic wall at several operation counts to separate fixed pass
  overhead from per-switch cost.
- Inspect Incremental `Bind_lhs_change` for the measured operation.
- Guard measured leaf helpers with `[@zero_alloc]` only after the profile shows
  a specific allocation or branch dominating.

## Retained allocation findings (dynamic switch)

- 273 -> 130 words; dynamic wall 737 -> 563 ns.
- Leaf fast paths, stack-allocated pass closures, hoisted recursive walks,
  in-place dependency replacement, leaf-inner listener skip, node bool
  bitfield.
- Successful passes without checkpoints skip full queue scans; timer-free
  graphs bypass timer discovery; zero/one observer bypasses sorting.

## Remaining measured allocation sites (130 words)

- Node record (21) + signal record (5) = 26 (fresh inner const per switch).
- Rollback capsule closure + record (14) - existential refs cap variant gains
  at ~3 words; not worth the protocol change.
- Ancestry List.filter (6) - bounded-growth requirement blocks allocation-free
  redesign without a children-index structure.
- enqueue_stale_freshness Hashtbl closure (6) - would need an array iteration
  registry parallel to bind_evaluations.
- Scope record (3) + ancestry tuple+cons pushes (12).
- Escaping const compute/initializer closures (11), Post_commit event/cursor
  data (12), bind Null-branch closure (3).

## Dynamic-switch wall progress (runs 49-54)

- 557.7 -> 345.3 ns (-38.1%); words 273 -> 120.
- Handle-record structural equality -> int-field same_handle (caml_equal gone).
- Typed high-water compares in enqueue; lazy Eio worker-context probe.
- Observer fields + bind selected -> or_null (immediate-payload options done).
- Initializer list stores packed nodes with shared enqueue helper.
- Eager evaluate of dependency-free bind inners removes the deferred retry and
  the second compute per switch.

## Deferred cutoff allocation result

- A private sealed plan `Empty | One observer | Many list` removes exactly three
  words from every one-observer pass (cutoff 5 -> 2, changed 21 -> 18, dynamic
  100 -> 97), but cutoff wall regressed 67.25 -> 69.18 ns. Revisit only if the
  primary changes back to allocation; the existing list plan is faster.

# Eta Signal Map performance ideas

## Highest-confidence work

- Track fixed duplicate-dependency nodes during graph construction. Iterate that
  registry during stale-freshness repair instead of scanning every graph slot.
  Include bind nodes because their dependency arrays can change.
- Remove the successful-pass `clear_queues` full slot scan. Queue pop clears
  `queue_next` and `in_queue`. Keep the full cleanup on rollback. If another
  path can leave residue, track only the touched queue nodes.
- After both scans are gone, use `perf` on data, membership, and child changes at
  100,000 keys. Do not guess at the next bottleneck.

## Likely follow-up work

- Avoid `Hashtbl.create` in stale-freshness repair for empty candidate
  registries.
- Replace stale registry entries after slot generations change. Do not let a
  long-lived graph accumulate stale handles.
- Check whether `enqueue_all_uninitialized_necessary` performs another full scan
  after a repaired stale node. Track uninitialized necessary nodes only after a
  profile shows that this path is hot.
- Profile the first propagation pass after the graph-wide scans are removed.
  Look for observer delivery, output-map equality, or child-wrapper overhead.
- Check whether each stable-family child needs the extra `Graph.map` wrapper
  that counts child visits. A deeper propagation operation can count visits
  without one node per key, but it must preserve diagnostics.
- Check whether the keyed owner needs a second balanced child tree. The input
  map already supplies stable key identity and shared ancestry. Any
  replacement must preserve rollback and generation-safe child lookup.
- Specialize output patching so one child change performs one map update and no
  generic option wrapping.

## Map-kernel work after graph work

- Profile `fold_symmetric_diff_with` after stabilization becomes affected-only.
  Keep its shared-ancestry complexity law.
- Consider a cursor representation that reuses traversal storage. If it
  increases comparisons or allocation on one-key shared edits, reject it.
- Inspect weight-balanced-tree rotations and output patch allocation only after
  profiles show that map operations dominate.

## Historical knowledge

- The previous execution engine reached single-digit microseconds for a
  10,000-key child change after it removed global timer, observer, invalidation,
  and dependency-snapshot work. This is evidence that affected-only execution
  is possible. The old engine is not a source-compatible fallback.
- The current promoted execution model reintroduced a full duplicate-dependency
  scan and a full queue cleanup scan. A 100,000-key child-change profile assigns
  about 55% of CPU samples to these two scans.
- `/home/ribelo/projects/ribelo/ocaml/Eta/.auto` contains H2-over-TLS research,
  not Signal Map research.

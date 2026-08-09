# Eta Signal wall-ratio geomean ideas

## Landed architecture wins (runs 94-96)

- Removed the redundant `Running` cursor state; the delivery token guard alone
  is authoritative (words 19 -> 16).
- Per-pass evaluation freshness moved from three per-node closure refs plus a
  `compute_invalidators` Hashtbl and a per-node `Weak` array into one kernel
  node field (`computed_in`) with an opt-in `pass_memoized` flag. Keyed
  incarnations and bind owners under retry legitimately publish twice per pass,
  so they stay unmemoized.
- Default cutoff named as a kernel variant (`Physical_cutoff`), so physical
  suppression inlines to one pointer compare instead of `caml_apply2` through a
  closure field. `or_null` is unboxed, so this is exactly `old == next`.

## Open wall-time targets

- **Delivery ceremony (~25% of changed_1).** Each `Post_commit` entry point
  wraps its body in `claim owner @@ stack_ (fun () -> ...)`, so one delivery
  pays several phase claims and closure frames. The Graph's own observer
  callback calls `Edges.current` from inside the driver walk, where the cursor
  is provably Pending with the matching token, so a direct immutable event read
  needs no claim. `run_edge_plan_sync_inner` (13.1%) and the delivery `with_phase`
  body (4.0%) still rebuild ref state per pass.
- **Per-node closure chain.** `evaluate_from` calls a null-guard closure
  (graph.ml:521) that calls each API's compute closure (map at 606). Fusing the
  guard into one closure per API entry removes one indirect call per node.
- **Fixed pass ceremony.** `run_stabilization` (12% of cutoff) plus the Graph
  stabilize wrapper (9%) run ~8 no-op calls for a graph without timers, binds,
  or duplicate dependencies: `enqueue_uninitialized_necessary`,
  `unlink_queued_descendants`, `account_recomputations`, `reconcile_timer_demands`.
- **Slot resolution chase.** Every pop/resolve loads `graph.slots.(slot)` -> slot
  record -> `strong : packed option` -> node. Making `strong` a `packed or_null`
  removes one dependent load everywhere and a 2-word `Some` per install
  (34 sites in propagation.ml, all private).

## Rejected with evidence

- **Admission ledger as the first drain wave** (runs 97, 98). Correct after two
  ordering fixes (consume the ledger after the priority queue; sources admitted
  during a running pass keep their queue insertion). Changed rows gained 3-5%,
  but dynamic regressed 18.7% from drain-loop code layout. Patch:
  /tmp/admission-wave.patch.
- **In-place cursor retagging.** `Obj.set_tag` does not exist in OxCaml 5.2 and
  `caml_obj_set_tag` is not in the runtime; `Obj.with_tag` copies the block, so
  it cannot beat the current allocation.
- **Flat cursor variants.** Nested cursors share the event block with the
  delivery record (14 words); flat `Pending_changed (token, old, new)` variants
  duplicate it (15-16 words). Strictly worse.
- **Packed-node admissions** (run 88) and **delivery-plan memoization** (run 90).
- **Compute-kind variant for consts.** Would save 4 words per const creation but
  adds a tag test per node evaluation; at ~101 evaluations per changed_100
  operation that is a 4% wall cost on the changed rows.

## Measurement notes

- Profile with `EIO_BACKEND=posix OCAMLPARAM=_,g=1` and
  `perf record -F 9000 -- compare.exe --only <row> --samples 4`; without the
  posix backend the harness dies on `io_uring_queue_init` under perf.
- The dynamic row is the most layout-sensitive; confirm any small dynamic delta
  with a paired SAMPLES=3 re-run before trusting it.

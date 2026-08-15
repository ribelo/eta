# Select the public interface and seam

Type: grilling
Status: resolved
Blocked by: 08, 09, 10, 11, 12, 13

## Question

Which public interface and ownership seam does the user approve?

Present each alternative before the comparison. Show types, usage, invariants,
ordering, error modes, dependencies, adapter duties, and hidden implementation
work.

Then present the recommended interface and its semantic reasons. Record the
user decision without silently selecting an interface.

## Answer

The user approved changed complete-value batch push as the public interface.

The delivered type is:

```ocaml
type Projection.delivery =
  | Updates of Projection.Batch.t
  | Bootstrap of Projection.Snapshot.t
```

The semantic reasons are:

- The canonical projection terms (`Attached`, `Changed`, `Removed`,
  `Bootstrap`) get direct public meaning.
- Eta Crux owns update classification, removal, incarnation, bootstrap, and
  atomic delivery behind one driver seam. No adapter reimplements
  reconciliation.
- Wire bytes are proportional to changed identities. The one-changed
  `encoded_bytes` are exactly equal at 10,000 and 100,000 active projections.
- Identity-binding callers keep selective reads through typed batch lookup, so
  the pull profile cursor and paging machinery buys nothing.

The common projection surface from [Alternative public
interfaces](08-alternative-public-interfaces.md) stands unchanged: kind,
catalog, publish, root, commit, typed lookup, and the existential fold. The
ownership seam is unchanged. Eta Crux owns stabilization, atomic commit,
delivery order, serialized sessions, and delivery acknowledgment. The driver
remains the only transport writer.

The selection change deletes the complete snapshot push profile and the
notification followed by bounded pull profile. The deletion covers their wire
frames, cursor and paging machinery, profile-specific PRW rows (PRW-21 and
PRW-23 to PRW-29), the pull-only clauses of shared rows (the frozen-observation clause of
PRB-07, the paging clause and `test_projection_bootstrap_paged` gate of
PRB-18, and the continuation clause of PRW-15), the snapshot-push and pull
clauses of PRF-06 with their byte workloads, and the
rejected-profile generated classes under W-02, W-03, W-06, and W-07. The
protocol keeps exactly one profile. PRW-18 (no negotiation, no fallback, no
dormant tags) becomes executable in the same change.

[Implementation plan](15-implementation-plan.md) is unblocked. It names the
exact surviving registry rows, gates, workloads, and counters, and it
schedules the profile deletion.

No new ticket is necessary.

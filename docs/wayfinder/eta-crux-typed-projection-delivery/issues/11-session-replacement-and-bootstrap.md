# Session replacement and bootstrap

Type: grilling
Status: resolved
Blocked by: 10

## Question

What happens when a serialized session attaches, closes, or is replaced?

Specify a bootstrap observation for every active value. Decide how replacement
gets current committed state without a new graph change or application replay.

Define order between old-session closure, permit settlement, fresh identity
registration, bootstrap delivery, new advancement, and post-commit work.

Specify races with commit, removal, delivery acknowledgment, root stop, root
crash, and capacity failure.

## Answer

### Bootstrap source

The bootstrap snapshot is the driver-retained latest committed projection
snapshot. Replacement performs no stabilization, no new commit, and no
application replay. The bootstrap contains every active attachment of that
snapshot in canonical order.

A removal committed before replacement needs no special case. The removed
identity is absent from the retained snapshot. The bootstrap carries the
current active attachments only.

Session replacement preserves active incarnation values. The shell can use
incarnation continuity to distinguish a continuing attachment from a
re-attachment.

The recipient installs the bootstrap as one atomic replacement of its complete
delivered snapshot. An identity absent from the bootstrap leaves the delivered
state.

### Replacement sequence

One accepted replacement performs these steps in order:

1. Preflight rejects the replacement from the driver state with the closed
   error family.
2. Fresh identity registration allocates the next session identity and a
   complete fresh remote-handle registry.
3. Eta Crux encodes the retained committed snapshot as the bootstrap against
   the fresh registry. Remote handles in the bootstrap belong to the new
   session.
4. The driver closes the old session.
5. The driver sends the bootstrap delivery on the new session.
6. Permit settlement closes old-session bound requests with `Session_closed`,
   installs the fresh registry, and waits for old export permits.
7. The driver waits for the bootstrap `projection.result`. An accepted result
   completes the replacement and lifts the advancement fence.

The bootstrap is always the first delivery on the new session. Every later
advancement batch follows it in order.

### Preflight family

The closed five-case family stays unchanged: `Starting`,
`Replacement_pending`, `Awaiting_delivery`, `Terminating`, and `Closed`.

A pending pull-profile notification is an unacknowledged delivery. Replacement
during this interval returns `Awaiting_delivery`. This rule resolves the
replacement race that [Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md) delegated to this ticket.
Session closure releases the frozen observation.

Replacement on an identity binding returns `Closed`.

`Starting` means that the driver has no committed image. An initial commit
with an empty projection image establishes an empty committed snapshot.
Replacement after that commit is legal, and its bootstrap is empty.

### Commit with no live session

If a commit occurs while no session is live, the commit publishes and the
delivery fails immediately. Eta Crux latches `Adapter_delivery`, and the root
crashes.

Replacement stays legal in the window between session loss and the next
commit. The driver state is `Running`, and committed state exists. This
replacement is the recovery path.

### Post-commit work

Replacement has no interaction with post-commit work. It never waits for
in-flight post-commit effects. A bootstrap admits no post-commit work, because
it is not a commit.

### Outcomes and terminal races

The outcome family stays `Replaced`, `Stopped`, and `Crashed of Failure.t`.

A failed bootstrap `projection.result` latches `Adapter_delivery` with trigger
`Projection_delivery`. The replacement returns `Crashed`. Loss of the new
session during bootstrap delivery has the same outcome.

Root stop during the wait returns `Stopped`. Root crash returns `Crashed` with
the root failure. Terminal work waits until the pending bootstrap delivery
receives its answer. This rule matches the terminal fence for ordinary
delivery.

Eta Crux does not retry a failed bootstrap delivery.

### Commit race and advancement fence

Commit and replacement use first-winner arbitration at driver-operation
granularity. The bootstrap carries the prior or the new complete committed
snapshot. It never carries a mix.

Advancement runs only in driver state `Running`. No advancement runs while a
replacement delivery is pending.

### Bounds

The bootstrap entry count cannot exceed `projection_capacity`. Capacity
already bounds the active identities in the committed image. Replacement adds
no new preflight failure.

If a push-profile bootstrap frame exceeds `max_frame_bytes`, Eta Crux closes
the new session with `Frame_too_large`, fails the delivery, latches
`Adapter_delivery`, and returns `Crashed`. The pull profile pages the
bootstrap under `max_frame_bytes`. An entry that cannot fit returns
`Entry_too_large`, and the shell returns a failed final result.

### Initial attach

Initial session attach has no bootstrap. The first successful commit publishes
`Attached` for every active projection. This advancement is the starting
observation of the first session.

### Relationship to later tickets

[Laws and deterministic test
controls](12-laws-and-deterministic-test-controls.md) owns the named gates for
the laws in this answer. These gates include the five `replace_error` cases
and the old-session permit-wait observation that [Current Eta Crux delivery
baseline](01-current-eta-crux-delivery-baseline.md) recorded as open gaps.

No new ticket is necessary.

# Commit observation and ownership contract

Type: grilling
Status: resolved
Blocked by: 08

## Question

What observation and ownership contract must any selected interface satisfy?

Decide initialization, significant change, dynamic removal, commit-level
batching, and the relationship with complete root-output delivery.

Define latest committed and latest delivered observations. Decide which module
retains each value and when acknowledgment admits post-commit work.

Specify the atomic observation boundary for one commit. Include delivery failure
and commits with no changed values.

## Answer

Each successful commit creates one immutable `Projection.Commit.t`. The commit
contains one complete snapshot and its ordered update batch. An observer sees
the prior or new complete commit. It never sees a partial commit.

Root computation results remain local. Projection delivery replaces complete
root-output delivery.

### Projection updates

Eta Crux compares the prior committed snapshot with the final stabilized state.
Intermediate recomputations do not enter the commit.

`Attached` publishes the first value of an incarnation. `Changed` publishes a
complete new value when the cutoff reports a significant change. An equal
candidate does not replace the retained projection value.

`Removed` ends the incarnation and removes it from the snapshot. Cutoffs cannot
suppress `Attached` or `Removed`. An incarnation replacement produces `Removed`
followed by `Attached`.

A cutoff exception is a pre-commit failure. Eta Crux preserves the prior
committed snapshot and publishes no delivery.

### Initialization and empty batches

The initial successful commit emits `Attached` for every active projection. An
initial commit with no active projections has an empty ordinary batch.

Every successful commit requires one delivery and one acknowledgment. This rule
includes a commit with an empty batch. `Bootstrap` remains specific to
serialized session replacement.

### Latest committed observation

`Driver` retains the latest committed snapshot.
`Driver.latest_committed_snapshot` returns `Projection.Snapshot.t option`. It
returns `None` before the first commit.

The driver publishes the snapshot after commit and before delivery. A concurrent
pull sees the prior or new complete snapshot. It never sees a partial snapshot.

The pull exposes no commit identity, revision, delivery state, or terminal
state. Delivery failure, stop, and crash do not clear the snapshot. A pull has
no delivery or post-commit effect.

### Latest delivered observation

The delivery recipient retains the latest delivered snapshot. The recipient has
no delivered snapshot before the first accepted delivery. An accepted empty
initial batch establishes an empty delivered snapshot.

During pending delivery, the latest delivered snapshot remains the prior
accepted snapshot. The recipient installs the complete new observation before
it acknowledges success.

Eta Crux exposes no production query for delivered state. The test handle can
retain a delivered-state shadow.

### Acknowledgment and failure

One acknowledgment covers the complete atomic delivery. Successful
acknowledgment admits post-commit work in the same effect.

Delivery failure does not roll back the commit or advance delivered state. Eta
Crux latches `Adapter_delivery` and does not retry automatically. It discards
ordinary post-commit work and starts terminal cleanup.

A stop or crash does not cancel pending delivery. Terminal work waits until that
delivery receives a successful or failed answer.

[Identity, codec, and wire
contract](10-identity-codec-and-wire-contract.md) owns deterministic batch order
and representation. [Session replacement and
bootstrap](11-session-replacement-and-bootstrap.md) owns bootstrap sequencing.

No new ticket is necessary.

# Eta Crux V1 verification

## Required test surfaces

Each law in [Semantic laws](semantic-laws.md) names its executable gate. The
implementation is complete only when all named gates pass.

The test tree has these groups:

```text
test/crux/unit/          focused deterministic cases
test/crux/laws/          generated bounded laws
test/crux/races/         controlled two-winner races
test/crux/conformance/   identity and serialized shared scenarios
test/crux/wire/          frame, replacement, and malformed-input cases
test/crux/telemetry/     fixed observation contract
test/crux/negative/      compile-time opacity gates
lib/crux/bench/          production benchmark executable
```

Use the Nix development shell for every gate:

```sh
nix develop -c dune build @install
nix develop -c dune build @bench
nix develop -c dune runtest test/crux/negative --force
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
```

## Projection gates

The projection implementation has three gate groups.

### Core

The core gates cover:

- kind generativity and catalog rejection
- identity equivalence and collision
- key and value codec obligations
- incarnation continuity, allocation, opacity, and exhaustion
- cutoff retention and defects
- independent capacity bounds
- typed preflight causes
- immutable commits and canonical order
- typed lookup and existential folds
- committed and delivered observation
- one delivery and one answer for each commit

The generated core gates are in
`test/crux/laws/test_eta_crux_projection_laws.ml`.

The deterministic core gates are in
`test/crux/unit/test_eta_crux_projection.ml` and
`test/crux/unit/test_eta_crux_test_surface.ml`.

### Wire

The wire gates cover:

- exact JSON and S-expression item structure
- item order and S-expression item count
- canonical keys, bytes, and incarnations
- payload rejection and atomic installation
- transition checks against delivered state
- frame-size boundaries
- codec encode errors and codec defects
- the committed export-registry fence
- identity delivery with zero codec work
- reason and content pairing

The generated wire gates are in
`test/crux/laws/test_eta_crux_projection_wire_laws.ml`.

The deterministic wire gates are in
`test/crux/wire/test_eta_crux_projection_wire.ml`.

### Bootstrap and replacement

The bootstrap gates cover:

- committed-snapshot source and incarnation continuity
- atomic complete replacement
- replacement step order
- the five replacement preflight errors
- empty bootstraps
- session-loss recovery
- failed bootstrap results
- the advancement fence
- frame-size failure
- initial attachment without a bootstrap

These gates are in
`test/crux/wire/test_eta_crux_projection_bootstrap.ml`.

The two-winner replacement gate is
`race_replacement_vs_commit_both_winners`.

## Property requirements

Each generated gate states its generated class and observation boundary in the
test source.

Projection generators include the discriminating case for each claim. Examples
include equivalent keys, collisions, replacements, suppressed values,
capacity-plus-one populations, item permutations, and malformed payloads.

A property executes each side of an equation. It prints the counterexample when
it fails.

## Race requirements

These projection race gates control both legal winners:

- `race_commit_atomicity`
- `race_commit_vs_crash_both_winners`
- `race_terminal_vs_delivery`
- `race_terminal_vs_bootstrap`
- `race_pull_vs_commit_both_winners`
- `race_session_replacement`
- `race_replacement_vs_commit_both_winners`

A race must settle the root and all owned work. A race that uses
`Eta_test.Run.run` must call `Eta_test.Run.expect_no_pending_fibers`.

Private barriers can stop a contender before a real linearization point. A
barrier callback does not run while the root lock is held.

## Public test API

`Eta_crux_test.Handle` uses the production identity driver.

```ocaml
module Handle : sig
  type 'incoming t
  type operation_error = Busy
  type inject_error = No_projection | Ingress_closed

  val latest_committed_snapshot :
    'incoming t ->
    Eta_crux.Projection.Snapshot.t option

  val latest_delivered_snapshot :
    'incoming t ->
    Eta_crux.Projection.Snapshot.t option

  val delivery_delivered :
    'incoming t ->
    Eta_crux.Driver.Delivery.t ->
    ((unit, Eta_crux.Driver.Delivery.completion_error) result,
     Eta_crux.never) Eta.Effect.t

  val delivery_failed :
    'incoming t ->
    Eta_crux.Driver.Delivery.t ->
    Eta_crux.Failure.Packed_cause.t ->
    ((unit, Eta_crux.Driver.Delivery.completion_error) result,
     Eta_crux.never) Eta.Effect.t
end
```

The committed snapshot comes from `Driver.latest_committed_snapshot`. The
delivered snapshot is a test-only shadow.

The handle installs the delivered shadow before successful acknowledgment. A
failed or pending delivery keeps the prior shadow.

`Projection_harness` supplies these controls:

- unit-key and keyed projection descriptors
- snapshot and batch lookup helpers
- an incarnation-counter seed
- exact capacity configuration
- an atomic wire recipient
- one-shot installation failure

The existing session peer supplies raw-frame input, write failure through
session closure, replacement, and session-loss control. Application codecs
supply returned errors and raised defects at selected calls.

The recording adapter records each accepted `Adapter.delivery`.

## Negative gates

The negative suite compiles against the installed `.cmi` files.

It confirms these projection opacity boundaries:

- `Projection.Incarnation.t` has no constructor or wire conversion.
- `Projection.Snapshot.t`, `Projection.Batch.t`, and
  `Projection.Commit.t` are abstract.
- Production code has no delivered-state query.

## Operational telemetry

The fixed logs are:

| Body | Level |
|---|---|
| `eta_crux.root.started` | `Info` |
| `eta_crux.root.stopped` | `Info` |
| `eta_crux.root.crashed` | `Error` |

The crash log can contain:

- `eta_crux.failure.origin`
- `eta_crux.failure.trigger`
- `eta_crux.observation.position`

The trigger values include `projection_preflight` and
`projection_delivery`. There is no output-delivery trigger.

The fixed metrics are:

| Name | Kind | Unit | Attributes |
|---|---|---|---|
| `eta_crux.advancements.total` | counter | `{advancement}` | `eta_crux.trigger`, `eta_crux.outcome` |
| `eta_crux.advancement.duration` | histogram | `ms` | `eta_crux.trigger`, `eta_crux.outcome` |
| `eta_crux.roots.terminal.total` | counter | `{root}` | `eta_crux.outcome` |

The duration boundaries are `0.01`, `0.025`, `0.05`, `0.1`, `0.25`, `0.5`,
`1`, `2.5`, `5`, `10`, `25`, `50`, `100`, `250`, `500`, and `1000`
milliseconds.

The fixed spans are:

- `eta_crux.advance`
- `eta_crux.post_commit`
- `eta_crux.driver.delivery`
- `eta_crux.driver.request`
- `eta_crux.session.replace`
- `eta_crux.root.teardown`

Telemetry contains no application payload, projection key, projection value, or
runtime identity. Idle polls and driver waits create no telemetry.

## Performance gates

This ticket keeps benchmark compilation green. Projection performance workloads
belong to the next ticket.

Use these commands for a local snapshot:

```sh
nix develop -c bash bench/run.sh --quick --filter '^eta_crux\.'
nix develop -c bash bench/run.sh --filter '^eta_crux\.'
```

The pre-projection full baseline is
`bench/results/20260815T184109Z-b5c4e3d6.json`.

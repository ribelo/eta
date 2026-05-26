# ADR - effect_services native service effects

## Status

Rejected. The lab closes at P1 locality.

P9 addendum: this rejects native effects as a generic service substrate. A later
Logger-specific probe accepts a narrower hardened design candidate; see
logger_domain_addendum.md.

## Context

The hypothesis was additive: keep Eta's runtime AST and ordinary argument
passing, but test whether OCaml 5 native effects can serve as an opt-in service
mechanism for ambient services such as logging, time, random, or tracing.

P1 was the hard falsifier. A root-installed service handler had to survive, or
be recoverable with at most one well-named wrapper per fork site, across Eio and
Eta structured-concurrency boundaries.

## Decision

Do not introduce native-effect-backed Eta services.

This decision applies to the generic service mechanism studied by P0-P1: a
root-installed handler that arbitrary services use directly.

All Eta services remain ordinary values or existing capabilities:

- Log, Time, Random, Tracer, Logger, Meter: values/capabilities passed at the
  runtime or application boundary.
- Pool, Connection, File, DB handles, and other lifecycle-bound resources:
  values owned by the application or by scoped Eta resource combinators.

No public Effect.Service primitive, service handler registry, startup check, or
migration plan comes from P0-P1.

## Evidence

P0 prior art confirmed the shape of the risk. Languages such as Effekt and
Koka make effects safe with effect/capability tracking. OCaml native effects do
not track handler presence; Effect.Unhandled is a runtime failure.

P1 executable evidence:

- Same-fiber service perform: resolves under the root handler.
- Eio.Fiber.both: root handler does not propagate; branch reinstall through
  Eio FLS works.
- Eio.Fiber.fork: root handler does not propagate; child reinstall through Eio
  FLS works.
- Nested Switch.run: resolves under the root handler.
- Eta.Effect.timeout: resolves in this fixture.
- Eta.Effect.acquire_release body/release: resolves under the root handler.
- Eta.Supervisor.scoped children: root handler does not propagate; both
  children record Effect.Unhandled.
- Supervisor children can be made to pass only by wrapping each service leaf
  with handler reinstall logic.

## Rationale

The user-owned Eio fork cases are recoverable, but the required Eta supervisor
case is not recoverable at the accepted abstraction boundary. Application code
does not own Eta's internal supervisor child fiber creation. Eta also does not
expose a public operation that can wrap arbitrary Eta.Effect.t evaluation under
a native handler.

Wrapping every service operation with read FLS, install handler, perform is
mechanically possible, but it is not root-installed service effects. It is
effects as syntax over fiber-local service lookup, with the same hidden ambient
state that the P0 Eio docs warn against and the same missing-handler runtime
failure OCaml exposes.

## Boundary rule

Service S belongs as a native effect iff every path that may perform S remains
inside the installed handler, or every handler-crossing fiber creation point is
user-visible and can be wrapped with one named call. Otherwise S is a value.

Under current Eta, the rule yields an empty effect-suitable set because
Supervisor.scoped is a normal Eta concurrency primitive and its children can
perform services from inside internal fibers.

## Consequences

- P2-P8 do not run; P1 is a hard stop.
- Existing Eta capability/value conventions stand.
- The lab does not reopen V-R5 or V-Native-Effects.
- No packages/ files were edited.

## Reopen criteria

Reopen only if at least one of these becomes true:

1. OCaml/Eio propagates native handlers across Eio child fibers.
2. Eta gains a generic internal mechanism that captures and reinstalls service
   handlers at every runtime-owned fiber boundary without per-service-call
   wrapping.
3. OCaml gains effect rows or another handler-presence mechanism strong enough
   to make missing service handlers a compile-time or startup-time failure.

Until then, services stay values.

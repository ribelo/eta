# Startup facts and flags

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07, 10

## Question

Does Eta Crux need a distinct startup-facts or flags concept?

Check closure capture, construction arguments, and any accepted external-input
design. Decide whether startup facts need a first-class typed contract or remain
ordinary construction input.

Decide whether to adopt, defer with a precise condition, or reject the distinct
capability. If adopted, specify the API shape, initialization laws, test
controls, ownership, failure behavior, and migration effects. If rejected,
record the supported replacement pattern.

## Answer

### Decision

**Reject a distinct startup-facts or flags capability.**

The reported claim is correct. Eta Crux has no startup-input API. The current
capability is application-composable through ordinary typed construction
dependencies.

The supporting evidence is in the
[current baseline](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md),
[decision history](../../../../.scratch/research/eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md),
[Elm census](../../../../.scratch/research/eta-crux-capability-audit/elm-public-capability-census.md),
[Eta substrate audit](../../../../.scratch/research/eta-crux-capability-audit/06-eta-substrate-capability-support.md),
and
[consumer audit](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md).

### Supported replacement pattern

The host integration decodes and validates raw startup data before application
construction. Invalid data fails at that boundary before `Root.create`. No Eta
Crux root exists, so the failure is not an Eta Crux root failure.

An application-owned builder accepts the resulting typed values. The builder
returns an inert Eta Crux description. Production code and tests call the same
builder with different typed values.

The builder can use ordinary function arguments, `return`, constructor
arguments, and closure capture. A captured value is construction data. Pure
callbacks must not read captured mutable state as a hidden reactive dependency.

`Root.create` instantiates the completed description. Root initialization keeps
the existing stabilization and commit contracts.

If a host fact changes after construction, a typed endpoint action carries the
change into an application model. This rule follows the
[External graph input](10-external-graph-input.md) decision.

### Ownership and tests

The host integration owns the raw schema, decoding, validation, and startup
failure. The application owns the typed values and its builder. Eta Crux owns
the root only after successful construction.

Eta Crux tests need no startup-specific control. Tests supply typed fixtures to
the application builder and drive the resulting root through the existing test
handle.

This rejection adds no Eta Crux API, semantic law, test control, failure
variant, or migration work.

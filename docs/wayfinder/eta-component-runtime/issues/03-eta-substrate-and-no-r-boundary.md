# Eta substrate and no-R boundary

Type: research
Status: resolved
Blocked by:

## Question

Which current Eta interfaces and decisions can support a component runtime
without reopening the environment channel?

Read the current Effect, Runtime, runtime-contract, scope, supervisor,
capability, and service surfaces. Include `docs/zio-boundaries.md`,
`docs/services.md`, the no-`R` research evidence, and relevant executable laws.

Inventory reusable ownership, cancellation, finalization, dynamic-scope,
runtime-service, typed-error, and observability mechanisms. Identify exact gaps
for reactive component lifecycles and long-lived context-mediated effects.
State which existing contracts the new design must not weaken.

Write one cited report under
`.scratch/research/eta-component-runtime/`.

## Answer

Keep `Effect.t` as `('a, 'err) Effect.t`. Eta already provides the reusable
substrate for lexical ownership, finalization, structured cancellation,
coordination, typed causes, dynamic runtime scope, and observability.

Requirements and provisions stay at a separate component-runtime seam. That seam
must own typed declarations, dynamic provider availability, long-lived
component contexts, reconciliation, replacement, stale-instance handling, and
component recovery. It must compose with Eta scopes and supervisors instead of
adding `R`, `Layer`, `Tag`, an effect-environment `Context`, `provide`, or a
second effect type. This rejects only a ZIO-style environment context attached
to `Effect.t`; it does not reject the separate component context approved by
the design.

The cited substrate inventory, preserved contracts, exact gaps, verification
plan, and evidence gaps are in the
[Eta substrate and no-`R` boundary report](../../../../.scratch/research/eta-component-runtime/03-eta-substrate-and-no-r-boundary.md).

# Eta substrate and no-R boundary

Type: research
Status: open
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

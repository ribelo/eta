# Rust Crux public capability census

Type: research
Status: resolved

## Question

What public capability families do Rust Crux and its test support provide?

Use current primary source code and official documentation. Inventory each
public capability family at a useful architectural level. Cover the core and
shell boundary, capabilities, requests, commands, streams, cancellation,
middleware, events, views, serialization, testing, and other families that the
source exposes.

For each family, record:

- its user-visible purpose.
- its essential semantic contract.
- its test control.
- its lifecycle and effect ownership.
- whether it has a plausible generic Eta Crux role, supplies design evidence
  only, or appears Rust Crux-specific.

The last classification is research evidence, not the final Eta Crux decision.
Record every excluded family with a reason.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

## Answer

The [Rust Crux census report](../../../../.scratch/research/eta-crux-capability-audit/rust-crux-public-capability-census.md)
records 22 public capability families from upstream commit
`9ca03f3545c7b695be0d1e49d1bda925c43f04e2`.

Sixteen families have a plausible generic Eta Crux role.
Three families supply design evidence only.
Three families are Rust Crux-specific.

The census covers state, events, views, the shell boundary, operations,
commands, streams, cancellation, composition, middleware, serialization,
published capabilities, and test support.
It records each semantic contract, test control, ownership boundary, research
classification, and exclusion reason.

The report makes no final capability decision.
It also records four residual evidence gaps around routing, HTTP middleware,
shell cancellation, and deterministic shell simulation.

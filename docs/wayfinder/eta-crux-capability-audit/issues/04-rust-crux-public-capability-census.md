# Rust Crux public capability census

Type: research
Status: open

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

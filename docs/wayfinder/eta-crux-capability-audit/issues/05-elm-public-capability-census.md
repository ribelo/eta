# Elm public capability census

Type: research
Status: open

## Question

What public capability families do Elm and its program-test tools provide?

Use current primary source code and official documentation. Inventory each
public capability family at a useful architectural level. Cover programs,
flags, messages, commands, subscriptions, effects, time, ports, process control,
navigation, testing, debugging, and other families that the source exposes.

Inventory UI, browser, and package-tooling families at low resolution. Mark them
as framework-specific when they have no generic state-machine role.

For each family, record:

- its user-visible purpose.
- its essential semantic contract.
- its test control.
- its lifecycle and effect ownership.
- whether it has a plausible generic Eta Crux role, supplies design evidence
  only, or appears Elm-specific.

The last classification is research evidence, not the final Eta Crux decision.
Record every excluded family with a reason.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

# Elm public capability census

Type: research
Status: resolved

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

## Answer

The [Elm census report](../../../../.scratch/research/eta-crux-capability-audit/elm-public-capability-census.md)
records 28 public capability families.

Sixteen families have a plausible generic Eta Crux role.
Seven families supply design evidence only.
Five families are Elm-specific.

The census covers 16 first-party package repositories, the compiler, Elm test
support, and `elm-program-test`.
It records each semantic contract, test control, ownership boundary, research
classification, and exclusion reason.

The report makes no final capability decision.
It also records test-control gaps and the absence of a general resource
bracket or finalizer law.

# Keyed operator structural laws

Type: grilling
Blocked by: 07, 08

## Question

Which named executable laws prove the keyed operator's structural identity,
scope, transaction, and incarnation contracts?

Use the applicable structural claims from
[Keyed assoc and stable child identity](../../eta-crux-first-principles/issues/04-keyed-assoc-contract.md).
Do not restate or weaken those claims.

Map each claim to a generated property or an authoritative Eta Signal test.
Cover successful transitions, failed preflight, rollback, removal before
addition, and remove-and-readd before commit.

Each property must observe builder counts, scope incarnations, data-source
identity, structural cleanup order, output bindings, and pending graph work.

Do not decide application action errors, effect cancellation, or lifecycle-hook
payloads. The Eta Crux tickets named by the map own those decisions.

Effects with no legitimate background work must finish with an empty fiber
census. Register every law-bearing `.mli` claim in the executable-law registry
when implementation starts.

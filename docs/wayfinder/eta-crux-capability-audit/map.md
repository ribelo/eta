# Eta Crux capability audit map

## Destination

An evidence-backed, implementation-ready decision set for the Eta Crux
capability surface. The result checks the nine reported gaps, audits the full
reference capability space, and classifies each candidate as adopt, defer, or
reject.

## Notes

Planning is the deliverable. Implementation and canonical design-document
changes are not part of this map.

Eta Crux combines Bonsai graph semantics, Rust Crux host boundaries, and Elm API
simplicity. These projects are design references, not compatibility targets.

The audit uses two stages:

1. Inventory every public capability family in Bonsai, Rust Crux, Elm, and their
   test tools.
2. Classify each family as an Eta Crux candidate, useful design evidence, or
   framework-specific and out of scope.

The detailed assessment covers every candidate and all nine reported gaps. Each
excluded family needs a recorded reason.

Classify each reported claim as missing, partial, application-composable,
deliberately excluded, or incorrect. Then classify each candidate decision:

- **Adopt** means that the capability enters the next implementation effort.
- **Defer** requires a specific condition that will reopen the decision.
- **Reject** records a deliberate exclusion and its reason.

Use semantic ownership, deterministic testing, failure risk, consumer evidence,
repeated application boilerplate, and public-surface cost as the decision
rubric. Prior-art presence alone does not establish Eta Crux ownership.

Eta effects remain opaque by default. An inspectable command algebra is
available only if opaque effects cannot provide the required assertions without
duplicated protocols.

Taumel, Sliml, and other consumers supply scenarios and cost evidence. They do
not define the architecture. Eta has no release boundary for this effort.

An accepted design specifies its API shape, semantic laws, test controls,
ownership, and migration effects. It does not prescribe internal data
structures or implementation steps.

The current baseline is:

- [`eta_crux`](../../../lib/crux/eta_crux.mli)
- [`eta_crux_test`](../../../lib/crux_test/eta_crux_test.mli)
- [Eta Crux V1 design](../../design/eta-crux-v1/README.md)
- [Eta Crux semantic laws](../../design/eta-crux-v1/semantic-laws.md)
- [Eta Crux first-principles map](../eta-crux-first-principles/map.md)

Use primary sources for factual claims. Use `$research` for research tickets.
Use `$grilling` and `$domain-modeling` for decision tickets. Write all map,
ticket, and research prose with `$simple-english`.

## Decisions so far

- [Current Eta Crux capability baseline](issues/01-current-eta-crux-capability-baseline.md)
  — The baseline records one missing, three partial, three
  application-composable, and two deliberately excluded capabilities.
- [Prior decision and requirement provenance](issues/02-prior-decision-and-requirement-provenance.md)
  — The history records two superseded promises, two unresolved questions, two
  explicit decisions, and three exclusions. No gap is an accidental omission.
- [Bonsai public capability census](issues/03-bonsai-public-capability-census.md)
  — The census finds 21 families: 16 plausible generic roles, four design-evidence families, and one Bonsai-specific family.
- [Rust Crux public capability census](issues/04-rust-crux-public-capability-census.md)
  — The census finds 22 families: 16 plausible generic roles, three
  design-evidence families, and three Rust Crux-specific families.
- [Elm public capability census](issues/05-elm-public-capability-census.md)
  — The census finds 28 families: 16 plausible generic roles, seven
  design-evidence families, and five Elm-specific families.
- [Eta substrate capability support](issues/06-eta-substrate-capability-support.md)
  — Eta supplies core time, observation, handoff, cancellation, and test
  mechanics. Several Crux-level protocols and bounded diagnostic surfaces are
  absent.

## Not yet specified

The reference census can expose candidate capability gaps beyond the nine
reported items. These candidates cannot be named until
[Complete capability relevance census](issues/08-complete-capability-relevance-census.md)
classifies the reference families.

## Out of scope

- Eta Crux implementation.
- Changes to the canonical Eta Crux design documents.
- Compatibility with Bonsai, Rust Crux, or Elm APIs.
- Features added only to match another framework.
- UI components, renderers, browser APIs, and package tooling with no generic
  Eta Crux role.
- Taumel or Sliml application design.
- Release planning and compatibility shims.
- Performance tuning that does not change a capability contract.

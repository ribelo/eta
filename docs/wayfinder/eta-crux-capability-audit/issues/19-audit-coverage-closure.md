# Audit coverage closure

Type: task
Status: resolved
Blocked by: 18

## Question

Check that the capability audit is complete.

Make sure that every public capability family in the three reference frameworks
has one recorded relevance classification and reason. Make sure that every Eta
Crux candidate has one resolved decision ticket with an adopt, defer, or reject
disposition.

Make sure that every adopted design specifies its API shape, laws, test controls,
ownership, and migration effects. Make sure that the map contains no remaining
fog.

If coverage is incomplete, create or reopen the necessary tickets. Resolve this
task only when the complete decision set is ready for documentation and
implementation handoff.

## Answer

### Result

The audit is complete. The decision set is ready for documentation and
implementation handoff.

### Reference-family coverage

The final relevance census covers every inventoried family:

| Framework | Families | Candidate | Evidence | Out of scope |
|---|---:|---:|---:|---:|
| Bonsai | 21 | 4 | 16 | 1 |
| Rust Crux | 22 | 6 | 13 | 3 |
| Elm | 28 | 8 | 15 | 5 |
| Total | 71 | 18 | 44 | 9 |

Each row records one relevance class and one reason or decision link. The family
names and sequence match the three source censuses.

### Candidate-decision coverage

The census produces 11 decision tickets. All 11 tickets are resolved:

- Six tickets adopt a capability.
- Four tickets reject a capability.
- [Action history and diagnostics](17-action-history-and-diagnostics.md) defers
  one capability with precise reopening conditions.

The 11 tickets cover all nine reported gaps plus
[Structural model reset](20-structural-model-reset.md) and
[Poll run result coordination](21-poll-run-result-coordination.md).

### Accepted-design coverage

The accepted surface contains seven designs:

- graph time and deterministic clock control.
- explicit effect absence and post-commit effect observation.
- root-wide bounded FIFO ingress.
- pull observation of the latest committed Root output.
- corrected one-shot handler claims.
- structural model reset.
- Poll run result coordination.

Their capability tickets specify API shape, semantic laws, test controls,
ownership, and migration effects. [Coherent accepted capability
surface](18-coherent-accepted-capability-surface.md) specifies their shared
terms, interactions, and final concurrency contracts.

The coherence decision also assigns normative owners and named gates for Driver
attachment, shared-clock movement, and observer-consumer races.

### Map closure

All decision dependencies are resolved. The map has no remaining fog, and this
audit creates no additional ticket.

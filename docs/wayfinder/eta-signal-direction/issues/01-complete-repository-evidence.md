# Complete repository evidence

Type: task
Status: resolved
Blocked by: none

## Question

What does the complete repository add to or contradict in the independent
review, and where will every substantive review claim receive a decision?

First, create a lossless claim census for the complete
[independent review](../../../../.scratch/research/eta-signal-direction/independent-review.md).
Cover these sections:

- Scope, evidence limits, and revision limits.
- The executive verdict.
- F1-F14, including evidence, amended statements, corrections, and sequencing.
- N1-N5, including counterexamples, invariants, tests, and sequencing.
- Semantic rows S1-S17.
- The ranked correction plan and each rejected or deferred correction.
- All seven maintainer questions and the binding recommendation.

Split a paragraph when it contains separate claims. Give each census row:

- A stable row identity.
- An exact review line range.
- A one-line claim gist.
- A claim class, such as limitation, fact, counterexample, invariant,
  requirement, recommendation, or open question.
- One owner ticket or an explicit out-of-scope decision.
- An evidence status and final disposition.

Build one evidence matrix for F1-F14 and N1-N5. Inspect the law registry, Signal
tests, Signal Map tests, requirements, ADRs, and whole-repository symbol use.
Settle the conditional parts of F3 and F6. Identify existing tests that already
cover each new counterexample, and identify the exact missing cases.

Record the difference between the packed revision and the probe revision. Do
not accept a finding only because the independent review accepts it. Save the
claim census and evidence matrix under
`.scratch/research/eta-signal-direction/`. Do not resolve this ticket while a
claim is absent from the census or has no owner.

## Answer

The complete repository removes the revision uncertainty. The relevant Signal
source, tests, requirements, ADR, PRD, kernel contract, and law registry have
the same Git objects at `5694938a`, `4197be98`, and evidence baseline
`96f77eba`.

The probe timings therefore measure the same Signal code as the packed review.
They remain supporting evidence because they use wall time and do not give a
deterministic core-work gate.

Repository use is inventory evidence only. It cannot establish external
consumer value, and it does not justify interface omission or deletion.

The repository settles both conditional evidence questions:

- F3 is explicit but incomplete dated debt. The registry has 15 exact
  `eta_signal.mli` rows, and all 15 cover keyed diagnostics.
- F6 has five test-only functor consumers. `Make_edges` is the only listed
  functor with a production instantiation. This result does not decide whether
  to retain, adopt, replace, expose, or remove the other functors.

The repository has nearby coverage for N1-N5, but no test runs each exact
discriminating case. Tickets 02-05 own executable evidence for N1-N4. Ticket 09
owns N5 and the transaction model. Tickets 09-17 own the resulting design and
gate decisions.

The claim census gives every substantive review claim one owner. Its
`Retain`, `Amend`, `Reject`, and `Assign` values are final traceability
dispositions for this ticket. An `Assign` value does not decide the downstream
design.

Research reports:

- [Claim census](../../../../.scratch/research/eta-signal-direction/claim-census.md)
- [Repository evidence matrix](../../../../.scratch/research/eta-signal-direction/evidence-matrix.md)

### Census rows resolved here

- Scope and method: `SCP-001`, `SCP-002`, `SCP-003`, `SCP-004`, `SCP-005`,
  `SCP-007`, `SCP-008`, `SCP-010`, `SCP-011`, `SCP-012`, `SCP-014`,
  `SCP-015`, and `SCP-016`.
- Bounded negative evidence: `EXE-015` and `EXE-016`.
- F3 evidence: `F03-003`, `F03-004`, `F03-008`, and `F03-009`.
- F6 evidence: `F06-001`, `F06-002`, `F06-004`, and `F06-005`.
- Corrected routing: `F11-007` and `S05-001`.
- Existing economics evidence: `F13-002`, `F13-003`, `F13-006`, and
  `S13-003`.
- Complete-repository dependency: `PLN-10-002`.
- Maintainer evidence questions: `Q01-001` and `Q02-001`.

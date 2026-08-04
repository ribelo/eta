# Complete repository evidence

Type: task
Status: open
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

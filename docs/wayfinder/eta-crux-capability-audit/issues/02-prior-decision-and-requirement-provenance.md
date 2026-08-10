# Prior decision and requirement provenance

Type: research
Status: resolved

## Question

What decision history exists for the nine reported gaps and related capability
families?

Trace the first-principles tickets, durable research, removed requirement
bundles, current design documents, and relevant Git history. Check the named old
requirements when they exist, including `tick-k9r2`, `eng-6h8t`, `test-h5w3`,
`test-r8k2`, `test-3h6t`, `test-b5r8`, and `cmd-r5w9`.

For each capability, distinguish:

- an explicit accepted decision.
- an explicit exclusion.
- an unresolved question.
- an accidental omission.
- a superseded promise.

The old bundle is evidence only. Do not treat it as a binding contract. Record
facts and rationale without deciding the new disposition.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

## Answer

The [provenance report](../../../../.scratch/research/eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md)
traces all seven named requirements and all nine gaps through the full decision
history.

The report records:

- Graph time and pull observation as superseded promises.
- External graph input as an old unresolved question followed by an explicit
  endpoint-only decision.
- Startup flags and ingress admission classes as unresolved questions without
  explicit final decisions.
- Staged-effect observability as an explicit accepted opaque-effect decision.
  Controlled dependencies supersede the prior pending-command-handle promises.
- Streaming requests, middleware chains, and action history as explicit
  exclusions.

No gap is an accidental omission. All seven named requirements existed before
the old bundle was removed. The current `eng-6h8t` mention is a stale reference,
not a normative requirement.

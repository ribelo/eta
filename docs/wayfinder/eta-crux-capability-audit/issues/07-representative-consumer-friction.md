# Representative consumer friction

Type: research
Status: resolved

## Question

What repeated application or adapter work appears in representative Eta Crux
consumers?

Examine Taumel, Sliml, repository examples, benchmarks, and tests that use Eta
Crux. Treat them as evidence, not architectural authorities.

Check scenarios for the nine reported gaps. Also find other repeated protocols,
state duplication, adapter caches, shadow queues, time control, host resource
lifecycle, effect assertions, and diagnostic work.

For each pattern, record:

- concrete source locations.
- its frequency and complexity.
- the failure mode when it is implemented incorrectly.
- whether the work appears application-specific or framework-generic.

Do not infer a requirement from one consumer. Do not design a remedy.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

## Answer

The [consumer-friction report](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md)
records the evidence.

Eta Crux has no external consumer in the examined repositories. The direct
evidence comes from repository tests, benchmarks, and research adapters.

Taumel uses Eta core. Sliml uses Eta only in scratch evidence. Their patterns
are indirect evidence for this audit.

Time control is the strongest repeated pattern. Crux tests use controlled Eta
time. Taumel builds clocks, host-time inputs, and deadline races.

Effect assertions, pull-output caches, and manual dispatch layers also repeat.
Existing test helpers cover part of the assertion work.

Many-response operations, admission limits, durable history, claim protocols,
and rollback appear only in Taumel. These findings do not establish Eta Crux
requirements.

No consumer shows another external-input form or a separate startup-flags need.
This absence is weak evidence because the consumer set is small.

Later classification tickets must treat this report as limited cost evidence.
They must not treat absent consumer evidence as a rejection reason.

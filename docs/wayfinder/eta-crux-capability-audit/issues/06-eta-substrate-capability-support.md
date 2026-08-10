# Eta substrate capability support

Type: research
Status: resolved

## Question

Which current Eta capabilities can support the reported and newly discovered Eta
Crux candidates?

Check the public Eta runtime, effect, duration, schedule, queue, channel,
supervisor, source-like, observability, and test surfaces. Check implementation
details only when a public contract depends on them.

At minimum, establish:

- how injected clocks and sleepers work.
- what deterministic clock control tests already have.
- what names, annotations, identity, and lifecycle observations Eta effects
  expose.
- which bounded queue policies and fairness rules exist.
- which cancellation, scope, and resource protocols can own host streams.
- which observability facilities can record bounded diagnostics.

Separate available substrate from missing substrate. Identify which facts belong
to Eta and which belong to Eta Crux. Do not decide the final capability designs.

Write one cited report under
`.scratch/research/eta-crux-capability-audit/` and link it from the answer.

## Answer

The [Eta substrate report](../../../../.scratch/research/eta-crux-capability-audit/06-eta-substrate-capability-support.md)
audits the required public surfaces and separates available substrate from
missing substrate.

Eta supplies injected monotonic clocks, deterministic test clocks, effect
descriptions, structured observations, bounded handoff policies, scoped
cancellation, and resource finalizers.

Eta Crux still lacks a deadline wake, test-handle time control, staged-effect
inventory, admission classes, and a production pull API.
Eta also lacks a generic owned effectful pull source, a many-response host
operation, and a production bounded log ring.

The report assigns runtime mechanics and test controls to Eta.
It assigns graph cadence, ingress policy, host binding, and Crux observation
contracts to Eta Crux.
It makes no final capability decision.

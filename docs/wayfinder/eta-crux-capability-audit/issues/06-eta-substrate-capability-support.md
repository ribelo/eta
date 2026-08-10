# Eta substrate capability support

Type: research
Status: open

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

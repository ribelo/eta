# Operational introspection boundary

Type: grilling
Status: open
Blocked by: 05, 11, 12

## Question

What operational introspection belongs in Eta Crux V1 after typed actions,
failures, and the test contract are fixed?

Decide:

- which logs and metrics are production observations instead of test probes.
- whether action history exists outside explicit application diagnostics.
- whether any graph structure can be inspected without becoming public identity.
- whether time travel is possible without retaining models, effects, or host state.
- how redaction applies to actions, models, requests, and output.
- which observations belong to Eta, Eta Crux, a driver, or an adapter.
- which disabled instrumentation has zero semantic effect.

Do not expose private graph nodes only because internal law tests can inspect
them. Do not make a debugger or replay system part of V1 without a complete
state, effect, and host-boundary contract.

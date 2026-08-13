# StateFlow publication semantics

Type: research
Status: open
Blocked by: none

## Question

Which Kotlin `StateFlow` semantics can inform Eta Crux typed projection
delivery?

Use current Kotlin documentation and source code. Cover current-value retention,
equality conflation, replay to new collectors, collector order, backpressure,
and cancellation or reconnection.

Explain the limits of independent flows for one atomic observation of multiple
changed values. Record the latest-value owner and separate transferable
semantics from non-transferable semantics.

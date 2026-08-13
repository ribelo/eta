# StateFlow publication semantics

Type: research
Status: resolved
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

## Answer

The [research report](../../../../.scratch/research/eta-crux-typed-projection-delivery/stateflow-publication-semantics.md)
records the full evidence and source revisions.

`StateFlow` owns one current value. It suppresses equal updates and replays the
current value to each new collector. A slow collector can skip distinct
intermediate values, but it receives the latest value. A writer does not wait
for collectors. Collector cancellation removes only that collector.

`StateFlow` does not specify an order across collectors. It also has no delivery
acknowledgment, failure, or completion outcome.

Independent state flows do not provide one atomic observation of several
changed values. `combine` uses each input's latest value and can expose an
intermediate combination. Its suspension points do not create a shared commit.

Eta Crux can transfer current-value retention, current-value replay, explicit
equality policy, and cancellation checks. The Eta Crux driver remains the owner
of the latest committed output.

Eta Crux cannot transfer committed-output conflation, missing acknowledgment,
unspecified delivery order, or independent streams without one atomic
publication. These limits do not select the final public interface.

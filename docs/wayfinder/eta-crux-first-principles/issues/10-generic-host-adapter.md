# Generic host adapter contract

Type: prototype
Status: open
Blocked by: 06, 08, 09, 11, 16, 19

## Question

What is the smallest host-neutral contract between a running Eta Crux
application and a renderer or other external host?

Use Sliml as one falsifier, not as the interface template. The contract must
show:

- host event conversion into typed injection.
- delivery of the canonical root result or observation-plan changes.
- host-thread scheduling without exposing host handles to Eta Crux.
- startup, wake, stop, and ordered teardown.
- typed `Ingress_closed` admission and adapter capacity reporting.
- fatal output-delivery reporting before post-commit start.
- immediate crash detection and final teardown settlement.
- one same-domain host and one foreign-loop retained host.
- a recording fake that verifies the adapter without its toolkit.

Host-owned event systems expose the generic two-phase producer from
[Long-lived sources and subscriptions](08-subscriptions-and-sources.md). The
adapter reports readiness after it installs the host event path. Eta Crux still
owns source identity, reconciliation, and cancellation.

Determine which operations belong to Eta Crux, to a generic adapter helper, and
to a concrete package such as `eta_crux_sliml`. The core must not acquire a
renderer, serialization format, or Sliml value model.

[Failure, defect, and crash boundary](11-failure-boundary.md) fixes the semantic
failure outcomes. This ticket owns their host-neutral callback and scheduling
surface.

# Generic host adapter contract

Type: prototype
Status: open
Blocked by: 06, 09, 16, 19

## Question

What is the smallest host-neutral contract between a running Eta Crux
application and a renderer or other external host?

Use Sliml as one falsifier, not as the interface template. The contract must
show:

- host event conversion into typed injection.
- delivery of the canonical root result or observation-plan changes.
- host-thread scheduling without exposing host handles to Eta Crux.
- startup, wake, stop, and ordered teardown.
- admission and delivery failure reporting.
- one same-domain host and one foreign-loop retained host.
- a recording fake that verifies the adapter without its toolkit.

Determine which operations belong to Eta Crux, to a generic adapter helper, and
to a concrete package such as `eta_crux_sliml`. The core must not acquire a
renderer, serialization format, or Sliml value model.

# Minimal general supervised-work interface

Type: prototype
Status: open
Blocked by: 01

## Question

If **Current public composition verdict** proves a gap, what is the smallest
general Eta interface that closes that exact gap?

Compare at least two designs. Include managed task groups and atomic supervisor
admission unless the proven gap rules one out.

The selected design must meet these constraints:

- The interface is backend-neutral.
- The ownership tree cannot escape its structured lifetime.
- Admission has one explicit atomic registration point.
- Cancellation and settlement preserve complete `Eta.Cause` values.
- Shutdown gives a completion fence for all owned work and resources.
- The interface contains no Eta Crux concepts.
- The interface exposes no Eio switch or runtime-contract token.
- The interface provides no unscoped detach operation.

Compile the public type sketch under the OxCaml and upstream OCaml tracks. Use
adversarial behavior probes for ordering, cancellation, failure, and shutdown.

Select one design and state why the other designs fail the contract or add
unnecessary surface. Identify the public laws and backend obligations that the
production change needs.

If **Current public composition verdict** proves no gap, rule this ticket out of
scope.

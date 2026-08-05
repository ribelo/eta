# Minimal general supervised-work interface

Type: prototype
Status: resolved
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

Compile the public type sketch under OxCaml. Use adversarial behavior probes for
ordering, cancellation, failure, and shutdown.

Select one design and state why the other designs fail the contract or add
unnecessary surface. Identify the public laws and backend obligations that the
production change needs.

If **Current public composition verdict** proves no gap, rule this ticket out of
scope.

## Answer

### Selection

Add one operation to the existing supervisor interface:

```ocaml
val request_cancel :
  ('s, 'err, 'a) child -> ('s, unit, 'outer_err) Scope.t
```

`request_cancel child` issues the existing idempotent child cancellation
request. It returns without waiting for the child result promise.

The existing `cancel child` operation remains the settlement fence. It waits
for cleanup and preserves child or finalizer failures.

The user approved this selection after the prototype review.

### Interface boundary

The operation belongs in the root `eta` package and the existing `Supervisor`
module. It is general Eta lifecycle machinery.

The rank-two supervisor brand remains unchanged. No child, scope, or
cancellation token can escape its nursery.

The interpreter uses the existing child cancellation callback. The selected
interface needs no new backend contract operation.

### Rejected designs

An atomic supervisor-admission operation duplicates working effect registration
and caller-owned phase policy. It also requires packed children and owner
routing across nested supervisors.

A managed task-group module duplicates the existing supervisor ownership tree
and failure tracking. The proven gap does not require another group handle
or public lifetime vocabulary.

The selected operation passes the deletion test. Without it, callers need
private access to the child cancellation callback to regain the missing point.

### Evidence

The prototype is on branch `prototype/eta-supervised-work-minimal-interface`.

- Candidate commit: `25599df1`
- Results commit: `f90f8232`
- [Prototype results](https://github.com/ribelo/eta/blob/f90f8232/.scratch/research/eta-supervised-work-substrate/minimal-interface/RESULTS.md)

Both commands exited with status `0`:

```sh
nix develop -c bash .scratch/research/eta-supervised-work-substrate/minimal-interface/run.sh
nix develop .#mainline -c bash .scratch/research/eta-supervised-work-substrate/minimal-interface/run.sh
```

The candidate compiled under OCaml `5.2.0+ox` and upstream OCaml `5.4.1`.
Both tracks produced the same traces.

The probes demonstrated atomic registration, idempotent requests, ordered
release, cleanup overlap, failure preservation, first-terminal-outcome behavior,
and complete shutdown settlement.

[Production request-cancellation contract](03-production-request-cancellation-contract.md)
owns the exact laws, test names, backend obligations, and production gates.

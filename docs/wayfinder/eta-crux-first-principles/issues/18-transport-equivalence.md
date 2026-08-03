# Identity and serialized transport equivalence

Type: prototype
Status: resolved
Blocked by: 06, 10, 11, 13, 16, 17

## Question

Can one Eta Crux application run with an in-process shell or a serialized shell
without changing its semantics or application description?

Run one application through an identity driver and a serialized loopback driver.
Compare:

- inbound message and transition order.
- committed models and typed root outputs.
- staged host-operation requests and resolutions.
- endpoint activation, invocation, and revocation.
- stale, malformed, full, and closed admission results.
- effect start and cancellation traces.
- crash detection and final settlement traces.
- synchronous re-entry rejection.
- local-path allocation, remote-handle lookup, and encoding overhead.

Decide whether transport specialization belongs in a driver functor, a runtime
value, or another root-owned seam. The application computation must not depend
on that choice. The local driver must not allocate remote handles or encode
payloads.

## Prototype

The comparison harness is on branch
`prototype/eta-crux-transport-equivalence` at commit `8be825d7`:

- [prototype](https://github.com/ribelo/eta/tree/8be825d7/.scratch/prototypes/eta-crux-transport-equivalence)
- [results](https://github.com/ribelo/eta/blob/8be825d7/.scratch/prototypes/eta-crux-transport-equivalence/RESULTS.md)
- [provisional seam](https://github.com/ribelo/eta/blob/8be825d7/.scratch/prototypes/eta-crux-transport-equivalence/SEAM.md)

## Answer

### Equivalence boundary

One application description runs through an identity binding or a serialized
binding. The application computation cannot observe or select this binding.

Both bindings use the same root, advancement transaction, typed ingress queue,
post-commit protocol, request lifetime, and crash protocol. They preserve:

- the order of inbound messages and transitions.
- committed models and complete typed root outputs.
- host-operation dispatch, resolution, and cancellation.
- export activation, invocation, revocation, and re-entry.
- effect start and cancellation order.
- crash detection and final settlement.
- synchronous re-entry rejection.

Transport-only rejection occurs before typed core admission. Malformed frames,
handles, payloads, sequences, and correlation data cannot change application
state or add an application action.

The two bindings return the same outcomes for their shared operations. The
serialized binding adds closed protocol outcomes that have no typed local form.
This addition does not change the shared outcomes.

### Selected seam

Transport specialization is one closed runtime binding inside the driver. The
integration selects this binding when it creates the driver for a root.

The binding has two framework-owned variants:

- The identity binding carries typed OCaml values directly.
- The serialized binding carries the exact frame protocol from
  [Wire codec and protocol contract](17-wire-codec-protocol.md).

The binding is not an application value, computation node, host capability, or
open adapter object. A root uses one binding for its complete lifetime.

Eta Crux can use internal functors to construct the two closed variants. The
public API does not expose these functors or give them different driver types.

### Ownership

The root owns computation state, structural identity, export active intervals,
atomic commit, typed ingress, work ownership, and failure settlement.

The common driver owns advancement, delivery fences, request events, and hosted
loop ordering. Both bindings call these same operations.

The identity binding owns direct typed delivery only. It creates no serialized
registry, remote handle, frame, sequence, token, or encoded payload.

The serialized binding owns:

- the active session and authenticated handle registry.
- payload and root-output codecs.
- frame encoding and decoding.
- sequence and result correlation.
- protocol closure and session replacement.

Structural commit calls one closed internal binding hook. The identity hook does
nothing. The serialized hook updates the active handle registry as part of the
same commit.

### Session administration

Only a serialized binding creates a session-administration capability. Session
replacement requires this capability and the common driver.

An identity binding creates no such capability. The generic driver API does not
add `Not_serialized`, and an identity driver cannot change into a serialized
driver.

This decision narrows the provisional generic replacement operation in
[Generic host adapter contract](10-generic-host-adapter.md). The final OCaml
surface must keep one common driver and place the capability with the serialized
binding.

### Prototype result

The two prototype runs used the same application description and core functions.
They produced the same 19 semantic observations and the same shared boundary
outcomes.

The serialized run rejected malformed input before core admission. The identity
run recorded zero remote-handle allocations, registry lookups, codec operations,
and wire bytes.

The serialized run recorded two remote-handle allocations, 10 registry lookups,
10 payload encodes, nine payload decodes, and 258 wire bytes. These values are
protocol-operation counts, not performance measurements.

The prototype passes with OxCaml 5.2.0+ox and upstream OCaml 5.4.1.

### Rejected alternatives

Eta Crux does not expose a public driver functor. A public functor makes common
hosted code and session administration depend on different module instances.

Eta Crux does not accept an open transport record. The semantic protocol is
closed, so third-party implementations cannot replace parts independently.

Eta Crux does not put transport selection in the application description or
computation graph. It does not make the identity path allocate dormant wire
state.

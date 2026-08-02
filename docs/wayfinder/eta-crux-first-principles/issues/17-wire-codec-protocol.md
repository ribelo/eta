# Wire codec and protocol contract

Type: prototype
Status: open
Blocked by: 13, 16

## Question

What wire contract carries exported endpoint invocations and host operations
between an Eta Crux core and a shell in another process or language?

Decide and prototype:

- the payload codec abstraction and its error type.
- schema ownership, protocol tags, and versioning.
- envelope session, sequence, and correlation fields.
- endpoint invocation, request resolution, cancellation, and revocation.
- size limits, malformed input, unknown tags, and duplicate messages.
- whether one format is fixed or selected by a transport package.
- whether V1 needs generated foreign-language types.
- which protocol details remain invisible to application computations.

Use one serialized loopback and one second-language fixture. Do not serialize
closures, local endpoints, graph structure, models, or complete internal action
types.

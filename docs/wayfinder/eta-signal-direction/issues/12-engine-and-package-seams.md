# Engine and package seams

Type: grilling
Status: open
Blocked by: 06, 08, 09, 10

## Question

Where do the Eta Signal engine, Eta Signal Map, and any extension seam belong?

Decide whether the engine stays closed, exposes a narrow first-party protocol,
or gains another deep-module seam. Decide graph-functor ownership, the
two-graphs problem, package dependencies, version coupling, and the type-safe
testing surface.

The result must resolve F2, F7, F10, and ADR 0004. It must not expose phase,
scope, transaction, or graph-mutation complexity to application consumers.

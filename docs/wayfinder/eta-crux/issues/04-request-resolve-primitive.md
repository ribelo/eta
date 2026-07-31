# Request/resolve as a framework primitive, in both directions

Type: grilling
Status: open

## Question

**This reopens a recorded decision.** The notes currently state that shell interaction is
symmetric messaging with no framework request mechanism, and that correlation is an
application-level token. A reviewer argues the framework must own ask-and-answer in both
directions, under one failure taxonomy.

The case for reopening: request and resolve currently flow only outward, as capability
messages. There is no inbound ask — a host asking the core and awaiting an answer. Every
non-UI host is ask-shaped: a Pi extension tool call, an HTTP handler, LSP, JSON-RPC. The
boundary rightly forbids synchronous dispatch-then-read, so an ask must today be hand-built
from an action carrying a token plus a fragment or capability message carrying that token
back — the string-keyed correlation table this architecture exists to delete. A
mis-correlation then becomes an application bug instead of a framework error. Crux makes it
a primitive: `Request<Op>`, `RequestHandle::{Never,Once,Many}`, `Core::resolve`, and
`ResolveError::{Never,FinishedMany,NotFound}`.

Decide, and if adopted keep it **one** concept serving both directions:

- Inbound ask admitted as an ordinary action carrying an opaque request handle; resolution
  permitted only through a scheduled command; exactly-once delivery under Once semantics
  with a reported error for later resolutions; a reported not-found when the owning scope
  was disposed; a never-resolved ask staying pending with no synthesized value; no
  state-mutating operation exposed while an ask is pending beyond ordinary admission.
- Outbound capability messages that expect a response carrying the same handle with Once or
  Many semantics, so a stale shell response becomes a framework-reported error rather than
  an application ambiguity.
- One taxonomy shared by ask replies, capability responses and action-admission failures.
  Candidate members: never, finished-once, finished-many, not-found, saturated, closed.
  This also answers the open "exact adapter-facing admission-failure type".
- Whether application-level correlation payloads remain permitted alongside the framework
  handle.

If adopted, the recorded claim narrows from "no request mechanism" to "no serialized
Operation/Request/resolve machinery", and `shell-capabilities.md` plus `errors.md` must be
rewritten rather than extended. The ADR for that decision then depends on this ticket.

---
kind: requirement
---
# HTTP server connection invariants

## Intent

Keep shared H1 and H2 server lifecycle behavior consistent without pretending
their protocol state machines are the same.

## Requirements

- The eta-http Eio server shall use one common cause traversal when selecting a typed server failure from a handler cause. ^httpsrv-fooq
- The eta-http Eio server shall use one common policy for constructing handler-timeout, response-body-timeout, and handler-exception errors. ^httpsrv-f1oi
- The eta-http Eio server shall use one common policy for converting an unhandled handler failure into a fallback response. ^httpsrv-x8ru
- The eta-http Eio server shall apply the same handler observability and exception fencing for H1 and H2 requests. ^httpsrv-77jk
- The eta-http Eio server shall preserve separate H1 and H2 protocol state machines. ^httpsrv-w8gc
- A private `Server_connection_common` module shall own shared H1 and H2 cause traversal, error construction, fallback-response, and handler-fencing behavior. ^httpsrv-m558
- The H1 and H2 server connection modules shall retain their protocol-local phase-trace helpers. ^httpsrv-izhn

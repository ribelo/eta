# R-Pool-Shape-Survey Results

## Question

What belongs in Eta.Pool before Eta-t59 starts?

The pool-survival lab proved that a bounded checkout lifecycle is worth owning
inside Eta. It did not prove that every connection-like structure is the same
primitive.

## Cross-Tab

| Consumer | Needs bounded checkout of values? | Needs one active value with many concurrent users? | Needs keyed registry? | Fits Eta.Pool? |
| --- | --- | --- | --- | --- |
| eta-http HTTP/1.1 | Yes. Several warm idle connections per authority, one request owns one connection at a time. | No. Pipelining is not the v1 contract. | Yes, keyed by scheme/host/port/ALPN outcome. | Yes, one Pool per h1 authority bucket. |
| eta-http HTTP/2 multiplexer | No. One TCP/TLS connection carries many concurrent streams. | Yes. Stream admission is a permit counter plus per-stream routing. | Yes, keyed by authority. | No. Pool checkout inverts the contract. |
| eta-http ALPN bootstrap | Temporarily unknown until TLS resolves ALPN. | Sometimes, when ALPN resolves h2. | Yes, keyed by authority and pending connection state. | Pool only after ALPN resolves h1. |
| eta-sql connection pool | Yes. A query/session borrows one connection, returns it, and health/lifetime policy applies. | No for ordinary drivers. Transaction/session modes are policy over checkout. | Often, keyed by tenant/role/database. | Yes, same Pool primitive as h1. |
| eta-grpc over h2 | No for the transport. Calls are streams over one multiplexer. | Yes. Needs stream admission, not connection checkout. | Yes, keyed by authority/channel config. | No for h2 transport; possibly yes for non-h2 resources. |

## Health Check Shape

Pool health checks should be effectful:

    health_check : conn -> (unit, err) Effect.t

Reasons:

- HTTP/1.1 may need a nonblocking EOF probe, ping-like request, or TLS/socket
  check at the IO leaf.
- SQL health checks commonly issue a lightweight query or protocol ping.
- A synchronous predicate would force users to hide real IO behind Effect.sync
  or skip health entirely.

The implementation can still offer Effect.unit as the default.

## Verdicts

### Hypothesis A: One Pool For HTTP/1.1 And SQL

Accepted.

Eta.Pool should cover bounded checkout/release of ordinary same-domain
connection values:

- max size
- max idle
- idle lifetime
- max lifetime
- effectful health check
- cancellation-safe wait cleanup
- graceful shutdown
- stats and observability

HTTP/1.1 and SQL differ in configuration and adapter policy, not in the core
lifecycle primitive.

### Hypothesis B: HTTP/2 Multiplexer Is Separate

Accepted.

The h2 multiplexer is single-connection, many-streams. Pool.with_resource would
either hold the connection for one stream, which defeats multiplexing, or return
a handle whose real resource lifetime outlives the callback, which breaks
Pool's ownership model.

For v1, the h2 multiplexer stays inside eta-http. The shared Eta primitives it
should consume are Channel/Permit_set from H-D0 once shipped, not Pool. eta-grpc
can reopen a public multiplexer primitive later with real second-user evidence.

### Hypothesis C: Cohort_map Is Separate

Accepted as a separate primitive shape, not as part of Eta-t59.

The keyed registry needs to own:

- key-to-pool lookup and creation
- eviction of empty cohorts
- optional shared budget across cohorts
- collapse of concurrent first arrivals for the same key

It does not need to reach into Pool's idle list or migrate live connections
between pools. That makes it separable.

Eta-t59 should implement one Eta.Pool.t. It should not embed keyed sharding. A
follow-up task records the future Eta.Cohort_map primitive.

## Scope Locked For Eta-t59

Eta-t59 should ship:

- same-domain generic Eta.Pool
- mutex LIFO idle storage
- conservative callback API
- effectful health check
- cancellation-safe wait protocol internal to Pool unless G2 reopens
- observability per G9

Eta-t59 should not ship:

- HTTP/2 multiplexer
- keyed Cohort_map registry
- cross-domain or portable-payload pool
- local-unique borrow API

## Downstream Notes

- Eta-cxs / H-D1: h2 uses single-cell multiplexer cache plus permit admission.
- Eta-qvi / H-D5: ALPN dispatch sends h1 to Eta.Pool; h2 goes to multiplexer
  cache.
- eta-sql planning can consume Eta.Pool for ordinary driver connection
  checkout. Driver portability remains Eta-s9u's job.

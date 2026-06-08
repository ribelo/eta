# Prior Art Mapping

This is a design mapping, not a source vendoring exercise. The local repo does
not contain these implementations, so the lab maps their settled public design
choices onto Eta primitives and then checks Eta with runnable probes.

| System | Settled pool choice | Eta mapping |
| --- | --- | --- |
| Caqti / caqti-eio | Bounded DB connection checkout/use/checkin. Older OCaml pool shapes commonly use mutex/condition or stream-like wait queues. | Resource is the wrong shape: this is N resources with checkout and health, not one cached last-good value. |
| undici Pool | Client-owned pool, warm reuse, pipelining/connection lifecycle hidden behind request APIs. | eta-http callers should not see Pool. Eta.Pool can still be the internal primitive consumed by eta-http. |
| hyper client pool | Internal connection reuse keyed by destination/protocol, with warm idle reuse and protocol-specific lifecycle hidden behind the request path. | Separate public request API from internal pool primitive. H-D5 still owns ALPN/bootstrap dispatch. |
| HikariCP | Strong lifecycle centralization: max pool size, max lifetime, idle timeout, health checks, leak detection/metrics. ConcurrentBag favors hot reuse over strict FIFO fairness. | Supports an Eta-owned primitive with stats and tracing hooks. Suggests LIFO/warm reuse is worth testing where fairness is not the key invariant. |
| pgbouncer | Pool semantics vary by mode: session/transaction/statement pooling differ materially. | Do not leak one pool abstraction into eta-http public API. Generic Eta.Pool should be a low-level resource primitive, not the HTTP request abstraction. |

## Mapping

- Warm reuse probably matters, but this lab did not prove LIFO is fastest or
  best. The Treiber probes only prove that the storage candidate compiles and
  preserves LIFO order.
- The module path Atomic.Portable is wrong. oxmono and the installed OxCaml
  libraries expose Portable.Atomic, including Atomic.Loc for atomic record
  fields. The lock-free LIFO story is a viable implementation path if Eta
  accepts using the portable package API directly, but it still needs
  contention, fairness, allocation, and warm-reuse comparison against
  mutex-protected list/queue and Eio.Stream-style FIFO.
- HTTP/1.1 connection pooling and HTTP/2 multiplexer caching should be internal
  eta-http consumers of a primitive, not public user-facing API.
- The wait queue and cancellation behavior are more important than the idle
  container algorithm. This is where the current Eta dogfood probe found the
  sharpest gap.

# Eta.Pool Observability Design

## Scope

This design settles the observability shape for Eta-t59. It does not implement
Pool.

The existing runtime capability seam is sufficient:

- Effect.named_kind / Effect.annotate for spans and attributes
- Effect.metric_update for metrics
- Effect.log for structured operational events

No new Eta-core capability is needed for Pool observability.

## Attributes

Use these attributes consistently on spans, metrics, and logs:

| Attribute | Meaning |
| --- | --- |
| eta.pool.name | Stable pool name supplied at creation. |
| eta.pool.kind | Caller supplied class, for example http.client or sql.client. |
| network.peer.address | Remote host when known. Aligns with HTTP/client semconv vocabulary. |
| network.peer.port | Remote port when known. |
| server.address | HTTP authority host when eta-http has semconv context. |
| server.port | HTTP authority port when eta-http has semconv context. |

Pool-owned attributes use the eta.pool.* prefix. HTTP semantic-convention
attributes stay with eta-http spans; Pool should not emit http.* or url.*.

## Metrics

| Name | Kind | Unit | Value | Notes |
| --- | --- | --- | --- | --- |
| eta.pool.active | Gauge | {connection} | current in-use count | Snapshot after acquire/release/open/close. |
| eta.pool.idle | Gauge | {connection} | current idle count | Snapshot after idle push/pop/evict. |
| eta.pool.waiting | Gauge | {waiter} | queued waiter count | Snapshot after queue/cancel/wakeup. |
| eta.pool.max_size | Gauge | {connection} | configured max size | Record at create and when stats are sampled. |
| eta.pool.opened | Counter_monotonic | {connection} | cumulative opened | Increment when factory succeeds. |
| eta.pool.closed | Counter_monotonic | {connection} | cumulative closed | Increment when close finalizer finishes. |
| eta.pool.health_rejected | Counter_monotonic | {connection} | cumulative rejected | Increment when health check fails. |
| eta.pool.cancelled_waiters | Counter_monotonic | {waiter} | cumulative cancelled | Increment when queued acquire is cancelled. |
| eta.pool.acquire_wait_ms | Counter_cumulative | ms | observed wait duration | Current meter has no histogram, so record samples until Eta gains histograms. |

The meter can express these today through Capabilities.meter#record.
Counter_cumulative is non-monotonic in Eta's current naming and can carry
duration samples until the eta-otel rebuild adds histogram support.

## Spans

Pool should open spans only around operations that may block or perform IO:

| Span | Kind | Status |
| --- | --- | --- |
| eta.pool.acquire | Internal | Ok on checkout, Cancelled on caller cancellation, Error on typed acquire failure. |
| eta.pool.health_check | Internal | Ok on accepted connection, Error on rejected connection. |
| eta.pool.close | Internal | Ok or Error based on close effect. |
| eta.pool.shutdown | Internal | Ok when drained, Cancelled/Error when interrupted or failed. |

release should usually be an event on the acquire span or a metric update, not a
separate span. It should become a span only if release can run user IO and block
materially.

## Logs

Use logs for sparse operational events, not hot-path state:

| Event body | Level | Trigger |
| --- | --- | --- |
| eta.pool.health_rejected | Debug | A connection fails health check. |
| eta.pool.waiter_cancelled | Debug | A queued acquire is cancelled. |
| eta.pool.shutdown_started | Info | Shutdown begins. |
| eta.pool.shutdown_timeout | Warn | Shutdown deadline expires. |
| eta.pool.close_failed | Warn | Closing a connection fails. |

Every log record carries the active trace/span ids through the runtime logger.

## Compatibility Checks

### Eta-5zo eta-otel rebuild

Eta-5zo wants a runtime-capability exporter with no raw Eio outside IO leaves.
This design uses only existing tracer/logger/meter capabilities, so eta-otel can
consume Pool signals without a new runtime service.

The only missing measurement shape is histogram/distribution. Eta-t59 should
record eta.pool.acquire_wait_ms as samples using the current meter and leave a
future eta-otel histogram task to improve aggregation, not block Pool.

### Eta-2s0 HTTP semantic conventions

Eta-2s0 owns HTTP client semconv. Pool metrics should remain eta.pool.* so they
do not collide with HTTP request metrics. eta-http may attach HTTP semconv
attributes such as server.address and server.port when it calls Pool, but Pool
itself should stay protocol-neutral.

Connection-pool stats mentioned by Eta-2s0 map directly to:

- eta.pool.active
- eta.pool.idle
- eta.pool.waiting
- eta.pool.opened
- eta.pool.closed
- eta.pool.health_rejected
- eta.pool.cancelled_waiters

## Verdict

Existing capabilities are sufficient. Do not add a Pool-specific observability
capability for Eta-t59.

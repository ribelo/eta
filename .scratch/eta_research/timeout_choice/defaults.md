# Initial eta-http Timeout Defaults

These are implementation defaults to validate in eta-http integration tests, not
universal protocol facts.

## Recommended starting policy

| Setting | Initial default | Reason |
| --- | ---: | --- |
| connect_timeout | 10s | Bounds DNS/TCP path without affecting established streams. |
| tls_handshake_timeout | 10s | Separate from connect because TLS can stall after TCP succeeds. |
| request_write_timeout | 30s | Bounds request headers/body upload stalls. |
| response_header_timeout | 30s | Bounds time-to-first-byte without constraining body size. |
| response_body_idle_timeout | 30s | Slowloris defense; any body chunk or SSE heartbeat resets it. |
| total_request_timeout | disabled by default for streaming APIs | A total deadline kills valid SSE and long downloads. Callers can enable it for bounded RPC-style requests. |
| pool_acquire_timeout | 30s | Prevents unbounded wait behind a saturated connection pool. |

## Rule

Never use total_request_timeout as the only safety control. For streaming
responses, response_body_idle_timeout is the safety control; total timeout is an
optional caller policy.

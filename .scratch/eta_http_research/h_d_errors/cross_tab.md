# H-D-Errors Cross-Tab

| Source outcome | H-D-Errors variant | Layer | Error class |
| --- | --- | --- | --- |
| Eta.Pool shutdown | Pool_shutdown | pool | pool_shutdown |
| Eta.Pool acquire timeout | Pool_acquire_timeout | pool | pool_acquire_timeout |
| H-D1 stream admission limit | Stream_admission_rejected | http_response | stream_admission_rejected |
| H-D1 socket/connection closed | Connection_closed | http_response | connection_closed |
| H-D1/Track B HPACK overflow | Hpack_decode_overflow | http_response | hpack_decode_overflow |
| H-D5 pending connection cancelled | Connection_closed | cancellation | connection_closed with cancellation layer |
| H-Q2 RST breaker | Rst_rate_exceeded | http_response | rst_rate_exceeded |
| H-Q5 ping flood | Ping_rate_exceeded | http_response | ping_rate_exceeded |
| H-Q5 WINDOW_UPDATE accounting | Connection_protocol_violation | http_response | connection_protocol_violation |
| H-Q5 SETTINGS churn | Settings_churn_rate_exceeded | http_response | settings_churn_rate_exceeded |
| H-Q2 response header churn | Response_header_change_rate_exceeded | http_response | response_header_change_rate_exceeded |
| H-Q5 header normalization | Header_invalid | http_response | header_invalid |
| H-Q3 CONTINUATION breaker | Continuation_flood | http_response | continuation_flood |

Connection_closed is intentionally a shared transport shape. The
low-cardinality class stays connection_closed; the layer distinguishes TCP,
HTTP response, and cancellation context without inventing one variant per call
site.

Decode_error remains the generic decode/corruption fallback. H-Q protocol
abuse and rate-limit rows use specific variants so retry policy, metrics, and
observability can distinguish peer misbehavior from replayable transient
corruption.

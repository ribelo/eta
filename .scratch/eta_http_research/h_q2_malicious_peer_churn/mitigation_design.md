# H-Q2 Mitigation Design

Public eta-http v1 config knobs from this lab:

```ocaml
type config = {
  max_concurrent_stream_attempts : int;
  max_rst_per_second_per_connection : int;
  max_ping_per_second : int;
  response_header_max_change_rate : int;
}
```

Semantics:

- `max_concurrent_stream_attempts` counts active plus recently cancelled stream attempts. This blocks HEADERS/RST churn and stream-id jumps from creating unbounded metadata.
- `max_rst_per_second_per_connection` trips a connection circuit breaker when a peer exceeds the configured RST_STREAM rate.
- `max_ping_per_second` trips a connection circuit breaker on PING floods. H-D-Errors has no ping-specific variant, so the v1 mapping is `Connection_closed { during = Http_response }` unless a future taxonomy adds `Ping_rate_exceeded`.
- `response_header_max_change_rate` bounds header churn between SETTINGS and maps to `Response_header_timeout` in this scratch proof.

Defense stance: drop and disconnect on threshold breach. H-Q2 does not require gracefully sustaining a malicious server indefinitely.

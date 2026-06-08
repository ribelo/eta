# H-Q2 Malicious Peer Churn

Question: do malicious HTTP/2 peer churn patterns plateau in memory/fiber/fd usage, clean up state after disconnect, and map to typed eta-http errors?

Public eta-http config knobs proved by the fixture:

```ocaml
type config = {
  max_concurrent_stream_attempts : int;
  max_rst_per_second_per_connection : int;
  max_ping_per_second : int;
  response_header_max_change_rate : int;
}
```

Defaults used by the lab:

- `max_concurrent_stream_attempts = 128`
- `max_rst_per_second_per_connection = 100`
- `max_ping_per_second = 100`
- `response_header_max_change_rate = 32`

Fixtures:

- HEADERS + RST_STREAM after every stream.
- GOAWAY mid-flight.
- PING flood at 1000/s.
- Header churn between SETTINGS.
- Stream-id jumps.
- RST_STREAM rate exceeding the configured limit.

The runner samples all six attacks over the same 30-second wall-clock window, once per second. It records `Gc.quick_stat().live_words`, `/proc/self/status` RSS, fixture-owned fiber count, and `/proc/self/fd` fd count.

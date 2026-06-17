# Hill-Climbing Prompt

Split the dominant H2C 1x16 `echo_1k` client segment:

- client writes request DATA `END_STREAM`
- client socket later reads response HEADERS bytes

Join client checkpoints with server trace by stream ID. Run one repeat per fresh
probe process so H2 stream IDs are unambiguous.

This hill should determine whether the remaining p99 gap is:

- request bytes waiting before server acceptance,
- server app/body/write work,
- server `Flow.write` completion to client-readable response HEADERS,
- client H2 parser/body callback work.

Do not optimize production server code in this hill.

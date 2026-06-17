# Hill-Climbing Prompt

Split the H2C 1x16 `echo_1k` request-body availability segment:

- `handler_started -> body_available`

Use trace-only instrumentation to distinguish:

- handler delay before first body read call,
- handler-to-owner command wait,
- waiting for request DATA,
- H2 body reader delivery after DATA/read are both ready,
- chunk copy/resolve/handler wake,
- second read/EOF roundtrip inside `Body.read_all`,
- post-EOF handler continuation.

Do not optimize server code in this hill. Use one fresh traced H2C probe per
repeat so stream IDs are unambiguous.

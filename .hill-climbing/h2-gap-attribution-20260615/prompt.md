# Hill-Climbing Prompt

Prove where the H2 plain `echo_1k` 1-connection / 16-stream p99 gap lives.

Do not optimize production server code for this hill. Build and run attribution
measurements that distinguish:

- client request scheduling / write completion,
- time until response HEADERS bytes are read by the client socket,
- H2 parser/demux callback overhead,
- response body completion after headers,
- benchmark-client-specific accounting artifacts.

Primary workload:

- H2C, plain TCP
- one connection
- 16 concurrent streams
- `POST /echo`
- 1024-byte request body
- 24,000 requests per repeat
- 9 repeats

The custom client records:

- `t0`: stream/request queued
- `t1`: outgoing DATA frame with `END_STREAM` written to the client socket
- `rx_headers`: client socket read returned bytes containing response HEADERS
- `t2`: H2 response headers callback ran
- `rx_body_end`: client socket read returned DATA `END_STREAM`
- `t3`: response body EOF callback ran

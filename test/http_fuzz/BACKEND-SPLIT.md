# Backend Split

`test/http_fuzz` is Crowbar fuzzing infrastructure. It is not an Alcotest
runtime-backend suite and is intentionally driven through opt-in aliases:
`@test/http_fuzz/fuzz-smoke` and `@test/http_fuzz/fuzz`.

The fuzz targets cover parser/codec/state-machine invariants:

- HTTP/1 response parsing span bounds.
- HTTP/1 request writer agreement across string, bytes, buffer, and Eio flow
  writers.
- WebSocket frame codec round trips and arbitrary-byte rejection behavior.
- HTTP/2 security/header/stream-state invariants.

The HTTP/1 flow-writer fuzz target links Eio because that public writer accepts
an `Eio.Flow.sink`. The other targets are codec/state-machine fuzzers. Shared
deterministic HTTP tests live in `test/http_common`; these fuzz executables stay
as domain-specific fuzz infrastructure.

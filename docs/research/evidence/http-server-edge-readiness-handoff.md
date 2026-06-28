# Eta HTTP Edge Readiness Handoff

Status date: 2026-06-12

## Goal

Make `eta_http` and `eta_http_eio` defensible as a directly Internet-facing,
general-purpose edge HTTP server.

The target state covers untrusted clients, HTTP/1.1, HTTP/2, HTTPS/TLS/ALPN,
slow-client and resource-exhaustion controls, adversarial tests, interop
evidence, operational defaults, and clear commit history.

## Current Repository State

- Branch: `master`.
- H2 response framing (previously WIP) is now finished, tested, and committed.
- Existing untracked artifacts remain outside this handoff:
  - `docs/big-picture/`
  - `docs/http-server-production-readiness-audit.md`
  - `porting-candidates.md`
- Commit command for this work should use:

```sh
git commit --no-gpg-sign -m "<subject>"
```

## Already Committed

| Commit | Subject | What changed |
| --- | --- | --- |
| `2ba507921` | `fix: require http11 transfer encoding` | Tightened HTTP/1.1 request framing behavior. |
| `ae3575261` | `fix: make h2 stream limit authoritative` | Made H2 max concurrent streams enforced by Eta instead of treating substrate behavior as enough. |
| `92b863272` | `fix: close pending tls handshakes on shutdown` | Shutdown now closes pending HTTPS/TLS handshakes instead of leaving them alive. |
| `6d5f296d4` | `fix: reject h2 connection-specific headers` | H2 request/response/trailer paths reject forbidden connection-specific fields; `te` accepts only `trailers`. |
| `e05757f82` | `fix: enforce h2 content length` | H2 request `content-length` syntax and body length are enforced; invalid values, duplicates, overflow, underflow, and body overflow are rejected. |
| `fix: own h2 response framing` | H2 response framing is owned by Eta: generated `content-length` for known-size responses, handler-supplied response `content-length` rejected as a 500 fallback, stream `length = Some n` enforced (reset on over/under), and bodies suppressed for `HEAD`/informational/`204`/`304` with ignored stream bodies released. |

## Verified Evidence So Far

The following checks passed after the committed H2 request content-length work:

```sh
nix --option eval-cache false develop -c dune exec test/http/run.exe -- test h2-server
nix --option eval-cache false develop -c dune runtest test/http --force
nix --option eval-cache false develop -c dune runtest test/http_eio --force
nix --option eval-cache false develop -c timeout 300s dune build eta_http.install eta_http_eio.install --display=short
timeout 120s nix --option eval-cache false develop -c dune exec http-testsuite/test/cve_regress/run.exe
git diff --check
```

Notes:

- H2 server group had 27 passing tests at that point.
- Full `test/http` had 182 passing tests at that point.
- Full `test/http_eio` had 142 passing tests at that point.
- `dune build @cve-regress --force` timed out once through the alias, while the direct CVE runner completed successfully.

Current counts after the handler-exception fix:

- H2 server group: 37 tests.
- Full `test/http`: 197 tests.
- Full `test/http_eio`: 142 tests.
- Interop: PASS 314, DIVERGENT 0, FAIL 0, SKIP 176.

## Fixed: Synchronous handler exceptions left clients with stream resets

Operational readiness bug fixed in `lib/http_eio/h1_server_connection.ml` and
`lib/http_eio/h2_server_connection.ml`:

- Symptom: `Eta.Runtime.run` catches exceptions raised *during* effect
  interpretation and converts them to `Exit.Error`, which the server turns into
  a 500 response. But `handler request` is evaluated *before* `Eta.Runtime.run`
  is called (to build the effect). A handler function that raised synchronously
  (`failwith`, match failure, etc.) therefore crashed the response fiber and
  left the client with an H2 stream reset or H1 connection error instead of a
  500. This is a real edge concern for Internet-facing servers where untrusted
  input can trigger unexpected failures in user-provided handlers.
- Fix: wrap the handler invocation (`Eta_http.Observability.Server.Tracer.request
  ... handler request`) in a try/with that converts non-cancellation exceptions
  into `Eta.Effect.fail (Handler_failed ...)`. Eio cancellation exceptions are
  re-raised so switch cancellation still propagates.
- Regression tests:
  - `test_h1_server_handler_exception_returns_500`
  - `test_h2c_server_handler_exception_returns_500`
  Both assert the 500 response and that the connection remains usable for a
  subsequent request.

## Fixed: H2 slow-read stream stall (response_write_timeout gap)

Edge-DoS fixed in `lib/http_eio/h2_server_connection.ml`:

- Symptom: an H2 client that keeps draining the socket but withholds stream
  `WINDOW_UPDATE` (advertises a small window and never reads the body) pinned a
  server stream open indefinitely. `response_write_timeout` only wrapped the
  socket write in `write_iovecs`, so it caught a client that stops reading the
  socket (write syscall blocks, like H1) but not a flow-control-blocked stream,
  where the pump parked in `await_owner` waiting for a flush that never
  completes. A few such streams could exhaust `max_concurrent_streams`.
- Fix: `await_owner_write` bounds the response-write commands
  (`Response_chunk` and trailing `Response_trailers`/`Response_close`) by
  `response_write_timeout`; on timeout the stalled stream is reset.
- Regression test: `test_h2c_server_resets_stalled_reader_stream` drives a
  client advertising a 16 KiB window that never reads, and asserts the server
  resets the stream.

## Completed: H2 Response Framing

H2 response framing is now owned by Eta in `lib/http_eio/h2_server_connection.ml`:

- Generated `content-length` for known-size responses (empty `0`, fixed exact
  byte length, stream with `length = Some n` -> `n`).
- Handler-supplied response `content-length` is rejected before headers are
  sent and falls back to a `500` response.
- Stream `length = Some n` is enforced while pumping: the stream is
  reset/failed if it sends more than `n` or ends before `n`.
- Bodies are suppressed for `HEAD`, informational, `204`, and `304` responses,
  and ignored stream bodies are released.

Tests live in `test/http/test_eta_http_h2_server.ml` (registered in
`test/http/run.ml`):

- `test_h2c_server_owns_response_framing` (generated content-length for
  fixed/known-stream, `HEAD`/`204`/`304` body suppression, ignored stream
  release).
- `test_h2c_server_rejects_handler_supplied_content_length` (`500` fallback).
- `test_h2c_server_resets_short_stream_response` (under-length reset).
- `test_h2c_server_resets_overflowing_stream_response` (over-length reset).
- `test_h2c_server_resets_stalled_reader_stream` (slow-read write timeout).
- `test_h2c_server_rejects_control_char_header_values` (HPACK header-value
  anti-injection invariant).
- `test_h2c_server_handler_exception_returns_500` (synchronous handler
  exception converted to 500, connection stays usable).
- `test_h2c_server_handler_timeout_returns_503`.

Evidence (all passing on this work):

```sh
nix --option eval-cache false develop -c dune exec test/http/run.exe -- test h2-server   # 37 tests
nix --option eval-cache false develop -c dune runtest test/http --force                  # 197 tests
nix --option eval-cache false develop -c dune runtest test/http_eio --force               # 142 tests
timeout 600s nix --option eval-cache false develop -c dune exec http-testsuite/test/interop/run.exe
timeout 180s nix --option eval-cache false develop -c dune exec http-testsuite/test/cve_regress/run.exe
nix --option eval-cache false develop -c timeout 300s dune build eta_http.install eta_http_eio.install --display=short
git diff --check
```

## Fixed: H2-over-TLS large-transfer deadlock

Directly Internet-facing edge defect found via the interop matrix and fixed in
`lib/http_eio/tls/tls_eio.ml`:

- Symptom: HTTPS H2 responses larger than the initial flow-control window
  stalled after the first 16 KiB DATA frame. Interop showed a 100 MB GET
  delivering only 16384 bytes and a 1 MB POST echo delivering 0 bytes; the
  interop runner hung indefinitely on the first large eta TLS transfer.
- Root cause: the TLS flow serialized every `single_read` and `single_write`
  under one coarse `io_mutex`. The H2 server reader fiber acquired `io_mutex`
  and parked inside `feed_bio` waiting for client bytes, while the owner fiber
  that needed to send the next response chunk blocked acquiring the same
  `io_mutex` -> full-duplex deadlock. Plain h2c never hit it (no shared
  read/write lock).
- Fix: removed `io_mutex`. The shared SSL object is already serialized per call
  by `ssl_mutex`, socket reads by `read_mutex` in `feed_bio`, and socket writes
  by `write_mutex` in `drain_bio`, so reads and writes proceed concurrently
  without corrupting OpenSSL or socket state.
- Regression tests: `test_h2c_server_streams_large_body_past_window`
  (plain h2c, 512 KiB) and
  `test_https_server_h2_streams_large_body_past_window` (HTTPS H2, 512 KiB).
- Verification: 25 TLS unit tests, 190 `test/http`, 142 `test/http_eio`,
  `@cve-regress`, and install builds all pass; the interop runner now
  completes instead of hanging.

## Audit Findings (verified this session)

- HTTP/1.1 parser is strict against request smuggling: obs-fold continuation
  lines, leading whitespace before header names, whitespace before the
  header-name colon, tabs inside header names, and bare CR / NUL in header
  values are all rejected (`400`, `protocol_errors = 1`, handler not called).
  Locked by `test_h1_server_connection_rejects_header_smuggling_vectors`
  (`test/http/test_eta_http_h1_server.ml`).
- `@cve-regress` (`http-testsuite/lib/adversarial.ml`) covers a broad
  adversarial set: rapid reset (CVE-2023-44487), continuation flood
  (CVE-2024-27919), hpack bomb, ping/settings/empty-frame floods, window-update
  accounting, H1 slowloris headers + slow body, invalid chunk, CL/TE smuggling,
  duplicate content-length, missing/duplicate/invalid host, invalid request
  target, absolute-form host conflict, header flood, oversized trailers, H2
  slow preface/headers/body timeouts, H2 invalid target, H2 missing authority,
  goaway churn. The interop "covered in @cve-regress" skip notes
  (`goaway_mid_flight`, `rst_stream_mid_flight`, `slow_body_timeout`) hold.
- Interop skips that remain are explicit v1 non-features, not edge blockers:
  103 Early Hints, gzip/deflate, explicit chunked POST, redirect cap, cookie
  scoping. Keep as policy.
- Operational defaults are edge-appropriate, not local-dev:
  - `Server.Config.default`: request line 8 KiB, headers 32 KiB / 256 count,
    request body cap 1 MiB, response headers 32 KiB / 256, trailers 8 KiB / 64;
    all six timeouts set (header/body/write/response-body 30s, idle 60s,
    handler 30s); unread body policy `Reset`.
  - `Eta_http_eio.Server.Config.default`: `max_connections = 1024`,
    `backlog = 128`, `read_buffer_size = 64 KiB`, H2
    `max_concurrent_streams = 128`, `tls_handshake_timeout = 10s`.
  - `h2_security_config = None` is safe: `H2.Security.create` applies
    `default_config` (settings 10, rst_stream 100, ping 100, hpack 256 KiB,
    continuation 64 KiB) when unset.

## Larger Remaining Work

### HTTP/1.1 Edge Behavior

- Done: smuggling vectors above are inspected and regression-locked. Duplicate
  / conflicting `content-length`, `transfer-encoding` combinations,
  absolute-form authority conflicts, and pipelined request boundaries already
  have server-level tests in `test/http/test_eta_http_h1_server.ml` and
  `@cve-regress`.
- Remaining: none known; keep H1 and H2 response ownership semantics aligned
  when either side changes.

### HTTP/2 Edge Behavior

- Covered by `@cve-regress`: header block size pressure (hpack bomb), DATA/
  empty-frame flooding, SETTINGS churn, stream reset churn (rapid reset),
  flow-control accounting (window_update_accounting), slow body timeout.
- Covered by `test/http`: per-stream/per-connection reset metrics
  (`reset_streams = 1` is asserted on a reset path in
  `test_eta_http_h2_server.ml`), slow-upload multiplexing across four
  concurrent streams (`test_h2c_server_multiplexes_slow_uploads`), slow-read
  write-timeout (`test_h2c_server_resets_stalled_reader_stream`), control-char
  header-value rejection
  (`test_h2c_server_rejects_control_char_header_values`), and handler
  exception/timeout paths (`test_h2c_server_handler_exception_returns_500`,
  `test_h2c_server_handler_timeout_returns_503`).
- Remaining: none known.

### HTTPS/TLS/ALPN

- Fully covered by the `tls` group in `test/http/test_eta_http_tls.ml`
  (24 tests, all passing):
  - TLS 1.3 default (`d53a32431`)
  - close-notify on shutdown (`e1db75c45`), pending-handshake close on
    shutdown (`92b863272`)
  - explicit ALPN protocol selection + server dispatch (h1/h2), end-to-end
    HTTPS H1 and H2 requests
  - strict SNI rejection and SNI cert selection
  - TLS session resumption
  - handshake-timeout enforcement (the TLS-slowloris defense)
  - startup rejection of invalid certificate/key material
- Remaining: none known.

### Resource Exhaustion

- Confirmed present and bounded (see Audit Findings). Tested via `@cve-regress`
  slowloris (H1 headers, H1/H2 slow body, H2 slow preface), the TLS
  handshake-timeout test, and the limit rejection tests.
- Remaining: none known.

### Operational Readiness

- Defaults reviewed (see Audit Findings) and judged edge-appropriate.
- Stats/metrics coverage is exercised by `test_eta_http_server_stats.ml` and the
  per-connection stats assertions in the H1/H2 server tests (active
  connections/streams, reset streams, protocol errors, request/response bytes,
  handshake outcomes, shutdown state).
- Handler exception/timeout paths are regression-locked for both H1 and H2
  (`test_h1_server_handler_exception_returns_500`,
  `test_h2c_server_handler_exception_returns_500`,
  `test_h2c_server_handler_timeout_returns_503`).
- Remaining: none known.

### Interop, CVE, Benchmark, Soak

- Run and inspect:

```sh
nix develop -c dune build @interop
nix develop -c dune build @cve-regress
nix develop -c bash bench/run.sh --quick
```

- Remaining: none known for the server. A fresh quick bench snapshot is at
  `bench/results/20260612T092938Z-a2e9ee6d9.json`. The interop runner now
  completes and is fully green: **PASS 314, DIVERGENT 0, FAIL 0** (176 cells
  are explicit v1-policy skips). The eta server passes every interop cell
  across nginx/caddy/eta x h1/h2 x plain/tls, including `static_100m`
  (100 MB) and `expect_100_continue_upload`.
  - Two issues found while closing interop were differential-harness bugs, not
    eta defects, and are fixed: `Util.body_to_string` read responses with the
    default 1 MiB `read_all` cap (raised to 128 MiB), and the curl `-D` parser
    counted interim `100 Continue` blocks (now dropped) which had pushed the
    final headers into the trailer slot.

## Suggested Next Tasks

The enumerated edge-readiness surface is covered and verified: H2 response
framing, H1 smuggling, H2 multiplexing (plain + concurrent large TLS), the
H2-over-TLS large-transfer deadlock fix, TLS/ALPN, resource-exhaustion limits,
operational defaults, and fully-green interop / CVE / bench evidence. No
concrete server-side task is currently open. Each deep adversarial pass so far
has surfaced a real defect (H2-over-TLS deadlock, H2 slow-read stream stall),
so further probing remains worthwhile. Covered regression locks now include
concurrent large bidirectional H2-over-TLS transfers and H1 keep-alive over
TLS.

## Follow-up verification (2026-06-12, continued session)

Additional fixes and regression coverage added during the final verification
pass:

- **Synchronous handler exceptions in streaming response bodies** were leaving
  H2 streams reset (and H1 connections dropped) instead of a typed 500. Fixed
  in `lib/http_eio/h2_server_connection.ml` and
  `lib/http_eio/h1_server_connection.ml` by wrapping the effect *thunk*
  (`fun () -> stream.read ()`) so exceptions raised while constructing the
  effect are caught and converted to a `Handler_failed` error, while Eio
  cancellation still propagates.
- **Regression test** `test_h2c_server_streaming_response_exception_resets_stream`
  added to `test/http/test_eta_http_h2_server.ml` and registered in
  `test/http/run.ml`. It asserts the stream is reset cleanly and the connection
  remains usable for a subsequent request.
- **Posix-backend H2-over-TLS stall fixed** in `lib/http_eio/server.ml`: accepted
  server TCP flows now set `TCP_NODELAY` before handing the socket to H1, h2c,
  or HTTPS handlers. This removes the posix-backend-specific H2-over-TLS
  deadlock caused by small TLS/H2 frame writes being delayed by Nagle's
  algorithm.

All handoff verification commands now pass with counts at least as good as
reported:

```sh
nix --option eval-cache false develop -c dune exec test/http/run.exe -- test h2-server   # 38 tests
nix --option eval-cache false develop -c dune runtest test/http --force                  # 198 tests
nix --option eval-cache false develop -c dune runtest test/http_eio --force               # 142 tests
timeout 600s nix --option eval-cache false develop -c dune exec http-testsuite/test/interop/run.exe   # PASS 314, DIVERGENT 0, FAIL 0, SKIP 176
timeout 180s nix --option eval-cache false develop -c dune exec http-testsuite/test/cve_regress/run.exe  # PASS 27, FAIL 0, SKIP 0
nix --option eval-cache false develop -c dune build eta_http.install eta_http_eio.install
nix --option eval-cache false develop -c bash bench/run.sh --quick
```

- `git diff --check` is clean.
- No concrete server-side edge-readiness task remains open.


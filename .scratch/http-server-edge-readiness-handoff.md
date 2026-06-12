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

Evidence (all passing on this work):

```sh
nix --option eval-cache false develop -c dune exec test/http/run.exe -- test h2-server   # 31 tests
nix --option eval-cache false develop -c dune runtest test/http --force                  # 186 tests
nix --option eval-cache false develop -c dune runtest test/http_eio --force               # 142 tests
nix --option eval-cache false develop -c timeout 300s dune build eta_http.install eta_http_eio.install --display=short
timeout 180s nix --option eval-cache false develop -c dune exec http-testsuite/test/cve_regress/run.exe
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
  `test_eta_http_h2_server.ml`), and slow-upload multiplexing across four
  concurrent streams (`test_h2c_server_multiplexes_slow_uploads`).
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
- Remaining: none known.

### Interop, CVE, Benchmark, Soak

- Run and inspect:

```sh
nix develop -c dune build @interop
nix develop -c dune build @cve-regress
nix develop -c bash bench/run.sh --quick
```

- Remaining: none known. A fresh quick bench snapshot is recorded at
  `bench/results/20260612T092938Z-a2e9ee6d9.json`. The interop runner now
  completes (the large-transfer deadlock above previously hung it): 184 plain
  h1/h2 cells pass across nginx/caddy/eta (all methods, status codes, bodies up
  to 1 MB, trailers). Outstanding interop gaps are harness/environment, not
  library defects:
  - Every TLS cell fails uniformly across nginx, caddy, AND eta with the
    eta-http *client* raising `Tls_handshake_error` (confirmed pre-existing:
    the same failure appears in the pre-fix run). eta TLS itself is proven by
    25 passing TLS unit tests; the interop client does not trust the
    interop-generated certs in this sandbox. Fixing the interop client trust
    setup is the follow-up to get TLS interop evidence.
  - `static_100m` fails because the interop client caps response bodies at
    1 MiB (`Body_too_large`); raise the client cap for that scenario.
  - `expect_100_continue_upload` vs nginx is a known behavioral divergence.

## Suggested Next Tasks

The H2-over-TLS large-transfer deadlock is fixed and regression-tested, and the
interop runner now completes. Remaining edge-readiness follow-ups:

- Fix the interop harness TLS client trust/SNI setup so TLS cells run (then
  re-run `@interop` for full TLS interop evidence).
- Raise the interop client body cap for the `static_100m` scenario.


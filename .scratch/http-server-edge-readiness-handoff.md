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

## Larger Remaining Work

### HTTP/1.1 Edge Behavior

- Re-run adversarial HTTP/1.1 cases after the H2 response framing commit.
- Inspect parser behavior for ambiguous request smuggling cases:
  - duplicate or conflicting `content-length`
  - `transfer-encoding` combinations
  - whitespace and obs-fold injection
  - absolute-form authority conflicts
  - pipelined request boundaries
- Keep H1 and H2 response ownership semantics aligned.

### HTTP/2 Edge Behavior

- Review H2 interop skips and convert missing coverage into tests or explicit policy.
- Add adversarial cases for:
  - header block size pressure
  - DATA frame flooding
  - SETTINGS churn
  - stream reset churn
  - slow upload multiplexing
  - flow-control stalls
- Check that per-stream and per-connection metrics remain correct on all reset paths.

### HTTPS/TLS/ALPN

- Confirm TLS defaults match edge-server expectations:
  - TLS 1.3 default
  - strict SNI behavior
  - ALPN dispatch for H1/H2
  - certificate/key validation at startup
  - session resumption behavior
  - graceful TLS close-notify behavior
- Add tests for certificate reload/lifecycle only if Eta owns that lifecycle.

### Resource Exhaustion

- Confirm hard limits exist and are tested for:
  - max request header bytes
  - max response header bytes
  - max trailer bytes
  - max request body bytes
  - max concurrent connections
  - max concurrent H2 streams
  - idle/request header/request body/response body/write/handler timeouts
- Add slowloris-style tests for H1, H2, and TLS handshake paths.

### Operational Readiness

- Review default `Server.Config` values as public-Internet defaults, not local-dev defaults.
- Confirm stats/metrics expose enough for:
  - active connections
  - active streams
  - reset streams
  - protocol errors
  - timeout classes
  - request/response bytes
  - shutdown state
- Add examples or tests for metrics callbacks where evidence is weak.

### Interop, CVE, Benchmark, Soak

- Run and inspect:

```sh
nix develop -c dune build @interop
nix develop -c dune build @cve-regress
nix develop -c bash bench/run.sh --quick
```

- Convert skips into one of:
  - passing coverage
  - explicit Eta edge-server policy
  - tracked missing work item with a failing/adversarial repro

## Suggested Next Tasks

The H2 response framing work is complete. Remaining edge-readiness work, in
rough priority order:

- Inspect `http-testsuite/` skips and produce a concrete list of missing edge cases.
- Run H1 adversarial cases and record exact failures.
- Review `Server.Config.default` against edge-server defaults.
- Run `bench/run.sh --quick` and save the result path.
- Continue with the next protocol gap from interop/CVE evidence.


# Red Probes Aggregate Findings

The opt-in red probes under `http-testsuite/test/red_probes/` are adversarial
diagnostics. They are not part of normal `dune runtest`.

Run all families:

```sh
nix --option eval-cache false develop -c dune build @red-probes
```

Run individual families:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_frames/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h2_flow/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/tls_frag/run.exe
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/handler_fail/run.exe
```

## Current Status

`@red-probes` completes. The remaining non-PASS probes are explicit policy
gaps:

- `h1_smuggle.bare_cr_request_line`: waits for the request-header timeout
  rather than immediately rejecting a bare CR request line.
- `h2_frames.goaway_lower_last_stream`: received GOAWAY closes without serving
  an already-open stream whose id is within the peer's `last_stream_id`.
- `h2_frames.headers_without_end_headers`: incomplete HEADERS followed by EOF
  closes without an explicit GOAWAY.

## Fixed Findings

The following original red findings now pass or have deterministic regression
coverage:

- H1 pipelining: two pipelined GETs, bodied POST + GET, chunked POST + GET,
  and `Content-Length` boundary cases complete without hanging.
- H1 handler failure/timeout: recovered handler errors return 500/503 and close
  the connection rather than reusing it for pipelined requests.
- H2 response failure handling: response body exceptions, trailer construction
  exceptions, and response-body cancellation produce stream resets instead of
  escaping or silently closing.
- H2 DATA after peer reset: late DATA on stream 1 is ignored as a closed-stream
  artifact and an unrelated valid stream 3 still receives a response.
- H2 flow-control stalls: the probes now configure a short response write
  timeout and observe bounded stream resets or flow-control errors.
- TLS/tiny-fragment delivery: H1/TLS, H2/TLS, and H2C byte-fragmented request
  bodies complete; the probes stop on response completion instead of waiting
  for keep-alive connection close.

## Latest Green Gates

Focused gates run during this hardening pass:

- `dune exec test/http/run.exe -- test h1-server --show-errors`
- `dune exec test/http/run.exe -- test h2-server --show-errors`
- `dune exec test/http/run.exe -- test tls --show-errors`
- `dune build @red-probes`

Broader gates should still be run before release:

- `dune runtest test/http --force`
- `dune runtest test/http_eio --force`
- `dune exec http-testsuite/test/interop/run.exe`
- `dune exec http-testsuite/test/cve_regress/run.exe`
- `dune build eta_http.install eta_http_eio.install`

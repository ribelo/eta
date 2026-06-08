# H-S0 Results

Status: PASS-WITH-CAVEAT / partial. The local matrix passes for several
HTTP/1.1 semantics, but H-S0 is not a clean substrate pass because trailers and
high-level client keep-alive are negative.

## Local Matrix

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s0_cohttp_eio_h1/h1_matrix.exe && timeout 10s dune exec scratch/eta_http_research/h_s0_cohttp_eio_h1/h1_matrix.exe'
```

Output:

```text
h_s0_keep_alive_server responses=2
h_s0_chunked_response transfer=chunked body=HelloWorld
h_s0_known_length_upload content_length=11 body=hello-known
h_s0_chunked_upload transfer=chunked body=hello-chunk
h_s0_head status=200 content_length=9 body_len=0
h_s0_early_response status=200 body=early unread_upload=true
h_s0_error_body status=500 body="error-detail"
h_s0_client_no_pool connect_calls=2 verdict=negative
h_s0_cancel_cleanup_smoke accepts_after_client_close=true
h_s0_trailers verdict=negative reason=cohttp_transfer_io_discards_trailers
```

## Interpretation

Positive evidence:

- cohttp-eio server handles two sequential requests on one HTTP/1.1
  keep-alive TCP connection.
- streaming response bodies are emitted with `transfer-encoding: chunked`.
- known-length request uploads are read and echoed by the handler.
- chunked request uploads are decoded and echoed by the handler.
- a HEAD route can produce headers with no response body when the handler
  explicitly returns an empty body and preserves `content-length`.
- early response before upload-body consumption works for a close-delimited
  request.
- cohttp-eio client exposes response bodies for non-2xx statuses, so
  body-capture-on-error is possible.
- a client-side early close of a streaming response does not wedge the server;
  a subsequent connection still succeeds. This is a smoke only, not fd/fiber
  baseline evidence.

Negative/caveated evidence:

- `Cohttp_eio.Client.get` through the high-level client opens a fresh
  connection per request. Eta-http would need its own HTTP/1.1 pool/connection
  reuse layer or a lower-level cohttp integration if keep-alive reuse is a
  product requirement.
- Trailers are not supported by cohttp's transfer layer. Source inspection
  shows `cohttp/transfer_io.ml` reads trailers with `junk_until_empty_line`,
  and request/response writers have `TODO Trailer header support` before
  writing `0\r\n\r\n`.
- HEAD semantics are handler-owned; cohttp-eio does not automatically suppress
  a body for HEAD if the handler writes one.

## H-S0 Verdict

H-S0 is PASS-WITH-CAVEAT / partial. eta-http can use cohttp-eio as positive
prior art for local h1 server/client behavior, but cannot rely on the
high-level cohttp-eio client for pooling or on cohttp transfer handling for
trailers. If this path remains in H-D, eta-http must own HTTP/1.1 pooling,
trailers, and HEAD enforcement. Stronger fd/fiber cancellation evidence is
covered by H-S4a rather than this H-S0 matrix.

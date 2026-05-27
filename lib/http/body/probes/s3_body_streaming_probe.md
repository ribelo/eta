# S3 Body Streaming Foundation Probe

Question: can eta-http add S3 body primitives without introducing `digestif`,
while keeping chunked bodies, gzip transduction, and release semantics visible
through the public body stream surface?

## Evidence

- `decompress.1.5.3` installs under the current `5.2.0+ox` switch with
  `checkseum` and `optint`; it does not depend on `digestif`.
- `Eta_http.Body.Stream.of_reader` releases exactly once on EOF, discard, or
  read failure.
- `Eta_http.Body.Chunked` decodes chunk extensions and response trailers.
- h1 response bodies now stream fixed-length, chunked, and close-delimited
  bodies through `Eta_http.Body.Stream` instead of the S1 eager buffer.
- h1 request bodies accept `Request.Eta_stream` and use chunked transfer coding
  when no length is known.
- `Eta_http.Body.Transducer.gzip_encode` and `gzip_decode` round-trip over
  streaming body chunks through `decompress`.
- gzip decode enforces the eta-http expansion cap and maps failures to a typed
  `Decode_error { codec = "gzip"; ... }`.
- h2 response bodies now expose a pull-driven `Eta_http.Body.Stream.t` through
  the public client path; EOF and discard release are verified against real
  `ocaml-h2` body readers.
- gzip decode rejects truncated streams and CRC mismatch, and decodes
  concatenated gzip members.
- `scratch/eta_http_v1/probes/s3_gzip_rss.ml` posts a 100 MiB gzip streaming
  request to a local h1 server and receives a 100 MiB gzip streaming response
  with RSS sampled from `/proc/self/status`.

Commands:

```sh
nix develop -c opam install --yes decompress.1.5.3
nix develop -c dune runtest lib/http --force
nix develop -c dune exec scratch/eta_http_v1/probes/s3_gzip_rss.exe
bash lib/http/audit/run.sh
```

Observed:

```text
eta-http: 54 tests passed
eta-http-security: 1 test passed
eta_http_s3_gzip_rss outcome=ok request_bytes=104857600 response_bytes=104857600 baseline_rss_kib=36580 max_rss_kib=50196 delta_rss_kib=13616 limit_kib=131072
Dependency sites: 269
Eta escape sites: 0
```

## Verdict

PASS for S3 closeout: the digestif workaround remains intact, `decompress`
compiles under OxCaml, h1 and h2 response bodies stream through
`Body.Stream`, streaming request bodies release their source, gzip has typed
malformed-stream fixtures plus an expansion-cap fixture, and the 100 MiB
gzip request/response smoke shows bounded RSS. R11's final retry-facing ADR
continues in S5, where retry/idempotency consumes the replayability classifier.

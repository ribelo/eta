# S4 Security Envelope Frame-Scanner Probe

> Historical probe note: commands below record original local probe runs; maintained verification now lives in `test/`, `http-testsuite/`, and package Dune gates.


## Question

Can eta-http enforce the first S4 byte-level HTTP/2 envelope checks at the real
ocaml-h2 adapter boundary before hostile frame shapes enter the substrate?

## Evidence

- `Eta_http_h2.Security.observe_result` scans raw server-to-client frame bytes in the
  h2 read adapter before calling `H2.Client_connection.read`.
- SETTINGS churn is detected through real `Multiplexer.read_client_once` and
  returns `Settings_count_exceeded`.
- Response-header churn returns `Response_header_count_exceeded`.
- Oversized single HEADERS blocks return `Hpack_decode_overflow`; this is the
  fallback for HPACK/Huffman CPU amplification while the pinned ocaml-h2 API
  lacks a per-symbol CPU-budget hook.
- HEADERS plus CONTINUATION accumulation over 64 KiB returns
  `Continuation_flood`.
- More than one GOAWAY returns `Connection_closed`.
- `validate_headers` rejects empty names, NULs, uppercase h2 names, and names
  over 8192 bytes, plus values over 65536 bytes; the public h2 client checks
  decoded response headers.
- `.scratch/eta_http_v1/probes/s4_envelope_alloc.ml` replays all six deferred
  byte-envelope rows against the real h2 read adapter and samples active-path
  minor allocations.

Commands:

```sh
nix develop -c dune runtest lib/http --force
nix develop -c dune exec --display=short .scratch/eta_http_v1/probes/s4_envelope_alloc.exe
nix develop -c dune exec .scratch/eta_http_v1/probes/honeycomb_h2.exe
nix develop -c dune exec .scratch/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta-http: 60 tests passed
eta-http-security: 1 test passed
eta_http_s4_envelope_alloc_summary verdict=PASS attacks=6 max_minor_words=63 limit_words=2260
eta_http_s2_honeycomb outcome=ok status=404 body_bytes=19 protocol=h2
eta_http_reach_summary verdict=PASS targets=13 failed=<none>
```

## Verdict

PASS for S4 byte-envelope closeout at the eta-http real h2 adapter boundary.

The accepted v1 GOAWAY posture is drop-and-disconnect with no retry. Selective
retry by received `last_stream_id` is not claimed because the pinned ocaml-h2
line does not expose it.

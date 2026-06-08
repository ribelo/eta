# H-S1 Results

## 2026-05-22 P0/P1 Setup

Status: PASS-WITH-CAVEAT. Production Stage 1 smoke and local Stage 2 matrix
pass, but pinned h2 does not expose graceful GOAWAY last-stream cutoff
semantics. Eta-http must own GOAWAY admission/cutoff tracking or patch/pivot
the h2 substrate.

### Dependency Availability

Command:

```sh
nix develop .#oxcaml -c opam install --yes --assume-depexts cohttp-eio tls-eio h2 ca-certs mirage-crypto-rng-eio x509 domain-name uri
```

Result:

- Installed enough for H-S0/H-S1 cleartext probes: `cohttp`, `cohttp-eio`,
  `h2`, `hpack`, `httpun-types`.
- Failed before TLS packages installed because `digestif.1.3.0` does not
  compile under `ocaml-variants.5.2.0+ox`.

Relevant error:

```text
Error: This expression has type
         "bytes @ local -> int -> bytes @ local -> int -> int -> unit"
       but an expression was expected of type
         "By.t @ local -> (int -> By.t -> int -> int -> unit)"
File "src-ocaml/baijiu_rmd160.ml", line 348, characters 15-22:
348 |     feed ~blit:By.blit ~le32_to_cpu:By.le32_to_cpu ctx buf off len
                     ^^^^^^^
```

Retrying without `ca-certs` still failed because `tls` and
`mirage-crypto-rng` require `digestif >= 1.2.0`.

Installed HTTP/2 packages after the partial install:

```text
cohttp
cohttp-eio
h2
hpack
httpun-types
```

Interpretation at the time: the latest TLS branch was blocked, not h2 itself.

Resolution branch: installing the older TLS stack succeeds under OxCaml:

```sh
nix develop .#oxcaml -c opam install --yes --assume-depexts tls-eio.0.17.5 mirage-crypto-rng-eio.0.11.3 x509.0.16.5 ca-certs
```

Installed/pinned for the TLS probes:

```text
ca-certs              0.2.3
mirage-crypto         0.11.3
mirage-crypto-rng     0.11.3
mirage-crypto-rng-eio 0.11.3
tls                   0.17.5
tls-eio               0.17.5
x509                  0.16.5
```

This downgraded `mirage-crypto` from 1.2.0 to 0.11.3, `eqaf` from 0.10 to
0.9, and `asn1-combinators` from 0.3.2 to 0.2.6 in the local research switch.
`eta-oxcaml-test-shipped` still passes after the downgrade. This unblocks
H-S1 Stage 1 and H-S2 local ALPN evidence, but it is not an H-S3 production TLS
verdict; exact-version security and maintenance suitability remain open.

### P1: In-Process h2 Sans-IO Pump

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s1_ocaml_h2_eio/p1_inprocess_matrix.exe && dune exec scratch/eta_http_research/h_s1_ocaml_h2_eio/p1_inprocess_matrix.exe'
```

Output:

```text
h_s1_p1_single_get status=200 body="hello-h2" server_seen=/single
```

Result: PASS for P1. `H2.Client_connection` and
`H2.Server_connection` can be pumped directly as sans-IO state machines for a
single GET without an `httpun` runtime adapter.

Adapter note: calling `yield_writer` repeatedly on every observed `Yield`
double-registers the h2 wakeup callback and fails with
`Failure("on_wakeup: only one callback can be registered at a time")`. The
real adapter must register exactly one wakeup and wait for it, or treat `Yield`
as quiescence in a synchronous pump.

### P2: Eio TCP Flow Smoke

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s1_ocaml_h2_eio/p2_eio_tcp_get.exe && timeout 10s dune exec scratch/eta_http_research/h_s1_ocaml_h2_eio/p2_eio_tcp_get.exe'
```

Output:

```text
h_s1_p2_eio_tcp_get status=200 body="eio-h2:/eio" port=35119
```

Result: PASS for P2. The harness drives h2 client/server sans-IO state
machines over a real localhost `Eio.Net` TCP connection and `Eio.Flow`
read/write calls. It does not import an `httpun` runtime adapter.

Copying note: this first Eio adapter copies between `Cstruct.t`, `string`,
and `Bigstringaf.t`. That is acceptable for P2 API-shape evidence but not for
the final eta-http hot path; later H-S1/H-D1 work must replace this with a
lower-copy bridge and record OxCaml allocation implications.

### Stage 1: nghttp2.org TLS h2 Smoke

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s1_ocaml_h2_eio/nghttp2_h2_smoke.exe && timeout 20s dune exec scratch/eta_http_research/h_s1_ocaml_h2_eio/nghttp2_h2_smoke.exe'
```

Output:

```text
h_s1_stage1_nghttp2 status=200 alpn=h2 version=tls13 body_len=6324
```

Result: PASS for the production Stage 1 smoke. The probe uses `tls-eio` with
CA validation from `ca-certs`, negotiates ALPN `h2` against `nghttp2.org`, then
drives `H2.Client_connection` directly over the TLS flow and receives an HTTP
200 response. It does not import an `httpun` runtime adapter.

### Repo Verification

Focused H-S1 lab commands above pass.

Shipped-package gate:

```sh
nix develop .#oxcaml -c eta-oxcaml-test-shipped
```

Result: PASS.

- `eta-schema` tests passed.
- `ppx_eta`: 2 tests passed.
- `eta-otel`: 26 tests passed.
- `eta-stream`: 17 tests passed.
- `eta`: 134 tests passed.

Root `nix develop .#oxcaml -c dune build` is blocked by pre-existing scratch
directories that still depend on the old `effet` / `ppx_effet` names
(`scratch/otlp_compare`, `scratch/cause_research`,
`scratch/schema_research`, etc.). That blocker is unrelated to this H-S1 lab.

### P3 Partial: Local Stage 2 Matrix

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s1_ocaml_h2_eio/stage2_matrix.exe && timeout 10s dune exec scratch/eta_http_research/h_s1_ocaml_h2_eio/stage2_matrix.exe'
```

Output:

```text
h_s1_stage2_concurrent_gets count=10 statuses=all-200
h_s1_stage2_post_body status=200 body="post:upload-body"
h_s1_stage2_trailers status=200 trailers=1
h_s1_stage2_server_rst error="protocol_error:INTERNAL_ERROR (0x2):"
h_s1_stage2_goaway_cutoff adapter_gate connection_error="protocol_error:INTERNAL_ERROR (0x2):Failure(\"stage2-goaway\")"
h_s1_stage2_flow_stall first_chunk_len=1024 peer_window=1024 control_status=200
h_s1_stage2_client_cancel first_chunk="slow-prefix" body_closed=true metadata=0 after_status=200
```

Result: PASS for seven Stage 2 rows/capabilities, with a GOAWAY caveat.

- 10 GET requests are opened before awaiting responses, so they are in flight
  on one h2 connection. All return status 200 with their expected response
  bodies.
- POST request body is sent as DATA and read by the server through
  `Reqd.request_body`; the server responds after request-body EOF.
- Response trailers are sent with `Reqd.respond_with_streaming` plus
  `Reqd.schedule_trailers` and observed by the client `trailers_handler`.
- Server RST_STREAM is triggered by starting a streaming response and then
  reporting an exception. The client's stream-level error handler observes
  `INTERNAL_ERROR` without a connection-level client error.
- Error GOAWAY is triggered with `Server_connection.report_exn`. The client's
  connection-level error handler observes `INTERNAL_ERROR`; an eta-http adapter
  can gate new requests once that handler fires, avoiding the late-request hang
  observed in the earlier naive probe.
- Stream-level flow-control stall is exercised by advertising a 1024-byte
  client receive window, starting a 64 KiB response, reading only the first
  1024-byte chunk, leaving that response body open, and then completing a
  control GET on a second stream within 0.5s. This proves the h2 scheduler and
  Eio writer loop do not deadlock a different stream behind one stalled
  stream. It does not separately force a connection-window or OS-socket stall.
- Client mid-body cancellation is modeled by closing the response
  `Body.Reader` after the first chunk of a streaming response. The fixture now
  asserts `Body.Reader.is_closed = true`, decrements an adapter-owned metadata
  counter back to zero, and completes a follow-up GET on the same h2
  connection, proving this cancellation path need not leak adapter metadata or
  corrupt the connection state.

Negative sub-probe: calling `Reqd.report_exn` before a response starts is not
an RST_STREAM fixture; h2 routes it through the server error handler and sends a
500 response body. The RST row must start a streaming response first.

Negative GOAWAY sub-probes:

- `Server_connection.shutdown` is not a GOAWAY fixture; it closes the h2 server
  reader/writer without sending GOAWAY.
- A late request submitted after GOAWAY hangs if the adapter ignores the
  connection error handler and only checks `Client_connection.is_closed`.
  Request admission must therefore be adapter-owned.
- Graceful `NO_ERROR` GOAWAY with precise `last_stream_id` cutoff is negative
  evidence for pinned h2. Source inspection shows
  `process_goaway_frame` ignores `last_stream_id` and routes GOAWAY through
  connection shutdown; the raw probe below confirms that h2 reports no stream
  error for an outstanding stream above the cutoff.

### P3 Diagnostic: Raw Graceful GOAWAY

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s1_ocaml_h2_eio/goaway_raw_probe.exe && dune exec scratch/eta_http_research/h_s1_ocaml_h2_eio/goaway_raw_probe.exe'
```

Output:

```text
h_s1_goaway_raw last_stream_id=1 stream_errors=0 connection_errors=0 closed_before_flush=false closed_after_flush=true writes_before=1 writes_after=1
```

Result: NEGATIVE for graceful cutoff semantics. The probe opens two client
streams, feeds an empty server SETTINGS frame, then feeds a raw GOAWAY frame
with `NO_ERROR` and `last_stream_id=1`. The client closes after flushing its
own GOAWAY, but neither the connection error handler nor the stream error
handler is called for the stream above the cutoff. Eta-http therefore cannot
rely on pinned h2 to classify or retry streams excluded by graceful GOAWAY.

Ownership split and current probe LOC are documented in
`ownership_split.md`.

### H-S1 Verdict

H-S1 is PASS-WITH-CAVEAT.

The positive rows prove ocaml-h2 sans-IO can be driven from Eio without an
httpun runtime adapter for production TLS h2 smoke, local concurrent GETs, POST
body, response trailers, server RST cleanup, stream-level flow-control stall,
and client cancellation cleanup.

The caveat is architectural: pinned h2 does not surface graceful NO_ERROR
GOAWAY last_stream_id cutoff semantics. Eta-http must own request admission and
cutoff tracking in its adapter, patch h2, or pivot substrate if that ownership
is unacceptable.

# Eta-http v1 — Master Objective

Status: Complete. S0 closed PASS on 2026-05-23. S1 closed PASS on
2026-05-23 with h1 OpenAI 401 smoke, origin-scoped pool wiring,
13-endpoint h1 reach, R1 zero-allocation parser core, R2 zero-allocation
writer core, R5 stale-idle rejection, and h1 body EOF/discard/pre-response
cancellation release passing. S2 closed PASS locally on 2026-05-23 with R7
ocaml-h2 API-shape evidence, ACTIVE+CANCELLED admission, ALPN state and public
dispatch, R8 push-disable/PRIORITY evidence, stream-state release decisions,
h2 writer/read adapters, H-D1 real-`ocaml-h2` stress rows, live Honeycomb h2
smoke, 13-endpoint auto-ALPN reach (11 h2 routes, 2 h1 fallbacks), GOAWAY
post-close admission cutoff, and ADR 0004. H-Q2/H-Q5 byte-envelope attack
reproduction remains S4, not an S2 blocker. S3 closed PASS on 2026-05-23:
`decompress.1.5.3` compiles under OxCaml without `digestif`, h1 chunked
responses/trailers stream, h1 request streams use chunked transfer coding,
h2 public response bodies stream through `Body.Stream`, gzip encode/decode
handles truncated streams, CRC mismatch, concatenated members, and the
expansion-cap security fixture, and the local 100 MiB gzip POST/response RSS
smoke passed with bounded RSS. Backlog epic
Eta-x48. S4 closed PASS locally on 2026-05-23: the real ocaml-h2 adapter has
a byte-level frame scanner for SETTINGS churn, response-header churn, GOAWAY
churn, HPACK block caps, CONTINUATION accumulation caps, and decoded h2 header
normalization; the six-row S4 allocation probe passed with max 63 minor words
against the 2260 words/frame envelope; defaults.md caveats were removed; ADR
0003 was promoted to Accepted; V-Http-Q2/V-Http-Q5 were updated with S4
accepted verdicts; live h2 and 13-endpoint reach still pass. Slices Eta-a45
(S0), Eta-8s7 (S1), Eta-du3 (S2), Eta-a0h (S3), Eta-qr9 (S4). S5 closed
PASS locally on 2026-05-23: `Http.Retry_policy.t`, explicit
`request_with_retry` wrappers, RFC 9110 idempotency classification,
`Idempotency-Key` opt-in, body replayability gating, `Retry-After`
delta/date parsing, schedule fallback backoff with full jitter, and ADR 0005
landed. S6 closed PASS locally on 2026-05-23: observability modules,
OTel HTTP client semconv request/response/error/retry attributes, retry
attempt spans, recursion suppression via `~enabled:false`, pool stats gauges
through `Eta.Capabilities.meter`, ADR 0006, and the H-O1 fixtures landed.
The h2 body recheck passed against Honeycomb with 19 response bytes, and the
13-endpoint reach probe still passes. Eta-8w6 CI scheduling is out of scope
per user direction and remains open.

This is the single source of truth for the eta-http v1 implementation.
Each slice task in the backlog points at the corresponding section here.
Read this document end-to-end before starting any slice.

---

## 0. Goal

Build eta-http v1 from scratch, in-tree, as a public package alongside
`eta`, `eta-stream`, `eta-test`, `eta-otel`, `eta-schema`. Production-shape
HTTP/1.1 + HTTP/2 client. Owned end-to-end except where a dependency is
genuinely irreplaceable (HPACK / h2 frame codec via `ocaml-h2`, TLS via the
ocaml-tls stack). Clean-room rewrite using evidence-based coding.

The capability proof is done. Phase H-S, H-D, and H-Q closed PASS or PARTIAL
with explicit reopeners. Eta primitives (`Pool`, `Channel`, `timeout_as`,
`Supervisor.scoped`, `Resource`, `Schedule`, `Tracer`, `Capabilities`) are
shipped. Twelve scratch labs settled the design questions. v1 ports the
proven designs and re-derives the unproven ones with embedded research probes.

---

## 1. Constraints

### 1.1 Clean-room

We do **not** copy code from `httpz`, `requests`, `piaf`, `cohttp-eio`, or
any other library. Read them for shape and ergonomic inspiration. Every
line of eta-http source is written by us, against the relevant RFC and
against the Eta primitive surface. No license attribution carries. Eta-http
ships under Eta's own license (MIT/ISC, whichever the project already uses).

### 1.2 Minimum deps

**Allowed**, with rationale:

- `ocaml-h2` — HTTP/2 frame codec + HPACK + Huffman. Not redoable in v1
  scope; security-sensitive; tracked CVEs; specialist work.
- `tls` 0.17.5 + `tls-eio` 0.17.5 — TLS substrate. Pinned per ADR 0002.
- `eio` + `eio_main` — same-domain runtime.
- `x509` 0.16.5 + `ca-certs` 0.2.3 + `mirage-crypto` 0.11.3 +
  `mirage-crypto-rng` 0.11.3 + `mirage-crypto-rng-eio` 0.11.3 +
  `eqaf` — TLS-stack transitives on the ADR 0002 pinned branch.
  `digestif` is intentionally not a direct eta-http dependency on this branch:
  the newer TLS line pulls it in, and `digestif` 1.3.0 is documented as
  failing to compile under the current OxCaml switch.
- `domain-name` + `ipaddr` — X.509 hostname matching, also useful in URL
  parsing. Boring, small, well-maintained.
- `bigstringaf` — bigstring buffer manipulation. Already a transitive of
  `ocaml-h2`; we use it directly for buffer ownership.
- `cstruct` — direct use of Eio's flow read buffer type in the S1 h1 read
  loop. Already in the Eta dependency closure through `eta-stream`/Eio.
- `decompress` — gzip codec for S3. Not yet a dep; lands in S3.
- `base` + `base_bigstring` + `stdlib_stable` + `stdlib_upstream_compatible`
  + `unboxed.int32_u` — OxCaml baseline shipped with the toolchain. Not a
  meaningful dep cost.

**Rejected**, with rationale:

- `cohttp-eio`, `cohttp` — we own h1.
- `piaf` — dead.
- `ocurl`, `ctypes` — libcurl FFI rejected by user fiat.
- `conpool` — we have `Eta.Pool`.
- `cookeio` — cookies deferred to v2.
- `uri` — write our own URL parser (small, contained, RFC 3986 minimal
  client subset).
- `jsont` — JSON not in eta-http core surface.
- `magic-mime` — MIME inference deferred; caller-provided Content-Type only.
- `cmdliner` — no CLI in the library.
- `xdge`, `base64`, `logs`, `ptime` — application-level conveniences. Use
  Eta tracer/clock/capabilities instead. Inline base64 if we need it for
  Basic auth (15 LOC).

If a slice surfaces a need to add a dep beyond this list, the experimenter
**stops and reports**. Adding deps is a planner decision, not an
implementation decision.

### 1.3 Evidence-based

- **Concrete work** (we have evidence): port from the named scratch lab.
  Re-derive the implementation in clean-room style, but the design
  questions are already settled.
- **Research probes** (uncertainty remains): build a small fixture inside
  the slice's lab subdir. State the hypothesis, the disproof signature,
  the proof obligation. Run the probe. Record the verdict. Then ship.
- **Stop conditions** (per slice): if a probe falsifies a load-bearing
  assumption, stop and report. Do not patch over.

Each slice carries both kinds of work. The split is documented per slice
below.

### 1.4 Audit from day one

Two ripgrep-reproducible audit catalogs are maintained continuously. The goal
is every relevant site visible, classified, and justified. The goal is not
zero sites forever.

**Dependency-usage audit** (`packages/eta-http/audit/dep_usage.md`):

- Per allowed dep: every call site (`rg "Ocaml_h2|Tls\.|Eio\.Net\.|..."`).
- Per site: what it does, whether replaceable, replacement cost.
- Updated with every PR.

**Eta-primitive-escape audit** (`packages/eta-http/audit/eta_escapes.md`):

- Every site reaching into raw `Eio.Fiber.fork`, `Eio.Switch.run`,
  `Eio.Promise.*`, `Eio.Mutex`, `Eio.Condition`, or `Atomic.t` (NOT
  `Atomic.Portable`) inside eta-http.
- Per site: classification (`Replaceable` / `Structural` / `Debt`) and a
  one-line reason. Structural sites with written justification are acceptable.
- IO leaves are substrate, not escapes: `Eio.Net.*`, `Eio.Flow.*`,
  `Eio.Buf_read.*`, `Eio.Buf_write.*`, `Eio.Time.*`, and `Eio.Path.*`.
  Eta does not own IO leaves; passthrough wrappers add ceremony without
  semantics.
- If 3+ `Replaceable` sites share the same pattern, file a backlog task to
  ship the Eta primitive that absorbs them. After that primitive lands, the
  audit re-scans and those sites should move to zero.
- Updated with every PR.

This is the Bun-unsafe-audit pattern. Speed is fine; speed without honest
accounting is not. The audit catalog is shipped alongside the code as a
living document. It is not a gate. It is the truth-of-record.

---

## 2. Reference posture

Three external corpora are read for design guidance only. **Do not copy
code.** Read for shape; write our own.

- `.reference/oxmono/avsm/httpz/core/` — MIT, Anil Madhavapeddy 2026.
  OxCaml-native zero-allocation h1 parser. Patterns: unboxed records
  (`#{...}`), `int16#` spans, threaded position, local lists, pre-allocated
  buffers, span-based parsing (offset+length into buffer, no string
  copies). Bench numbers: 6.5M req/s, 0 words/parse. Server-oriented
  (parses requests not responses). Read for technique; we re-derive for
  client-side response parsing.

- `.reference/oxmono/bleeding/requests/lib/` — ISC, Anil Madhavapeddy 2025.
  Eio-based HTTP/1.1 + HTTP/2 client. Read for client-lifecycle structure:
  request loop, body Stream integration, ALPN dispatch, h1+h2 unification,
  retry, redirect, expect-continue, timing. Uses `conpool`, `cookeio`,
  `uri`, `jsont` — all rejected by us. Read shape, port API ergonomics,
  rewrite implementation against Eta primitives.

- `.scratch/research/evidence/eta_http_research/` — our own corpus. Twelve labs. The proven
  designs in here are the canonical reference. Each slice below names
  the labs to port from.

---

## 3. Concrete vs research split

### 3.1 Concrete (port from scratch labs)

- **TLS config chokepoint** — port from `h_s3_enforce/default_config_builder.ml`
  + `invariants.ml`. Compile-fail invariants on `~version` and `~ciphers`.
  Six ECDHE-AEAD ciphers, TLS 1.2 only. ADR 0002.
- **Reach probe smoke** — port from `h_s3_reach/probe.ml`. 13 endpoints,
  ECDHE-AEAD policy.
- **Connection pool** — `Eta.Pool` already shipped.
- **Bounded channel** — `Eta.Channel` already shipped.
- **Timeout taxonomy** — `Effect.timeout_as` already shipped (Cause.Fail
  Timeout for caller deadline; Cause.Interrupt for cancellation of
  losers/children).
- **Error taxonomy** — port from `h_d_errors/error.{ml,mli}`. Variants
  including the V-Http-Q-Hardening expansion: `Connection_closed`,
  `Tls_handshake_error`, `Decode_error`, `Connection_protocol_violation`,
  `Hpack_decode_overflow`, `Continuation_flood`, `Stream_admission_rejected`,
  `Rst_rate_exceeded`, `Ping_rate_exceeded`,
  `Settings_churn_rate_exceeded`, `Response_header_change_rate_exceeded`,
  `Header_invalid`, `Response_body_idle_timeout`,
  `Response_header_timeout`. Plus context (uri, method), redaction list,
  pretty/JSON projections.
- **Redaction list** — `Authorization`, `Cookie`, `X-API-Key`,
  `Set-Cookie`, plus URL query strings, plus body omission by default.
- **Request/Response API shape** — port from `h_d2a_request_api/`. Caller
  doesn't branch on h1/h2; `Response.body : Stream.t`; idempotent release
  on EOF / discard / cancellation.
- **HTTP/2 multiplexer design** — port from `h_d1_dogfood_multiplex/`.
  Writer fiber owns socket; admission counter = ACTIVE+CANCELLED;
  `Channel.try_send` for outbound RST_STREAM intent and stream wake-up
  (never raw `Eio.Promise.resolve` from read loop); `Supervisor.scoped`
  for fiber lifecycle; per-stream state in `Atomic.Portable`; stream IDs
  `immutable_data int`.
- **ALPN dispatch state machine** — port from `h_d5_alpn_bootstrap/`.
  States: Connecting, TLS_handshaking, ALPN_resolved_h1,
  ALPN_resolved_h2; collapse redundant pending h2 connections; third
  arrival waits for in-flight ALPN.
- **HPACK + CONTINUATION caps** — port from `h_q3_hpack_continuation/`.
  256 KiB decoded HPACK cap (4× p99 inventory baseline); 64 KiB
  CONTINUATION accumulator cap (4× large-header baseline).
- **Drop-and-disconnect knobs** — port from `h_q_envelope/defaults.md`.
  All 14 knobs and their justifications.
- **Eta-primitive-escape audit pattern** — apply Phase H-Q hardening
  pattern from day one.

### 3.2 Research (probes during implementation)

Each is sized to fit inside the slice that needs it. Disproof signatures
named. If a probe falsifies, stop and report.

- **R1 — h1 response parser, OxCaml zero-alloc shape.** Hypothesis: a
  client-side response parser using unboxed `pstate`, `int16#` spans,
  threaded position, local lists, and a 32 KiB pre-allocated read buffer
  achieves zero-alloc on the steady-state path against a realistic
  response corpus. Disproof: parser cannot maintain zero-alloc; or
  unboxed records cannot represent the parser state given OxCaml current
  limitations; or the API forces heap allocation at the consumer
  boundary. Falsifier in `packages/eta-http/h1/` lab subdir. Probe
  before committing the parser shape. PASS in S1 for the caller-owned
  `parse_raw` core plus the 32 KiB h1 client read loop; the accepted
  implementation uses ordinary `int` offsets in caller-owned arrays because
  the OxCaml zero-allocation checker and runtime probe prove the allocation
  claim without unboxed span state. **Slice S1.**

- **R2 — h1 request writer, OxCaml zero-alloc shape.** Same disproof
  shape as R1, applied to writing. Probably easier (we control the
  inputs). PASS in S1 for the caller-owned byte-buffer writer core;
  `write_to_flow` crosses the Eio sink boundary. **Slice S1.**

- **R3 — URL parser, RFC 3986 minimal client subset.** Hypothesis:
  scheme + host + port + path + query + fragment can be parsed in
  ~500 LOC OxCaml clean-room, zero-alloc. Disproof: parser grows past
  ~3000 LOC, in which case we reconsider the `uri` dep with explicit
  ADR. **Slice S1.**

- **R4 — DNS resolution.** Hypothesis: `Eio.Net.getaddrinfo` is
  sufficient for v1; happy eyeballs (RFC 8305) is deferred to v1.x.
  Disproof: `getaddrinfo` blocks the whole runtime; or IPv4-only
  fallback misses real endpoints. Probe via the 13-endpoint reach
  smoke. **Slice S1.**

- **R5 — Pool health-check on h1 acquire.** Hypothesis: a safe
  liveness check for an idle h1 connection exists without sending
  application data. Disproof: no reliable mechanism; pool returns
  dead connections to caller. PASS in S1 for EOF/unexpected-data rejection
  and real loopback stale-idle replacement; post-health-check peer close
  remains handled at request time. **Slice S1.**

- **R6 — Body Stream<bytes> idempotent release.** Already proven in
  H-D2a against fake servers. Reverify against real h1 + real h2.
  Disproof: real connection lifecycle differs from the fake; release
  paths leak under realistic cancellation patterns. S1 h1 EOF/discard and
  pre-response cancellation are PASS. S1 bodies are still eager; S3 owns
  true streaming body cancellation when streaming bodies land. S2 owns h2
  stream-permit verification. **Slice S1 + S2.**

- **R7 — ocaml-h2 API integration shape.** Hypothesis: ocaml-h2's read
  loop, frame parser, HPACK decoder, and stream state machine compose
  cleanly with H-D1's writer-fiber-owns-socket pattern. Disproof:
  ocaml-h2 forces shapes incompatible with H-D1; or its stream state
  machine conflicts with our `Atomic.Portable` per-stream record. P1 API
  shape PASS in S2: direct Sans-IO client/server request, write-drain,
  read-feed, response callback, and body reader scheduling compile and run.
  S2 read-adapter cut also PASS: real client/server bytes flow through
  `Http.H2.Writer`, an Eio source split into 7-byte chunks, and
  `Http.H2.Multiplexer.read_client_once`, yielding status 200/body
  `hello-read`. The writer-loop wakeup bridge also PASSes with
  `Eta.Channel` under `Eta.Supervisor.scoped` teardown. Eta-http still owns
  the full real-socket owner-fiber lifecycle, public dispatch, GOAWAY
  admission, and typed error mapping. If this falsifies later, we either
  fork ocaml-h2 (large) or revisit the multiplexer design (medium).
  **Slice S2.**

- **R8 — Server push rejection + PRIORITY tolerance.** Hypothesis:
  SETTINGS_ENABLE_PUSH=0 in initial SETTINGS suffices; PUSH_PROMISE
  on receive treated as connection error per RFC 9113 §8.4; PRIORITY
  frames received are ignored without crash per RFC 9113 §5.3.2.
  Disproof: ocaml-h2 does not expose the hooks. PASS in S2:
  `h2_r8_push_priority.exe` proves no-push-handler clients advertise
  push disabled so server `Reqd.push` returns `Push_disabled`, forced
  PUSH_PROMISE against a disabled client reports `ProtocolError`, and
  well-formed PRIORITY frames are tolerated by client and server state
  machines. **Slice S2.**

- **R9 — Chunked encoding clean-room.** Hypothesis: RFC 9112 chunked
  encoding (writer + reader + trailers) implements in ~500 LOC OxCaml
  zero-alloc. Disproof: trailers semantics + Stream<bytes> integration
  forces unbounded buffering. **Slice S3.**

- **R10 — gzip transducer over Stream<bytes>.** Hypothesis: `decompress`
  encode/decode runs as a `Stream.t` transducer in constant memory
  regardless of body size; expansion cap aborts deterministically;
  truncated streams + CRC mismatch + concatenated members all surface
  as typed errors. Disproof: `decompress` demands full input upfront;
  or chunk boundaries break codec state. If positive: ship
  `Stream.transducer` as a public eta-stream primitive with
  V-Eta-StreamTransducer journal entry. **Slice S3.** (Closes Eta-eor
  H-D4a.)

- **R11 — Body retransmission for retry.** Hypothesis: a body-source
  surface that distinguishes (a) small in-memory buffer always
  replayable, (b) Stream<bytes> with caller-provided rewind hook
  replayable, (c) opaque Stream not replayable. Disproof: the
  three-way distinction confuses callers; or the rewind-hook protocol
  is unimplementable safely. **Slice S3 + S5.**

- **R12 — Decompression bomb mitigation.** Hypothesis: expansion cap +
  idle timeout + typed error variant (Decompression_bomb or
  Decode_error with codec='gzip') bounds bombs to default 256 MiB
  decoded. Disproof: cap enforcement requires re-architecting decompress
  consumer. **Slice S3 + S4.**

- **R13 — GOAWAY admission cutoff (RFC 9113 §6.8).** Deferred from
  Eta-yuk. Hypothesis: after GOAWAY mid-flight, streams above
  last_stream_id are not retried; client cleanly tears down.
  Disproof: ocaml-h2 doesn't expose last_stream_id on receive.
  S2 result: PASS for post-GOAWAY admission cutoff once `ocaml-h2` marks the
  client closed after writer drain; last-stream-id selective handling is not
  exposed by the substrate in this cut.
  S4 result: accepted v1 behavior is drop-and-disconnect with no retry; no
  selective retry by received `last_stream_id` is claimed. **Slice S2 + S4.**

- **R14 — SETTINGS rate limiting.** Deferred from Eta-yuk. Hypothesis:
  default `max_settings_per_second=10/sec` from defaults.md; storm
  triggers `Settings_churn_rate_exceeded`. Disproof: ocaml-h2 applies
  SETTINGS internally before we see them.
  S4 result: PASS for raw server-to-client frame observation before
  `ocaml-h2` ingestion, with >10 SETTINGS frames mapped to
  `Settings_churn_rate_exceeded`. **Slice S4.**

- **R15 — Huffman CPU amplification mitigation.** Deferred from Eta-yuk.
  Hypothesis: a CPU budget on HPACK decode bounds Huffman amplification.
  Disproof: ocaml-h2 doesn't expose Huffman decoding hooks for budget
  enforcement. If this falsifies, mitigate via decoded-byte cap from
  H-Q3 only and document the limit.
  S4 result: PASS for the fallback path; eta-http rejects
  single HEADERS blocks and HEADERS+CONTINUATION accumulations above the
  default caps before handing bytes to `ocaml-h2`. A per-symbol Huffman CPU
  budget is not exposed by the pinned substrate. **Slice S4.**

- **R16 — Header normalization edges.** Deferred from Eta-yuk. Very
  long names, embedded nulls, zero-length, mixed case. Hypothesis: each
  maps to `Header_invalid`. Disproof: ocaml-h2 already accepts edge
  cases that should be rejected.
  S4 result: PASS for eta-http's decoded-header policy; empty
  names, NULs, uppercase h2 names, and names over 8192 bytes map to
  `Header_invalid`; values over 65536 bytes also map to `Header_invalid`,
  and the public h2 client validates decoded response
  headers. **Slice S4.**

- **R17 — Real-world allocator-pressure invariant.** Reverify the 2260
  words/admitted-frame envelope against real ocaml-h2 + real malicious
  server (not the H-D1 scratch SUT). Disproof: real adapter allocates
  more than the synthetic.
  S4 result: PASS at the real h2 read-adapter boundary; the six deferred rows
  max at 63 minor words against the 2260 words/frame envelope. **Slice S4.**

- **R18 — Retry policy classifier surface.** H-D3a was never settled in
  scratch. Hypothesis: classifier of shape
  `(error, attempt, elapsed) -> Retry of Duration.t | Stop |
  Retry_with_new_connection` covers the H-D-Errors retryability
  classification cleanly; consumer can override per-request. Disproof:
  the surface forces non-idempotent retries by default, or its
  Retry-After integration is observably wrong. **Slice S5.**

- **R19 — Idempotency map.** Hypothesis: GET, HEAD, PUT, DELETE,
  OPTIONS, TRACE retryable per RFC 9110 §9.2.2; POST, PATCH not.
  Idempotency-Key header support per RFC draft (Stripe / industry
  practice). Disproof: real API behavior diverges from RFC defaults
  often enough that a static map misleads. **Slice S5.**

- **R20 — Backoff with full jitter.** Hypothesis: AWS-style exponential
  + full jitter (cap, base configurable) is enough for v1; defaults
  base=100ms cap=30s. Disproof: backoff math is observably wrong on a
  flaky test server. **Slice S5.**

- **R21 — OTel semconv attribute matrix (1.27.0).** Hypothesis: the
  attributes `http.request.method`, `url.full`, `server.address`,
  `server.port`, `network.protocol.name`, `network.protocol.version`,
  `http.response.status_code`, `error.type`, `http.request.body.size`,
  `http.response.body.size` all derive cleanly from the
  Request/Response/Error types. Disproof: derivation requires per-call
  bookkeeping that costs allocations. **Slice S6.**

- **R22 — Recursion avoidance for eta-otel consumer.** Hypothesis: a
  separate non-exporting tracer at the eta-otel boundary breaks the
  loop. Disproof: filtering at the boundary requires a tracer-API
  extension we haven't designed. **Slice S6.**

- **R23 — Metric emission for connection pool stats.** Hypothesis:
  pool active/idle/capacity surface through Eta.Capabilities.meter
  cleanly. Disproof: meter API forces high-cardinality attributes that
  observability tools choke on. **Slice S6.**

### 3.3 Out of scope for v1

- HTTP/3 / QUIC. Reserve API vocabulary for negotiated protocol.
- Public eta-http server (test fixtures only).
- HTTP/1.1 pipelining (one request per connection at a time within a pool slot).
- WebSocket upgrade. Reserve API extension point per RFC 8441.
- HTTP/2 server push: actively rejected via SETTINGS_ENABLE_PUSH=0; PUSH_PROMISE on receive treated as connection error.
- HTTP/2 PRIORITY honoring (deprecated by RFC 9113 §5.3.2; tolerate without crash).
- Connection coalescing across hostnames. Single-host-per-pool-key.
- Cookies (caller-managed via headers; auto-jar deferred to v2).
- Response decompression beyond gzip (brotli/zstd deferred).
- Response cache (Cache-Control parsing exists in error context only).
- HTTP authentication (Basic/Bearer/Digest deferred to caller; v1.1).

---

## 4. Slice plan

Each slice is independently shippable. Sequential dependencies named.
Each slice has its own README + smoke target + audit update.

### S0 — Skeleton + audit infrastructure (Eta-a45)

**Pure structural. No research.**

- Create `packages/eta-http/` with subdirs: `core/`, `h1/`, `h2/`,
  `transport/`, `client/`, `error/`, `tls/`, `body/`, `audit/`, `test/`.
- `dune-project` package stanza for eta-http.
- `eta-http.opam` with the §1.2 allowed-deps list.
- Empty `.ml`/`.mli` files with copyright headers and module documentation.
- Test harness scaffolding (alcotest + Test).
- Audit document templates: `audit/dep_usage.md` and `audit/eta_escapes.md`,
  each with the ripgrep command and an empty initial ledger.
- `audit/run.sh` — script that re-runs both ripgrep commands and updates
  the ledger headers (sites count, last-run timestamp).
- README.md skeleton with a public API table-of-contents (filled as slices land).

**Smoke**: `nix develop -c dune build packages/eta-http` succeeds.
`nix develop -c dune runtest packages/eta-http --force` passes (empty suite OK).
`bash packages/eta-http/audit/run.sh` runs and produces zero current sites
(empty package).

**Acceptance**: package skeleton lands with the audit infrastructure visible
from the first commit.

### S1 — h1 GET over TLS (Eta-8s7)

**Largest slice. ~50% concrete port, ~50% research probes.**

Concrete (port):
- TLS config chokepoint (port from h_s3_enforce).
- Reach probe smoke (port from h_s3_reach).
- Pool integration (`Eta.Pool`).
- Error taxonomy + projections + redaction (port from h_d_errors).
- Public Request.t / Response.t shape (port from h_d2a_request_api).

Research probes (run inside this slice's lab subdir):
- R1 (h1 response parser zero-alloc).
- R2 (h1 request writer zero-alloc).
- R3 (URL parser RFC 3986 client subset).
- R4 (DNS resolution).
- R5 (pool health check).
- R6 (body Stream idempotent release on real h1).

Modules: `core/url.{ml,mli}`, `core/method.{ml,mli}`, `core/version.{ml,mli}`,
`core/header.{ml,mli}`, `core/status.{ml,mli}`, `core/span.{ml,mli}`,
`tls/config.{ml,mli}` (chokepoint), `transport/connect.{ml,mli}` (TCP +
TLS + DNS), `h1/parse.{ml,mli}` (response parser),
`h1/write.{ml,mli}` (request writer), `h1/client.{ml,mli}` (request loop +
Pool wiring), `error/error.{ml,mli}`, `error/redaction.{ml,mli}`,
`error/projection.{ml,mli}`, `body/stream.{ml,mli}`,
`client/request.{ml,mli}`, `client/response.{ml,mli}`,
`client/client.{ml,mli}` (top-level public API).

**Smoke**: `GET https://api.openai.com/v1/models` without API key
returns `Response.t` with status=401, Authorization header redacted in
error projection, body Stream<bytes> readable, connection released
cleanly to pool. Reach probe: 13/13 endpoints succeed under the ADR 0002
cipher policy via h1 path.

**Acceptance**:
- All §S1 modules implemented.
- Public API: `Http.Client.t`, `Http.request`, `Http.Request.t`,
  `Http.Response.t`, `Http.Error.t`.
- Smoke target passes against real OpenAI (401).
- Reach probe passes 13/13.
- Audit catalogs updated with every external call site and Eta-escape
  classified.
- TLS chokepoint compile-fail tests under `packages/eta-http/test/tls/`.
- `eta-oxcaml-test-shipped` still passes.
- ADR 0002 verification appendix updated to point at the migrated
  chokepoint (closes Eta-l1o).
- Reach probe scriptable as a CI job (closes Eta-8w6 prep work).

### S2 — ALPN + h2 multiplexer on real ocaml-h2 (Eta-du3)

**Mostly concrete port from H-D1 + H-D5. Research where ocaml-h2 differs
from the scratch SUT.**

Concrete (port):
- Multiplexer (port from h_d1_dogfood_multiplex/multiplexer.ml).
- ALPN dispatch state machine (port from h_d5_alpn_bootstrap).
- HPACK + CONTINUATION caps (port from h_q3_hpack_continuation).
- H-Q2 + H-Q5 byte-envelope attacks are S4 security-envelope work; S2 records
  the h2 ownership boundary and GOAWAY cutoff evidence.

Research probes:
- R7 (ocaml-h2 API integration shape).
- R8 (server push rejection + PRIORITY tolerance).

Modules: `h2/frame.{ml,mli}` (thin wrapper over ocaml-h2 frame types
giving us `immutable_data` discipline), `h2/multiplexer.{ml,mli}`,
`h2/writer.{ml,mli}`, `h2/stream_state.{ml,mli}` (per-stream
`Atomic.Portable`), `h2/admission.{ml,mli}` (counter), `transport/alpn.{ml,mli}`
(state machine), `transport/dispatch.{ml,mli}` (h1-pool-or-h2-mux choice),
`h1/client.ml` extended for h1-from-ALPN-fallback path.

**Smoke**: `GET https://api.honeycomb.io/v1/auth` over h2; same caller
code as S1 with no h1/h2 branching in the smoke/reach probes. Multiplexer sustains 100 concurrent
requests against an `ocaml-h2`-based test server. S4 owns the H-Q2/H-Q5
malicious-server byte-envelope reproductions.

**Acceptance**:
- All §S2 modules implemented.
- Same caller code path across h1 and h2.
- 13-endpoint reach probe extended: each negotiates h2 if ALPN allows.
- H-Q2 + H-Q5 attack reproduction is explicitly deferred to S4 byte-level
  security envelope work.
- Audit catalogs updated; ocaml-h2 dep call sites enumerated.
- ADR 0004 (or amend 0003) drafts the h2 ownership boundary: which parts
  ocaml-h2 owns (frame parse, HPACK), which parts we own (multiplexer,
  admission, writer, stream lifecycle).

### S3 — Streaming bodies, chunked, gzip (Eta-a0h)

**~30% concrete (chunked from RFC), ~70% research (gzip transducer is open).**

Concrete:
- POST/PUT request with `Stream<bytes>` body.
- Body-length policy (Content-Length / chunked / connection-close).
- Trailers (port from h_d2a_request_api Response.trailers shape).

Research probes:
- R9 (chunked encoding clean-room).
- R10 (gzip transducer).
- R11 (body retransmission classifier).
- R12 (decompression bomb mitigation, partial; remainder in S4).

Modules: `body/chunked.{ml,mli}`, `body/source.{ml,mli}` (replayability
classifier), `body/transducer.{ml,mli}` (gzip), plus possibly
`packages/eta-stream/transducer.{ml,mli}` if R10 promotes the
abstraction.

**Smoke**: POST 100 MB gzip-compressed body to a test server; receive
100 MB gzip-compressed response; constant memory on both directions
(RSS samples, not just `live_words`). Bomb fixture: 10 KB encoded ->
10 GB decoded aborts at default 256 MiB expansion cap with typed error.

**Acceptance**:
- §S3 modules implemented.
- Stream<bytes> idempotent release on EOF / discard / cancellation
  re-verified against real h1 + real h2 streaming bodies.
- gzip transducer verified zero-alloc on RSS samples (not just `live_words`).
- Decompression bomb fixture under `packages/eta-http/test/security/`.
- If `Stream.transducer` ships in eta-stream: V-Eta-StreamTransducer
  journal entry + ADR.
- Audit catalogs updated; `decompress` dep call sites enumerated.
- Closes Eta-eor (H-D4a).

### S4 — Byte-level security envelope (Eta-qr9, closes Eta-yuk)

**Mostly research. The deferred half of the H-Q envelope.**

Concrete:
- Port the H-Q envelope monitoring harness onto real ocaml-h2.
- Port the active-path allocator-pressure metric.

Research probes:
- R13 (GOAWAY admission cutoff).
- R14 (SETTINGS rate limiting).
- R15 (Huffman CPU amplification).
- R16 (header normalization edges).
- R17 (real-world allocator-pressure invariant).
- R12 (decompression bomb completion, building on S3).
- GOAWAY churn rate enforcement.
- Header churn rate enforcement.

Modules: `h2/security/`. Per-attack fixtures under
`packages/eta-http/test/security/q_envelope/`.

**Smoke**: all 6 deferred attacks now exercisable against real ocaml-h2;
bounded resource use under each at default config; precise typed-error
variants from expanded taxonomy.

Closeout evidence:
- `Http.H2.Security.observe` scans raw server-to-client HTTP/2 frame bytes
  in the real h2 read adapter before `H2.Client_connection.read`.
- SETTINGS churn, response-header churn, GOAWAY churn, single HEADERS block
  cap, and HEADERS+CONTINUATION cap have focused real-adapter tests.
- `Http.H2.Security.validate_headers` rejects empty, NUL-containing,
  uppercase, overlong-name, and overlong-value h2 response headers; the public
  h2 client invokes it after `ocaml-h2` header decode.
- `.scratch/eta_http_v1/probes/s4_envelope_alloc.ml` replays all six
  deferred rows against the real h2 read adapter and samples active-path minor
  allocations; max observed is 63 words against the 2260-word envelope.
- Live h2 Honeycomb smoke and the 13-endpoint reach probe still pass after the
  scanner is inserted.

Caveats:
- The accepted GOAWAY policy is drop-and-disconnect with no retry. Selective
  retry by received `last_stream_id` is not claimed because the pinned
  `ocaml-h2` line does not expose it.
- Rate-shaped typed fields report burst counters at the adapter boundary in
  this v1 implementation. A future long-lived h2 connection pool may need
  wall-clock token-bucket accounting.

**Acceptance**:
- All 6 deferred attacks PASS against real ocaml-h2 adapter.
- defaults.md caveats removed ("Requires byte-level X hook before final
  enforcement" lines deleted).
- ADR 0003 promoted from Draft to Accepted.
- Closes Eta-yuk.
- V-Http-Q2 and V-Http-Q5 verdicts updated from "Accepted as partial" to
  "Accepted".
- Audit catalogs updated.

### S5 — Retry + idempotency (Eta-bvn)

**Mostly research; Schedule + error taxonomy are concrete substrate.**

Concrete:
- Backoff schedule via `Eta.Schedule`.
- H-D-Errors retryability classification fields (already on the type).

Research probes:
- R18 (retry policy classifier surface).
- R19 (idempotency map).
- R11 (body replayability — finalized here from S3).
- R20 (backoff with full jitter).

Modules: `client/retry.{ml,mli}`, `client/idempotency.{ml,mli}`.

**Smoke**: against a test server that fails 2/3 times then succeeds,
client retries 3 times with backoff, returns Response on attempt 3;
verify Retry-After header honored; non-idempotent failure not retried by
default but caller can opt in via `idempotency_key` or explicit
`retry_policy = Always`.

**Acceptance**:
- §S5 modules implemented.
- Public API: `Http.Retry_policy.t` with default + ergonomic
  constructors.
- Idempotency map documented with RFC 9110 §9.2.2 citations.
- Body replayability surface settled with ADR 0005.
- Smoke target passes.

Closeout evidence:
- `packages/eta-http/client/idempotency.ml` maps RFC 9110 idempotent
  methods and refuses one-shot request bodies.
- `packages/eta-http/client/retry.ml` provides default/always/never retry
  policies, `Retry-After` parsing, schedule fallback backoff, and explicit
  retry wrappers.
- `request_with_retry` retries a scripted 503/503/200 sequence on the third
  attempt and discards failed response bodies.
- POST is not retried by default; `Idempotency-Key` opts it in; one-shot
  streams are not retried even under `Retry_policy.always`.
- ADR 0005 records the body replayability decision.

### S6 — OTel HTTP client semconv (Eta-ef7, closes Eta-2s0)

**Mostly research; Tracer integration is concrete substrate.**

Research probes:
- R21 (semconv attribute matrix 1.27.0).
- R22 (recursion avoidance).
- R23 (pool stats metrics).

Modules: `observability/semconv.{ml,mli}`,
`observability/tracer.{ml,mli}`, `observability/meter.{ml,mli}`.

**Smoke**: in-memory tracer captures all 7 H-O1 scenarios (successful
GET, DNS error, TLS error, 500 with retry-success, redirect chain,
h2 request, eta-otel-using-eta-http with recursion avoided).

**Acceptance**:
- §S6 modules implemented.
- Public API: tracer/meter integration via `Eta.Capabilities`.
- All 7 H-O1 fixtures passing with semconv 1.27.0 attributes.
- Closes Eta-2s0 (H-O1).
- ADR 0006 records the recursion-avoidance pattern.

**Closeout 2026-05-23**: PASS locally. `Http.Observability.{Semconv,Tracer,Meter}`
is public, the in-memory tracer/meter fixtures pass, ADR 0006 is Accepted,
Honeycomb h2 returns 19 response bytes, and the 13-endpoint reach probe still
passes. Audit reports 283 dependency sites and 1 classified Structural escape
site. `eta-oxcaml-test-shipped` passes. `Eta-8w6` is not closed by S6;
scheduled CI wiring is out of scope.

---

## 5. Audit catalog format

### 5.1 dep_usage.md

```
# Dependency Usage Audit

Run: `bash packages/eta-http/audit/run.sh`
Last updated: <timestamp>

## ocaml-h2 (35 sites)

Search: `rg -tocaml '\bH2\.' packages/eta-http/`

| Site | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- |
| h2/multiplexer.ml:42 | H2.Frame.parse on read loop | structural | high (frame parser) |
| h2/multiplexer.ml:88 | H2.Hpack.decode on incoming HEADERS | structural | high (HPACK + Huffman) |
| ... | ... | ... | ... |

## tls (12 sites)

[similar table]

[etc per dep]
```

### 5.2 eta_escapes.md

```
# Eta-Primitive-Escape Audit

Run: `bash packages/eta-http/audit/run.sh`
Last updated: <timestamp>

Sites where eta-http reaches into raw Eio / Atomic.t (not Atomic.Portable) /
Mutex / Condition / Promise. Classified replaceable / structural / debt.

Search: `rg -tocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.\w+' packages/eta-http/ | rg -v 'Atomic\.Portable'`

## Replaceable (3 sites)

| Site | Pattern | Replacement |
| --- | --- | --- |
| transport/connect.ml:18 | Eio.Switch.run for handshake | wrap in Effect.acquire_release |
| ... | ... | ... |

## Structural (1 site)

| Site | Pattern | Why it stays |
| --- | --- | --- |
| transport/connect.ml:34 | Eio.Net.with_tcp_connect | IO leaf — Eta has no replacement |

## Debt (0 sites)

[anything we know is wrong-shaped but haven't fixed]
```

The catalogs are not gates. They are the truth-of-record. A PR may add
sites; the audit reflects them.

---

## 6. Per-slice ship gate

For each slice:

1. Smoke target passes.
2. Audit catalogs updated to reflect any new call sites.
3. `eta-oxcaml-test-shipped` still passes.
4. ADR amended where the slice settles policy.
5. Backlog task closed by planner with summary in close_reason.
6. Journal entry V-Http-S{N} appended at the bottom of journal.md.

The 13-endpoint reach probe runs at the end of each slice (it's a
universal smoke). Any endpoint failure at any slice reopens ADR 0002.

---

## 7. Stop conditions

Return to planner if any of these hold:

- An R-probe falsifies a load-bearing assumption (e.g., R10 says
  decompress can't stream, R7 says ocaml-h2's API is incompatible with
  H-D1's design).
- A slice surfaces a need to add a dep beyond §1.2.
- The TLS chokepoint cannot survive the migration from scratch into
  public API without breaking the compile-fail invariant (closes
  Eta-l1o blocked).
- An attack class in S4 cannot be bounded by configuration; requires
  structural change.
- An ocaml-h2 limitation prevents implementing a knob from
  `defaults.md` at the byte level. (Document and proceed with the
  caveat in ADR 0003.)
- The 13-endpoint reach probe regresses (was 13/13 in H-S3-Reach; if
  any slice causes a drop, stop).

---

## 8. Workflow

- Worktree: single `eta-http-v1` worktree (or master, planner's call).
  Slices share the package skeleton; sequential dependencies make
  parallel worktrees more friction than benefit.
- Per-slice flow: read the slice's backlog task and the corresponding
  §S{N} section here. Read the named scratch labs. Run probes for the
  research items. Implement the concrete items. Update audit catalogs.
  Run smoke target. Hand off.
- Backlog DB sync is a planner action. Experimenter closes via
  `.backlog/Eta-{slug}.md` notes; planner mirrors into the DB.
- Journal entries are the experimenter's responsibility (one per slice,
  same shape as V-Http-Q2 / V-Http-Q5 / V-Http-S3-Reach).
- ADRs are filed under `.scratch/research/evidence/eta_http_research/adrs/` until v1
  ships, then migrate into `packages/eta-http/docs/adrs/`.

---

## 9. Backlog mapping

| ID | Title | Slice |
| --- | --- | --- |
| Eta-x48 | eta-http v1 epic | — |
| Eta-a45 | S0 skeleton + audit | S0 |
| Eta-8s7 | S1 h1 GET over TLS | S1 |
| Eta-du3 | S2 ALPN + h2 multiplexer | S2 |
| Eta-a0h | S3 streaming bodies + gzip | S3 |
| Eta-qr9 | S4 byte-level security envelope | S4 |
| Eta-bvn | S5 retry + idempotency | S5 |
| Eta-ef7 | S6 OTel observability | S6 |
| Eta-yuk | byte-level h2 envelope (closed by S4) | reopener |
| Eta-l1o | TLS chokepoint migration (closed by S1) | reopener |
| Eta-8w6 | TLS reach probe in CI (out of scope; remains open) | reopener |
| Eta-eor | H-D4a gzip transducer (closed by S3) | reopener |
| Eta-2s0 | H-O1 OTel semconv (closed by S6) | reopener |

ADR set:
- ADR 0001 — TLS revocation policy (Accepted; from H-S3).
- ADR 0002 — TLS substrate pivot (Accepted with constraints; from H-S3).
- ADR 0003 — HTTP/2 security defaults (Draft; promoted by S4).
- ADR 0004 — h2 ownership boundary (Drafted by S2).
- ADR 0005 — Body replayability + retry classifier (Drafted by S5).
- ADR 0006 — Observability recursion avoidance (Accepted by S6).

---

## 10. What the experimenter should not do

- Copy code from httpz, requests, piaf, or any other external library.
- Add a dep beyond §1.2 without stopping and asking.
- Skip the audit catalogs.
- Mark a research probe DONE without running the falsifier.
- Promote ADR 0003 from Draft to Accepted before S4 closes.
- Ship a slice with the `eta-oxcaml-test-shipped` gate failing.
- Treat "PASS" against synthetic fixtures as proof of behavior against
  real endpoints. Reach-probe smoke is the universal real-endpoint check.
- Bury Eta extension work inside eta-http. If a slice surfaces a primitive
  gap (e.g., `Stream.transducer` from R10), ship the primitive in its
  proper Eta package with its own ADR + journal entry.

---

This document is the master objective. Update it as slices land. Do not
let it drift from the backlog. When in doubt, this file wins.

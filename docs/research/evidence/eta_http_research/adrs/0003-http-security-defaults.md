# ADR 0003: eta-http v1 HTTP/2 Security Defaults

Status: Accepted

Note: S4 moved the six byte-level deferred rows from the H-D1 scratch model to
the real ocaml-h2 adapter boundary. The accepted v1 posture is
drop-and-disconnect with typed errors, not sustaining malicious peers.

## Context

H-Q2 and H-Q5 test whether eta-http v1 can bound a fixed malicious-server
HTTP/2 catalogue. H-D1 provides the current scratch multiplexer SUT, H-D5
provides ALPN dispatch prior art, H-D2a provides the request API shape, and
H-D-Errors provides typed error mapping.

The original H-D1 frame model was not a byte-level HTTP/2 parser. It did not
represent GOAWAY, SETTINGS, HPACK/Huffman, or header names/values. S4 adds an
eta-http-owned raw-frame scanner before `ocaml-h2` ingestion and decoded-header
validation before public response exposure.

## Decision

eta-http v1 should expose explicit security defaults for malicious-server
bounding instead of relying on hidden library defaults.

Proposed defaults live in:

- `.scratch/eta_http_research/h_q_envelope/defaults.md`

The public API should expose the knobs as eta-http client configuration, not as
core Eta application state. Rate limiting is protocol policy at this layer.

## Evidence

Artifacts:

- `.scratch/eta_http_research/h_q_envelope/attack_runner.ml`
- `.scratch/eta_http_research/h_q_envelope/monitor.ml`
- `.scratch/eta_http_research/h_q_envelope/monitoring.csv`
- `.scratch/eta_http_research/h_q_envelope/results.md`
- `packages/eta-http/h2/security.ml`
- `packages/eta-http/h2/probes/s4_security_envelope_probe.md`
- `.scratch/eta_http_v1/probes/s4_envelope_alloc.ml`

The H-Q envelope runner sampled all catalogue rows at 1 Hz from second 0
through second 30. 6 of 12 catalogue attacks passed against H-D1.
H-D1-exercisable rows returned stream state to baseline, kept fd/fiber counts flat,
and mapped to precise H-D-Errors variants.

The allocator-pressure falsifier now samples Gc.minor_words on the active
path between attack start and breaker fire. The selected active-path rates
were 281.17, 153.84, and 98.43 words/admitted-frame against the 2260
words/frame envelope.

S4 exercises the six deferred byte-level rows at the real adapter boundary:
GOAWAY mid-flight/post-close admission, response header churn, SETTINGS churn,
GOAWAY churn, HPACK/Huffman fallback caps, and header normalization. The S4
allocation probe reports all six under the 2260 minor-words/frame envelope.

## Consequences

The implementation adds adapter-level fixtures before eta-http claims full
malicious-server HTTP/2 coverage. In particular:

- GOAWAY admission is enforced as drop-and-disconnect. The pinned `ocaml-h2`
  line does not surface received `last_stream_id`, so eta-http does not claim
  selective retry by last stream id in v1.
- SETTINGS churn is enforced before `ocaml-h2` receives the bytes.
- HPACK/Huffman uses encoded HEADERS and CONTINUATION caps before decode; the
  pinned substrate does not expose a per-symbol Huffman CPU-budget hook.
- Header normalization validates decoded names/values before the public
  response is exposed.

Drop-and-disconnect is an accepted defense. The defaults bound resource use
under attack; they do not promise to sustain malicious peers indefinitely.

H-D-Errors grew protocol-security variants instead of flattening H-Q rows into
Decode_error or Connection_closed:

- Connection_protocol_violation for WINDOW_UPDATE accounting abuse.
- Ping_rate_exceeded for PING floods.
- Settings_churn_rate_exceeded for SETTINGS churn.
- Response_header_change_rate_exceeded for response-header churn.
- Header_invalid for header normalization failures.

The retry-policy distinction is load-bearing: transient Decode_error remains
retryable if the request body is replayable, while protocol abuse and rate
violations are not retryable.

## Alternatives

Use ocaml-h2 defaults only:

- Rejected. The H-Q catalogue includes eta-http-visible policy decisions such
  as stream admission, timeouts, and typed error mapping.

Add a public Eta token-bucket primitive now:

- Deferred. The evidence shows eta-http needs rate policy, but not that core
  Eta needs a reusable public primitive yet. Keep the first implementation
  eta-http-internal unless three or more non-HTTP users need the same shape.

Treat deferred rows as pass:

- Rejected. Missing SUT capabilities are preserved as reopeners, not counted
  as byte-level coverage.

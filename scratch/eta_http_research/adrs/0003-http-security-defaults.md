# ADR 0003: eta-http v1 HTTP/2 Security Defaults

Status: Draft

## Context

H-Q2 and H-Q5 test whether eta-http v1 can bound a fixed malicious-server
HTTP/2 catalogue. H-D1 provides the current scratch multiplexer SUT, H-D5
provides ALPN dispatch prior art, H-D2a provides the request API shape, and
H-D-Errors provides typed error mapping.

The current H-D1 frame model is not a byte-level HTTP/2 parser. It does not
represent GOAWAY, SETTINGS, HPACK/Huffman, or header names/values.

## Decision

eta-http v1 should expose explicit security defaults for malicious-server
bounding instead of relying on hidden library defaults.

Proposed defaults live in:

- `scratch/eta_http_research/h_q_envelope/defaults.md`

The public API should expose the knobs as eta-http client configuration, not as
core Eta application state. Rate limiting is protocol policy at this layer.

## Evidence

Artifacts:

- `scratch/eta_http_research/h_q_envelope/attack_runner.ml`
- `scratch/eta_http_research/h_q_envelope/monitor.ml`
- `scratch/eta_http_research/h_q_envelope/monitoring.csv`
- `scratch/eta_http_research/h_q_envelope/results.md`

The H-Q envelope runner sampled all catalogue rows at 1 Hz from second 0
through second 30. H-D1-exercisable rows returned stream state to baseline,
kept fd/fiber counts flat, and mapped to H-D-Errors variants.

Rows requiring byte-level GOAWAY, SETTINGS, HPACK/Huffman, or header
normalization hooks are explicitly deferred with the missing capability named.

## Consequences

The implementation epic must add adapter-level fixtures before eta-http claims
full malicious-server HTTP/2 coverage. In particular:

- GOAWAY needs `last_stream_id` admission cutoff evidence.
- SETTINGS churn needs parser-level rate enforcement.
- HPACK/Huffman needs CPU and decoded-size evidence at the decoder boundary.
- Header normalization needs name/value validation evidence.

Drop-and-disconnect is an accepted defense. The defaults bound resource use
under attack; they do not promise to sustain malicious peers indefinitely.

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

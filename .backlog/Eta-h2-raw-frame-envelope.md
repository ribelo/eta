# Eta-h2-raw-frame-envelope

Status: closed

Task: promote the H-Q envelope deferred rows into byte-level ocaml-h2 adapter
fixtures.

Required hooks:

- GOAWAY with `last_stream_id` cutoff.
- SETTINGS_HEADER_TABLE_SIZE churn.
- HPACK/Huffman CPU amplification measurement.
- Header name/value normalization edge cases.
- H-D5 close/reopen GOAWAY churn accounting.

Reason: H-D1's scratch `Frame.t` does not represent these byte-level HTTP/2
features, so the current H-Q envelope records them as deferred instead of
claiming false coverage.

Closure: S4 (`Eta-qr9`) moved the deferred rows to the real eta-http h2
adapter boundary. `Eta_http.H2.Security.observe` scans raw server-to-client
frame bytes before `ocaml-h2` ingestion for SETTINGS churn, response-header
churn, GOAWAY churn, HPACK block caps, and CONTINUATION caps.
`Eta_http.H2.Security.validate_headers` rejects decoded header
normalization edges before public response exposure. The S4 allocation probe
reports all six rows below the 2260 minor-words/frame envelope.

GOAWAY `last_stream_id` selective retry is not claimed in v1 because the
pinned `ocaml-h2` line does not surface received `last_stream_id`; the
accepted policy is drop-and-disconnect with no retry.

# Eta-h2-raw-frame-envelope

Status: open

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

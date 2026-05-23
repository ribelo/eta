# H-Q1a State-Machine Properties

Question: can eta-http's adapter/state-machine invariants be tested without property-testing ocaml-h2's frame parser?

Scope:

- The lab uses a small QCheck-style seeded generator/shrinker because QCheck is not available in the current switch.
- The model drives H-D1 `Stream_state` for stream admission, RST cleanup, release, and baseline stats.
- GOAWAY, PUSH_PROMISE, PRIORITY, trailers, body exhaustion, pool arithmetic, and retry-classification behavior are modeled at the eta-http adapter layer.

Properties:

- a: permits return to baseline after cancellation/RST/release.
- b: no response body bytes are delivered after RST_STREAM.
- c: flow-control accounting never goes negative outside initial-window-change semantics, which this model does not generate.
- d: trailers are delivered only after body END_STREAM.
- e: GOAWAY prevents new streams above `last_stream_id`.
- f: response body EOF is observed exactly once.
- g: retry decisions match the H-D-Errors retryability classifier for the same outcome inputs.
- h: pool stats remain arithmetically consistent (`active + idle <= capacity`).
- i: server push is rejected. RFC 9113 section 8.4: after `SETTINGS_ENABLE_PUSH=0`, `PUSH_PROMISE` is a connection error.
- j: PRIORITY is accepted and ignored. RFC 9113 section 5.3.2 deprecates priority signaling.

Every property records a deterministic seed, trial count, coverage counter, and shrunk failure case. The passing run has `SHRINK none` for all properties.

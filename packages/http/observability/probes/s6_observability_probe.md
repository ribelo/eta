# S6 Observability Probe

Question: can eta-http emit OTel HTTP client semantic-convention attributes
through Eta tracer/meter capabilities without recursively tracing exporter
traffic?

Status: PASS locally.

Artifacts:

- `packages/eta-http/observability/semconv.ml`
- `packages/eta-http/observability/tracer.ml`
- `packages/eta-http/observability/meter.ml`
- `packages/eta-http/test/test_eta_http.ml`
- `scratch/eta_http_research/adrs/0006-http-observability-recursion.md`

Evidence:

~~~text
nix develop -c dune exec --display=short packages/eta-http/test/test_eta_http.exe
eta-http: 75 tests passed

observability / successful GET semconv: PASS
observability / DNS error semconv: PASS
observability / TLS error semconv: PASS
observability / retry success spans: PASS
observability / redirect semconv: PASS
observability / h2 protocol attrs: PASS
observability / recursion disabled: PASS
observability / pool stats meter: PASS
~~~

Live h2 body recheck:

~~~text
timeout 25s nix develop -c dune exec --display=short scratch/eta_http_v1/probes/honeycomb_h2.exe
eta_http_s2_honeycomb outcome=ok status=404 body_bytes=19 protocol=h2 policy=tls12_ecdhe_aead_only
~~~

Final gates:

~~~text
bash packages/eta-http/audit/run.sh
Dependency sites: 283
Eta escape sites: 1

nix develop -c eta-oxcaml-test-shipped
PASS
~~~

The single escape site is classified Structural in
`packages/eta-http/audit/eta_escapes.md`: the observability meter test creates
an in-memory metered runtime with `Eio.Switch.run` because `eta-test` does not
yet expose a meter-capable fixture helper.

The Honeycomb probe timeout wraps request, body read, and stats collection.
The h2 multiplexer suite also includes `body stream reads inline data`, which
feeds headers, DATA, and END_STREAM before the caller starts reading the Eta
body stream.

Verdicts:

- Request, response, error, retry, redirect, and protocol attributes derive
  from eta-http request/response/error values without adding an OTel SDK
  dependency.
- `~enabled:false` suppresses eta-http client spans for exporter-owned calls.
- Pool/client stats use gauge metrics through `Eta.Capabilities.meter`.

Residual risk:

- Redirect support is represented as semantic-convention attribute derivation
  in v1, not as an automatic redirect-following client.
- Trace-context injection into outbound headers is deferred to a propagation
  boundary owned by the caller or a future transport wrapper.

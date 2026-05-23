# H-O1 Results

Verdict: PASS.

eta-http can map its client observability to OTel HTTP client semconv while keeping eta-otel transport spans out of the export loop.

## Evidence

```text
nix develop -c bash -lc 'dune exec scratch/eta_http_research/h_o1_observability/fixtures.exe && dune exec scratch/eta_http_research/h_o1_observability/recursion_test.exe'
PASS successful GET returns 200
PASS successful GET has one client span
PASS successful GET semconv attrs
PASS W3C trace context injected from active client span
PASS successful GET emits HTTP metrics
PASS connect error marks span error
PASS connect error emits log
PASS TLS certificate error attrs
PASS TLS handshake error attrs
PASS TLS errors emit logs
PASS HTTP 500 retry succeeds on attempt 2
PASS retry parent and child spans
PASS first retry child records 500 error
PASS retry decision logged
PASS redirect chain lands on 200
PASS redirect child spans carry 301 and 200
PASS redirect event logged
PASS h2 request returns 200
PASS h2 semconv protocol differs from h1
h_o1_observability fixtures passed (semconv v1.56.0)
PASS unsuppressed eta-http transport spans recurse
PASS eta-otel transport filter reaches quiet state
filtered recursion quiet after 1 round(s), spans=1
h_o1 recursion_test passed
```

## Scenario Coverage

| Scenario | Evidence |
| --- | --- |
| Successful GET | One client span, semconv attrs, W3C injection, HTTP metrics. |
| DNS/connect error | Error span with `error.type=connect_timeout` and structured log. |
| TLS error | Certificate and handshake variants both produce error spans and TLS logs. |
| HTTP 500 retry | Parent span plus retry child spans; first child records 500/error, second succeeds. |
| Redirect 301 to 200 | Parent span plus redirect child spans with 301 and 200 status attrs. |
| h2 request | `network.protocol.version=2` distinguishes the protocol. |
| eta-otel using eta-http | Unsuppressed transport spans recurse; filtered transport reaches quiet state with one application span. |

## Decisions

- Use OTel HTTP client semconv `v1.56.0` keys: `http.request.method`, `url.full`, `server.address`, `server.port`, `network.protocol.name`, `network.protocol.version`, `http.response.status_code`, `http.request.resend_count`, and `error.type`.
- Inject W3C propagation headers from the active client span via `Trace_context.inject`.
- Model retry and redirect attempts as child client spans. The parent summarizes the final outcome and resend count.
- Suppress eta-http client spans when the caller marks the request as eta-otel transport. This avoids recursive export while leaving metrics/logs available.

## Follow-Up

- Eta's meter needs a histogram kind before production eta-http can emit `http.client.request.duration` with the preferred OTel instrument shape. The scratch lab records it as a gauge and documents the gap explicitly.

## S6 Package Promotion Note

S6 promoted the stable subset into `packages/eta-http/observability/` rather
than copying the full scratch stub. The package implementation includes client
spans, retry attempt spans, response/error attributes, h2 protocol attributes,
recursion suppression through `~enabled:false`, and pool/client gauges.

The scratch lab also modeled W3C header injection, structured retry/redirect
logs, request/response size metrics, and automatic redirect child spans. Those
remain future work for the package because v1 does not own a redirect-following
client or outbound propagation wrapper.

# R-T3 Exporter On Eta-Http Verdict

Date: 2026-05-23

Status: initial transport verdict accepted. The eta-http OTLP/JSON POST path
works against a real OpenTelemetry Collector, and the recursion seam now
suppresses lower Eta observability internals. This is not yet the full OS3
exporter implementation.

## Question

Can the eta-otel rebuild send OTLP/HTTP JSON traces through eta-http v1 to a
real collector, and can exporter-owned eta-http calls avoid recursively
observing their own transport path?

The proof obligations for this probe are:

- run a real OpenTelemetry Collector receiver;
- send 1000 spans over OTLP/HTTP JSON through eta-http;
- verify collector ingest, not just client-side success;
- exercise the eta-http observability recursion boundary;
- preserve the objective's direction: eta-otel consumes eta-http, not raw Eio
  HTTP.

## Fixtures

- bench/r_t3_exporter_on_eta_http/r_t3_eta_http_otlp.ml
- scratch/eta_otel_v2/r_t3_exporter_on_eta_http/run.sh
- scratch/eta_otel_v2/r_t3_exporter_on_eta_http/docker-compose.yml
- scratch/eta_otel_v2/r_t3_exporter_on_eta_http/otelcol-config.yaml

The OCaml executable lives under bench/ because the root Dune file treats
scratch/ as data-only. The research runner and collector config live under
scratch/.

The runner prefers docker-compose when the Docker daemon is available. On this
host Docker is installed but the daemon is inactive, so the successful proof
used the same collector config with nix run nixpkgs#opentelemetry-collector-
contrib.

Docker daemon evidence:

~~~text
docker info
failed to connect to the docker API at unix:///var/run/docker.sock

systemctl is-active docker
inactive
~~~

Collector fallback evidence:

~~~text
nix run nixpkgs#opentelemetry-collector-contrib -- --version
otelcol-contrib version 0.124.0
~~~

## Disconfirming Evidence Found

The first strengthened recursion run failed:

~~~text
r_t3_eta_http_otlp unexpected_spans=eta.pool.health_check, eta.pool.acquire
exit 3
~~~

That proved eta-http enabled:false only disabled the HTTP wrapper span. Lower
Eta.Pool spans still emitted under an instrumented runtime, so ADR 0006 was not
strong enough for an eta-otel exporter using eta-http.

The fix is in Eta, not hidden inside eta-otel:

- Eta.Effect.suppress_observability disables tracer, logger, meter, and
  auto-instrumentation for a subtree.
- Http.Observability.Tracer.request and request_with_retry wrap disabled
  calls in suppress_observability.
- eta-http regression coverage now proves enabled:false suppresses an inner
  named span as well as the wrapper span.

## Evidence After Fix

Build:

~~~text
nix develop -c dune build bench/r_t3_exporter_on_eta_http/r_t3_eta_http_otlp.exe
exit 0
~~~

Focused tests:

~~~text
nix develop -c dune runtest packages/eta --force
exit 0
eta: 186 tests passed

nix develop -c dune runtest packages/eta-http --force
exit 0
eta-http: 77 tests passed
eta-http-security: 1 test passed
~~~

Collector proof:

~~~text
bash scratch/eta_otel_v2/r_t3_exporter_on_eta_http/run.sh
exit 0
r_t3_eta_http_otlp status=200 spans=1000 body_bytes=21 eta_http_spans=0
r_t3_collector_ingest spans=1000 bytes=362116
~~~

## Verdict

Use eta-http for the eta-otel OTLP/HTTP JSON exporter.

R-T3 proves a single traces request can be encoded with the current eta-otel
OTLP/JSON encoder, sent through eta-http, accepted by a real collector, and
written by the collector file exporter with all 1000 span names present.

The recursion contract must be stronger than the original ADR 0006 wording:
eta-http enabled:false means the whole eta-http request subtree is unobserved,
not merely that the top-level HTTP semantic-convention span is skipped. This
contract is now backed by Eta.Effect.suppress_observability.

## Consequences For OS3

- The exporter should call Http.Observability.Tracer.request_with_retry
  with enabled:false, not bare Http.request, so the recursion policy is
  visible at the call site.
- The exporter should use Retry_policy.always with the OTLP retry status set
  429, 502, 503, and 504. The request body must be replayable.
- OS3 still needs package code that wires batching, flush, shutdown, retries,
  partial-success handling, logs, and metrics through the new transport path.
  R-T3 is a transport and recursion proof, not a replacement for OS3 tests.

## Counterevidence and Open Work

- The docker-compose fixture is present but was not executed on this host
  because Docker daemon access is unavailable. The real collector proof used
  the Nix collector fallback.
- This probe covers traces only. Logs and metrics still need OS3 fixtures.
- This probe uses the current eta-otel Internal encoder and a direct one-shot
  POST. It does not prove the final clean-room package shape.
- It does not exercise OTLP partial success, 400 no-retry, 408 no-retry, or
  429 retry against the collector. Those remain OS3 tests.

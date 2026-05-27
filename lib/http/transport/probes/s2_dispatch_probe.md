# S2 dispatch + live h2 smoke probe

Question: can the public eta-http client use one caller path, negotiate ALPN,
route h2 to the real `ocaml-h2` owner loop, and keep h1 fallback working?

## Artifacts

- `lib/http/client/client.ml`
- `lib/http/transport/dispatch.ml`
- `lib/http/transport/connect.ml`
- `scratch/eta_http_v1/probes/honeycomb_h2.ml`
- `scratch/eta_http_v1/probes/reach_13.ml`

## Evidence

```text
nix develop -c dune runtest lib/http --force
eta-http: 43 tests passed

nix develop -c dune exec scratch/eta_http_v1/probes/honeycomb_h2.exe
eta_http_s2_honeycomb outcome=ok status=404 body_bytes=19 protocol=h2 policy=tls12_ecdhe_aead_only

nix develop -c dune exec scratch/eta_http_v1/probes/reach_13.exe
eta_http_reach_summary verdict=PASS targets=13 failed=<none> protocol=auto_alpn policy=tls12_ecdhe_aead_only
```

Observed protocol split in the 13-endpoint run: 11 h2 routes, 2 h1 fallbacks
(`listener.logz.io:8071`, `sts.amazonaws.com`).

## Disproof Result

The first auto-ALPN reach run falsified the initial h2 response-body logic for
Datadog: `HEAD https://otlp.datadoghq.com/v1/traces` negotiated h2, returned
`content-length`, and correctly sent no body. The client waited for a body and
timed out. S2 fixed this by completing h2 HEAD/204/304/no-body responses
without waiting for DATA.

## Verdict

PASS for public ALPN dispatch, same caller path, Honeycomb h2 live smoke, and
13-endpoint auto-ALPN reach. Remaining S2 work is GOAWAY admission, H-Q2/H-Q5
attack reproduction on real `ocaml-h2`, and ADR 0004.

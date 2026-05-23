# R4 DNS Probe

## Question

Is `Eio.Net.getaddrinfo_stream` sufficient as the eta-http v1 DNS boundary,
with happy eyeballs deferred to v1.x?

## Implementation

- `Eta_http.Transport.Connect.target_of_url` turns an absolute client URL into
  a target containing scheme, host, effective port, and numeric service.
- `Eta_http.Transport.Connect.resolve_stream` calls
  `Eio.Net.getaddrinfo_stream` inside an `Eta.Effect.sync`.
- `Eta_http.Transport.Connect.connect_tcp` tries the resolved stream
  addresses in resolver order and returns the first TCP connection that opens.
- Resolver exceptions and empty resolver results become typed
  `Eta_http.Error.Dns_error` failures. Failed connection attempts become
  typed `Eta_http.Error.Connect_error` failures.

## Evidence

```sh
nix develop -c dune build packages/eta-http
nix develop -c dune runtest packages/eta-http --force
bash packages/eta-http/audit/run.sh
nix develop -c dune exec scratch/eta_http_v1/probes/openai_401.exe
nix develop -c dune exec scratch/eta_http_v1/probes/reach_13.exe
```

Observed:

```text
eta-http: 24 tests passed
Dependency sites: 67
Eta escape sites: 0
eta_http_openai_401 outcome=ok status=401 body_bytes=151 content_length="151" transfer_encoding="<none>" protocol=h1
eta_http_s1_reach_summary verdict=PASS targets=13 failed=<none> protocol=h1 policy=tls12_ecdhe_aead_only
```

## Verdict

PASS.

The Eio DNS API composes with Eta's effect runtime, maps failures into the
eta-http error taxonomy, works against a real OpenAI h1/TLS smoke, and passes
the 13-endpoint reach matrix through the public h1 client path.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| `getaddrinfo` blocks the whole runtime | Not observed; 13/13 live h1 reach passed. |
| IPv4-only fallback misses real endpoints | Not observed; 13/13 live h1 reach passed. |

# H-S2 Results

Status: local ALPN matrix passes and production ALPN smoke passes on the older
TLS stack. This is not yet an H-S3 production-grade TLS verdict.

## Dependency Branch

The latest available TLS stack was blocked by `digestif.1.3.0` under
`ocaml-variants.5.2.0+ox`. The viable branch is:

```text
ca-certs              0.2.3
mirage-crypto         0.11.3
mirage-crypto-rng     0.11.3
mirage-crypto-rng-eio 0.11.3
tls                   0.17.5
tls-eio               0.17.5
x509                  0.16.5
```

Install command:

```sh
nix develop .#oxcaml -c opam install --yes --assume-depexts tls-eio.0.17.5 mirage-crypto-rng-eio.0.11.3 x509.0.16.5 ca-certs
```

The install downgraded `mirage-crypto`, `eqaf`, and `asn1-combinators` in the
local research switch. `eta-oxcaml-test-shipped` passes after the downgrade.

## Local Matrix

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s2_tls_eio_alpn/alpn_matrix.exe && timeout 20s dune exec scratch/eta_http_research/h_s2_tls_eio_alpn/alpn_matrix.exe'
```

Output:

```text
h_s2_alpn mode=tls12 min=tls12 max=tls12 config=server_prefers_h2 selected=h2 payload="ok"
h_s2_alpn mode=tls12 min=tls12 max=tls12 config=server_prefers_h1 selected=http/1.1 payload="ok"
h_s2_alpn mode=tls13 min=tls13 max=tls13 config=server_prefers_h2 selected=h2 payload="ok"
h_s2_alpn mode=tls13 min=tls13 max=tls13 config=server_prefers_h1 selected=http/1.1 payload="ok"
h_s2_alpn mode=tls12_to_tls13 min=tls12 max=tls13 config=server_prefers_h2 selected=h2 payload="ok"
h_s2_alpn mode=tls12_to_tls13 min=tls12 max=tls13 config=server_prefers_h1 selected=http/1.1 payload="ok"
```

Result: PASS for 3 TLS modes x 2 ALPN configurations. Both client and server
epochs report the expected selected ALPN, and encrypted payload transfer works
after the handshake.

Modes:

- `tls12`: TLS 1.2 only.
- `tls13`: TLS 1.3 only.
- `tls12_to_tls13`: ranged TLS 1.2 through TLS 1.3.

ALPN configurations:

- `server_prefers_h2`: overlapping client/server lists select `h2`.
- `server_prefers_h1`: overlapping client/server lists select `http/1.1`.

## Required 2 x 3 ALPN Matrix

Command:

    nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s2_tls_eio_alpn/alpn_required_matrix.exe && timeout 20s dune exec scratch/eta_http_research/h_s2_tls_eio_alpn/alpn_required_matrix.exe'

Output:

    h_s2_required_alpn server=h2_h1 client=prefer_h2_fallback selected=h2 payload="ok"
    h_s2_required_alpn server=h2_h1 client=require_h2 selected=h2 payload="ok"
    h_s2_required_alpn server=h2_h1 client=require_h1 selected=http/1.1 payload="ok"
    h_s2_required_alpn server=h1_only client=prefer_h2_fallback selected=http/1.1 payload="ok"
    h_s2_required_alpn server=h1_only client=require_h2 selected=rejected payload="<none>"
    h_s2_required_alpn server=h1_only client=require_h1 selected=http/1.1 payload="ok"

Result: PASS for the requested server ALPN h2+h1/h1-only x client mode prefer
h2 fallback/require h2/require h1 matrix. Requiring h2 against an h1-only
server rejects the handshake with no application protocol, which is the
expected substrate signal for eta-http's require-h2 mode.

## Production Smoke

Command:

```sh
nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s2_tls_eio_alpn/nghttp2_alpn_smoke.exe && timeout 20s dune exec scratch/eta_http_research/h_s2_tls_eio_alpn/nghttp2_alpn_smoke.exe'
```

Output:

```text
h_s2_prod_alpn host=nghttp2.org selected=h2 version=tls13
```

Result: PASS as non-blocking production smoke. `tls-eio` negotiates ALPN `h2`
with `nghttp2.org` using CA validation from `ca-certs`.

## Caveats

- This evidence supports H-S2, not H-S3. H-S3 still needs badssl/local cert
  fixtures, CVE audit, and a revocation-policy ADR at exact pinned versions.
- The viable stack is older (`tls-eio.0.17.5`, `tls.0.17.5`,
  `x509.0.16.5`). The latest `tls-eio.2.1.0` branch remains blocked by the
  `digestif` OxCaml compile failure.

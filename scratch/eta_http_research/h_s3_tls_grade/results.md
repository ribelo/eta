# H-S3 Results

Status: FAIL for production-grade client TLS on the pinned branch. Part A has
an explicit BadSSL failure, Part B has positive local certificate evidence, and
Part C records exact-version advisory and revocation-policy evidence.

## Part A: BadSSL grid

Command:

    nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s3_tls_grade/badssl_grid.exe && timeout 90s dune exec scratch/eta_http_research/h_s3_tls_grade/badssl_grid.exe'

Output:

    h_s3_badssl name=expired host=expired.badssl.com expected=reject_expired observed=reject_expired result=PASS detail="reject_expired"
    h_s3_badssl name=self_signed host=self-signed.badssl.com expected=reject_invalid_chain observed=reject_invalid_chain result=PASS detail="reject_invalid_chain"
    h_s3_badssl name=untrusted_root host=untrusted-root.badssl.com expected=reject_invalid_chain observed=reject_invalid_chain result=PASS detail="reject_invalid_chain"
    h_s3_badssl name=wrong_host host=wrong.host.badssl.com expected=reject_name_mismatch observed=reject_name_mismatch result=PASS detail="reject_name_mismatch"
    h_s3_badssl name=dh1024 host=dh1024.badssl.com expected=reject_weak_dh observed=accepted_weak_dh result=FAIL version=tls12 alpn=http/1.1
    h_s3_badssl name=rc4_md5 host=rc4-md5.badssl.com expected=reject_weak_cipher observed=reject_handshake_failure result=PASS detail="reject_handshake_failure"
    h_s3_badssl name=hsts host=hsts.badssl.com expected=accept_valid_tls observed=accepted result=PASS version=tls12 alpn=http/1.1
    h_s3_badssl_summary verdict=FAIL failed=dh1024

Source inspection:

- `tls/config.ml`: `Tls.Config.Ciphers.http2` includes DHE_RSA
  AEAD suites.
- `tls/config.ml`: `let min_dh_size = 1024`.
- `tls/config.mli`: `min_dh_size` is documented as "currently
  1024".
- `tls/handshake_client.ml`: the DHE client handshake accepts
  `Mirage_crypto_pk.Dh.modulus_size group >= Config.min_dh_size`.

Decision:

This is a Part A FAIL for production-grade TLS on the pinned older TLS branch.
The stack correctly rejects expired, self-signed, untrusted-root, and
wrong-host certificates; rejects the RC4-MD5 endpoint by handshake failure; and
accepts a valid HSTS endpoint. However, it accepts `dh1024.badssl.com`
with TLS 1.2 and `http/1.1` ALPN when the production-grade bar expects
weak 1024-bit DHE rejection.

Implication:

H-S3 cannot pass unless eta-http can configure the TLS stack to reject this
class, carries an explicit narrowed cipher policy that avoids the weak-DH path,
moves to a TLS version that rejects it by default, or pivots to another TLS
substrate. The local certificate matrix and security audit should continue only
to determine whether this is an isolated configurable failure or part of a
broader production-grade TLS gap.

## Part B: local certificate matrix

Command:

    nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s3_tls_grade/local_cert_matrix.exe && timeout 60s dune exec scratch/eta_http_research/h_s3_tls_grade/local_cert_matrix.exe'

Output:

    h_s3_local_cert name=san_single expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls13 payload="ok"
    h_s3_local_cert name=san_mismatch expected=reject_name observed=reject_name result=PASS identity=host:other.local.test detail="reject_name"
    h_s3_local_cert name=wildcard expected=accept observed=accepted result=PASS identity=host:api.wild.local.test version=tls13 payload="ok"
    h_s3_local_cert name=wildcard_too_deep expected=reject_name observed=reject_name result=PASS identity=host:deep.api.wild.local.test detail="reject_name"
    h_s3_local_cert name=san_multiple expected=accept observed=accepted result=PASS identity=host:multi.local.test version=tls13 payload="ok"
    h_s3_local_cert name=ip_literal expected=accept observed=accepted result=PASS identity=ip:127.0.0.1 version=tls13 payload="ok"
    h_s3_local_cert name=idna_alabel expected=accept observed=accepted result=PASS identity=host:xn--bcher-kva.local.test version=tls13 payload="ok"
    h_s3_local_cert name=sni_multiple_cert_select expected=accept observed=accepted result=PASS identity=host:sni.local.test version=tls13 payload="ok"
    h_s3_local_cert name=tls12_only expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls12 payload="ok"
    h_s3_local_cert name=tls13_only expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls13 payload="ok"
    h_s3_local_cert_summary verdict=PASS failed=<none>

Decision:

This is positive H-S3 Part B evidence. The pinned stack validates SAN DNS
names, rejects a wrong DNS name, applies wildcard matching only one DNS label
deep, validates SAN IP addresses through `Tls.Config.client ~ip`, accepts
an IDNA A-label hostname, uses client SNI to select the matching certificate
from `Tls.Config.server ~certificates:(\`Multiple_default ...)`, and can
complete TLS 1.2-only and TLS 1.3-only local handshakes.

Caveat:

The IDNA row uses the ASCII A-label form
`xn--bcher-kva.local.test`. If eta-http accepts Unicode U-label input,
that conversion/normalization remains an eta-http API responsibility; this TLS
fixture proves that the wire-form A-label is validated correctly.

## Part C: exact-version security audit and revocation policy

Artifacts:

- scratch/eta_http_research/h_s3_tls_grade/security_audit.md
- scratch/eta_http_research/adrs/0001-tls-revocation-policy.md

Pinned versions:

| Package | Version |
| --- | --- |
| ca-certs | 0.2.3 |
| mirage-crypto | 0.11.3 |
| mirage-crypto-rng | 0.11.3 |
| mirage-crypto-rng-eio | 0.11.3 |
| tls | 0.17.5 |
| tls-eio | 0.17.5 |
| x509 | 0.16.5 |

OSV package-url query result:

    {"results":[{"vulns":[{"id":"OSEC-2026-06","modified":"2026-05-20T14:15:05.649849Z"},{"id":"OSEC-2026-07","modified":"2026-05-20T14:15:05.649759Z"}]},{},{},{},{},{},{}]}

Security findings:

- OSEC-2026-06 / CVE-2026-45388: tls < 2.1.0 TLS 1.3 client misses
  KeyUsage/ExtendedKeyUsage checks on server certificates. This directly
  affects eta-http client TLS on tls.0.17.5.
- OSEC-2026-07 / CVE-2026-45389: tls < 2.1.0 server mTLS misses
  client-certificate KeyUsage/ExtendedKeyUsage checks. This is not the main
  eta-http client case, but it constrains any server/mTLS substrate plan.
- Tls.Config.min_dh_size = 1024, and the BadSSL grid proves
  dh1024.badssl.com is accepted.
- Tls.Config.min_rsa_key_size = 1024.
- Revocation is opt-in through caller-provided CRLs. The default
  Ca_certs.authenticator () path does not perform live OCSP or CRL fetching.

Decision:

This is an H-S3 Part C FAIL. The exact pinned stack is affected by published
tls advisories and lacks browser-equivalent revocation behavior by default.
The ADR records the eta-http policy constraint: eta-http must not claim live
revocation checking unless a future API deliberately exposes caller-owned CRL
or policy hooks with fixtures.

## Overall H-S3 verdict

H-S3 FAIL on the pinned older TLS branch.

Positive evidence:

- Expired, self-signed, untrusted-root, wrong-host, RC4-MD5, and valid HSTS
  BadSSL rows classify as expected.
- Local SAN, wildcard, multiple SAN, IP-literal, A-label IDNA, SNI certificate
  selection, TLS 1.2-only, and TLS 1.3-only rows pass.

Negative evidence:

- dh1024.badssl.com is accepted under TLS 1.2.
- OSV reports OSEC-2026-06 / CVE-2026-45388 against tls.0.17.5, directly
  affecting TLS 1.3 client certificate validation.
- Default revocation checking is not live and must be an explicit eta-http
  policy/API decision.

H-D must not proceed on a claim that this exact TLS substrate is
production-grade. A pivot remains possible if eta-http can move to a fixed TLS
branch under OxCaml, narrow ciphers/key policy with evidence, or select another
TLS substrate.

## Focused verification after Part C

Command:

    nix develop .#oxcaml -c bash -lc 'dune build scratch/eta_http_research/h_s3_tls_grade/badssl_grid.exe scratch/eta_http_research/h_s3_tls_grade/local_cert_matrix.exe && timeout 90s dune exec scratch/eta_http_research/h_s3_tls_grade/badssl_grid.exe && timeout 60s dune exec scratch/eta_http_research/h_s3_tls_grade/local_cert_matrix.exe'

Output:

    h_s3_badssl name=expired host=expired.badssl.com expected=reject_expired observed=reject_expired result=PASS detail="reject_expired"
    h_s3_badssl name=self_signed host=self-signed.badssl.com expected=reject_invalid_chain observed=reject_invalid_chain result=PASS detail="reject_invalid_chain"
    h_s3_badssl name=untrusted_root host=untrusted-root.badssl.com expected=reject_invalid_chain observed=reject_invalid_chain result=PASS detail="reject_invalid_chain"
    h_s3_badssl name=wrong_host host=wrong.host.badssl.com expected=reject_name_mismatch observed=reject_name_mismatch result=PASS detail="reject_name_mismatch"
    h_s3_badssl name=dh1024 host=dh1024.badssl.com expected=reject_weak_dh observed=accepted_weak_dh result=FAIL version=tls12 alpn=http/1.1
    h_s3_badssl name=rc4_md5 host=rc4-md5.badssl.com expected=reject_weak_cipher observed=reject_handshake_failure result=PASS detail="reject_handshake_failure"
    h_s3_badssl name=hsts host=hsts.badssl.com expected=accept_valid_tls observed=accepted result=PASS version=tls12 alpn=http/1.1
    h_s3_badssl_summary verdict=FAIL failed=dh1024
    h_s3_local_cert name=san_single expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls13 payload="ok"
    h_s3_local_cert name=san_mismatch expected=reject_name observed=reject_name result=PASS identity=host:other.local.test detail="reject_name"
    h_s3_local_cert name=wildcard expected=accept observed=accepted result=PASS identity=host:api.wild.local.test version=tls13 payload="ok"
    h_s3_local_cert name=wildcard_too_deep expected=reject_name observed=reject_name result=PASS identity=host:deep.api.wild.local.test detail="reject_name"
    h_s3_local_cert name=san_multiple expected=accept observed=accepted result=PASS identity=host:multi.local.test version=tls13 payload="ok"
    h_s3_local_cert name=ip_literal expected=accept observed=accepted result=PASS identity=ip:127.0.0.1 version=tls13 payload="ok"
    h_s3_local_cert name=idna_alabel expected=accept observed=accepted result=PASS identity=host:xn--bcher-kva.local.test version=tls13 payload="ok"
    h_s3_local_cert name=sni_multiple_cert_select expected=accept observed=accepted result=PASS identity=host:sni.local.test version=tls13 payload="ok"
    h_s3_local_cert name=tls12_only expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls12 payload="ok"
    h_s3_local_cert name=tls13_only expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls13 payload="ok"
    h_s3_local_cert_summary verdict=PASS failed=<none>

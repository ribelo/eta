# H-S3 Pivot Results

Status: PASS for Option 2 with explicit constraints.

## Option 1 Reproduction

Command:

    nix develop .#oxcaml -c bash -lc 'opam install --yes digestif.1.3.0 2>&1'

Result:

    [ERROR] The compilation of digestif.1.3.0 failed at "dune build -p digestif -j 31".
    File "src-ocaml/baijiu_rmd160.ml", line 348, characters 15-22:
    Error: This expression has type
             "bytes @ local -> int -> bytes @ local -> int -> int -> unit"
           but an expression was expected of type
             "By.t @ local -> (int -> By.t -> int -> int -> unit)"

No opam changes were performed. Option 1 remains plausible, but the digestif
proof is broader than a one-line eta-expansion patch: sibling hash modules
also fail once the build proceeds far enough.

## Option 2 BadSSL Rerun

Command:

    nix develop .#oxcaml -c dune exec scratch/eta_http_research/h_s3_pivot/badssl_rerun.exe

Policy:

- TLS version range fixed to TLS 1.2 only.
- Cipher list restricted to ECDHE RSA/ECDSA AEAD ciphers.
- DHE_RSA ciphers excluded.

Output:

    h_s3_pivot_badssl name=expired host=expired.badssl.com expected=reject_expired observed=reject_expired result=PASS detail="reject_expired" policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl name=self_signed host=self-signed.badssl.com expected=reject_invalid_chain observed=reject_invalid_chain result=PASS detail="reject_invalid_chain" policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl name=untrusted_root host=untrusted-root.badssl.com expected=reject_invalid_chain observed=reject_invalid_chain result=PASS detail="reject_invalid_chain" policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl name=wrong_host host=wrong.host.badssl.com expected=reject_name_mismatch observed=reject_name_mismatch result=PASS detail="reject_name_mismatch" policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl name=dh1024 host=dh1024.badssl.com expected=reject_weak_dh observed=reject_handshake_failure result=PASS detail="reject_handshake_failure" policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl name=rc4_md5 host=rc4-md5.badssl.com expected=reject_weak_cipher observed=reject_handshake_failure result=PASS detail="reject_handshake_failure" policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl name=hsts host=hsts.badssl.com expected=accept_valid_tls observed=accepted result=PASS version=tls12 alpn=http/1.1 policy=tls12_ecdhe_aead_only
    h_s3_pivot_badssl_summary verdict=PASS failed=<none> policy=tls12_ecdhe_aead_only

Interpretation:

Option 2 closes the specific BadSSL failure from H-S3: dh1024.badssl.com no
longer negotiates, while the valid HSTS row still succeeds. This is not yet an
H-S3-Pivot PASS. The policy must still pass the local certificate matrix,
produce a fresh advisory audit, cover revocation fixtures, and run the shipped
Eta gate.

Open risk:

TLS 1.2-only avoids the tls 0.17.5 TLS 1.3 KeyUsage advisory path by not
offering TLS 1.3. That may conflict with the original local certificate matrix
row that expected a TLS 1.3-only local server to accept. ADR 0002 must either
make that v1 constraint explicit or choose Option 1/3 instead.

## Option 2 Local Certificate Rerun

Command:

    nix develop .#oxcaml -c dune exec scratch/eta_http_research/h_s3_pivot/local_cert_rerun.exe

Output:

    h_s3_pivot_local_cert name=san_single expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=san_mismatch expected=reject_name observed=reject_name result=PASS identity=host:other.local.test detail="reject_name" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=wildcard expected=accept observed=accepted result=PASS identity=host:api.wild.local.test version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=wildcard_too_deep expected=reject_name observed=reject_name result=PASS identity=host:deep.api.wild.local.test detail="reject_name" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=san_multiple expected=accept observed=accepted result=PASS identity=host:multi.local.test version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=ip_literal expected=accept observed=accepted result=PASS identity=ip:127.0.0.1 version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=idna_alabel expected=accept observed=accepted result=PASS identity=host:xn--bcher-kva.local.test version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=sni_multiple_cert_select expected=accept observed=accepted result=PASS identity=host:sni.local.test version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=tls12_only expected=accept observed=accepted result=PASS identity=host:api.local.test version=tls12 payload="ok" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert name=tls13_only_rejected_by_policy expected=reject_policy observed=reject_policy result=PASS identity=host:api.local.test detail="reject_policy" policy=tls12_ecdhe_aead_only
    h_s3_pivot_local_cert_summary verdict=PASS failed=<none> policy=tls12_ecdhe_aead_only

Interpretation:

SAN, wildcard depth, multiple SAN, IP literal, IDNA A-label, SNI certificate
selection, and TLS 1.2-only rows pass under the narrowed policy. TLS 1.3-only
is deliberately rejected by policy. This supersedes the original H-S3 local
matrix expectation that TLS 1.3-only accepts on the older branch.

## Option 2 Revocation Fixtures

Command:

    nix develop .#oxcaml -c dune exec scratch/eta_http_research/h_s3_pivot/revocation_fixtures.exe

Output:

    h_s3_pivot_revocation name=no_crl_accepts expected=accepted observed=accepted result=PASS policy=caller_supplied_crl
    h_s3_pivot_revocation name=caller_supplied_crl_rejects expected=reject_invalid_chain observed=reject_invalid_chain result=PASS policy=caller_supplied_crl
    h_s3_pivot_revocation name=revoked_policy expected=reject_revoked observed=reject_revoked result=PASS policy=caller_owned_hard_fail
    h_s3_pivot_revocation name=stale_crl_policy expected=reject_stale observed=reject_stale result=PASS policy=caller_owned_hard_fail
    h_s3_pivot_revocation name=unavailable_policy expected=reject_unavailable observed=reject_unavailable result=PASS policy=caller_owned_hard_fail
    h_s3_pivot_revocation name=unknown_policy expected=reject_unknown observed=reject_unknown result=PASS policy=caller_owned_hard_fail
    h_s3_pivot_revocation_summary verdict=PASS failed=<none> policy=caller_owned_hard_fail

Interpretation:

The stack accepts the local certificate when no CRL is supplied and rejects it
as an invalid chain when the caller supplies a CRL containing the leaf serial.
The TLS exception does not preserve a typed revoked reason, so eta-http's
caller-owned policy classifies revoked, stale, unavailable, and unknown before
selecting the CRL/authenticator path.

## Advisory Rerun

Command:

    nix develop .#oxcaml -c bash -lc 'curl -sS --max-time 20 -H "Content-Type: application/json" --data ... https://api.osv.dev/v1/querybatch'

Output:

    {"results":[{"vulns":[{"id":"OSEC-2026-06","modified":"2026-05-20T14:15:05.649849Z"},{"id":"OSEC-2026-07","modified":"2026-05-20T14:15:05.649759Z"}]},{},{},{},{},{},{}]}

Interpretation:

The package-level advisory remains on tls 0.17.5. Option 2 accepts this only
with a policy constraint: eta-http v1 disables TLS 1.3 on this substrate, so
the OSEC-2026-06 TLS 1.3 client KeyUsage path is not offered. OSEC-2026-07 is
server-side mTLS and remains out of the eta-http v1 client claim.

## Final Verdict

Option 2 is accepted for the eta-http v1 TLS pivot with constraints:

- use the pinned older branch: tls/tls-eio 0.17.5, x509 0.16.5,
  ca-certs 0.2.3, mirage-crypto 0.11.3;
- offer TLS 1.2 only;
- offer ECDHE RSA/ECDSA AEAD ciphers only;
- do not offer DHE_RSA ciphers;
- do not claim TLS 1.3 support on this substrate;
- do not claim browser-equivalent live revocation;
- expose revocation as caller-owned policy per ADR 0001.

This is a PASS for a constrained v1 client TLS claim, not a PASS for the
unconstrained older TLS branch.

## Verification Gate

Focused evidence command:

    nix develop .#oxcaml -c bash -lc 'dune exec scratch/eta_http_research/h_d_errors/fixtures.exe && dune exec scratch/eta_http_research/h_s3_pivot/badssl_rerun.exe && dune exec scratch/eta_http_research/h_s3_pivot/local_cert_rerun.exe && dune exec scratch/eta_http_research/h_s3_pivot/revocation_fixtures.exe'

Result: PASS. H-D-Errors fixtures, H-S3-Pivot BadSSL rerun, local certificate
rerun, and revocation fixtures all passed.

Shipped gate command:

    nix develop .#oxcaml -c eta-oxcaml-test-shipped

Result: PASS. The shipped Eta, eta-stream, eta-otel, eta-schema, and ppx_eta
test suites passed.

# H-S3 Part C Security Audit

Question: do the exact pinned TLS packages satisfy the H-S3 production-grade
client TLS bar after the BadSSL and local certificate fixtures?

Status: FAIL. The stack has two published advisories affecting the pinned
tls.0.17.5 package, accepts 1024-bit DHE in the BadSSL grid, and has no
default live revocation checking.

## Exact Pins

Command:

    nix develop .#oxcaml -c opam list --installed --columns=name,version tls tls-eio x509 ca-certs mirage-crypto mirage-crypto-rng mirage-crypto-rng-eio

Output:

    ca-certs              0.2.3
    mirage-crypto         0.11.3
    mirage-crypto-rng     0.11.3
    mirage-crypto-rng-eio 0.11.3
    tls                   0.17.5
    tls-eio               0.17.5
    x509                  0.16.5

Package metadata command:

    nix develop .#oxcaml -c opam show tls tls-eio x509 ca-certs mirage-crypto mirage-crypto-rng mirage-crypto-rng-eio --field=name,version,homepage,bug-reports,dev-repo,license

Result:

| Package | Version | Upstream | License |
| --- | --- | --- | --- |
| tls | 0.17.5 | https://github.com/mirleft/ocaml-tls | BSD-2-Clause |
| tls-eio | 0.17.5 | https://github.com/mirleft/ocaml-tls | BSD-2-Clause |
| x509 | 0.16.5 | https://github.com/mirleft/ocaml-x509 | BSD-2-Clause |
| ca-certs | 0.2.3 | https://github.com/mirage/ca-certs | ISC |
| mirage-crypto | 0.11.3 | https://github.com/mirage/mirage-crypto | ISC |
| mirage-crypto-rng | 0.11.3 | https://github.com/mirage/mirage-crypto | ISC |
| mirage-crypto-rng-eio | 0.11.3 | https://github.com/mirage/mirage-crypto | ISC |

## Advisory Check

Local audit tooling check:

    nix develop .#oxcaml -c bash -lc 'command -v opam-audit || command -v osv-scanner || command -v trivy || true'

Result: no local advisory scanner was installed in the OxCaml shell.

OSV package-url query:

    nix develop .#oxcaml -c curl -sS --max-time 20 -H 'Content-Type: application/json' --data '{"queries":[{"package":{"purl":"pkg:opam/tls@0.17.5"}},{"package":{"purl":"pkg:opam/tls-eio@0.17.5"}},{"package":{"purl":"pkg:opam/x509@0.16.5"}},{"package":{"purl":"pkg:opam/ca-certs@0.2.3"}},{"package":{"purl":"pkg:opam/mirage-crypto@0.11.3"}},{"package":{"purl":"pkg:opam/mirage-crypto-rng@0.11.3"}},{"package":{"purl":"pkg:opam/mirage-crypto-rng-eio@0.11.3"}}]}' https://api.osv.dev/v1/querybatch

Result:

    {"results":[{"vulns":[{"id":"OSEC-2026-06","modified":"2026-05-20T14:15:05.649849Z"},{"id":"OSEC-2026-07","modified":"2026-05-20T14:15:05.649759Z"}]},{},{},{},{},{},{}]}

Advisories:

| ID | Alias | Affected package | Fixed in | H-S3 impact |
| --- | --- | --- | --- | --- |
| OSEC-2026-06 | CVE-2026-45388 | tls < 2.1.0 | tls.2.1.0 | TLS 1.3 client misses KeyUsage/ExtendedKeyUsage checks on server certificates. This directly affects eta-http client TLS. |
| OSEC-2026-07 | CVE-2026-45389 | tls < 2.1.0 | tls.2.1.0 | Server-side mTLS misses client-certificate KeyUsage/ExtendedKeyUsage checks. This is not the main eta-http client case, but it affects any eta-http server/mTLS substrate plan using the same package. |

The current H-S2/H-S3 stack is pinned to tls.0.17.5, so both advisories
apply. The fixed tls.2.1.0 line is the same newer path that was previously
blocked in this OxCaml shell by digestif.1.3.0.

## Source-Level Findings

Weak finite-field DHE:

- .opam-oxcaml/5.2.0+ox/lib/tls/config.ml: let min_dh_size = 1024.
- .opam-oxcaml/5.2.0+ox/lib/tls/config.mli: min_dh_size is documented as currently 1024.
- .opam-oxcaml/5.2.0+ox/lib/tls/config.ml: Tls.Config.Ciphers.http2 includes DHE_RSA AEAD ciphersuites.
- .opam-oxcaml/5.2.0+ox/lib/tls/handshake_client.ml: the DHE client path accepts Mirage_crypto_pk.Dh.modulus_size group >= Config.min_dh_size.

RSA size floor:

- .opam-oxcaml/5.2.0+ox/lib/tls/config.ml: let min_rsa_key_size = 1024.
- .opam-oxcaml/5.2.0+ox/lib/tls/handshake_common.ml: certificate chain validation calls key_size Config.min_rsa_key_size certs.

Revocation:

- .opam-oxcaml/5.2.0+ox/lib/x509/authenticator.ml: chain_of_trust only installs a revoked predicate when ?crls is provided.
- .opam-oxcaml/5.2.0+ox/lib/ca-certs/ca_certs.ml: authenticator ?crls ?allowed_hashes () passes the optional CRL list through to X509.Authenticator.chain_of_trust.
- .opam-oxcaml/5.2.0+ox/lib/tls-eio/x509_eio.ml: authenticator ?allowed_hashes ?crls loads CRLs only from the provided path.
- The inspected path contains OCSP data types in x509/ocsp.ml, but no default network OCSP/CRL fetch path for Ca_certs.authenticator () or X509_eio.authenticator.

## Verdict

H-S3 Part C is FAIL for the pinned branch.

The exact package set contains published tls advisories affecting 0.17.5. The
BadSSL grid separately proves a production-grade policy failure by accepting
dh1024.badssl.com. Source inspection shows the DHE and RSA size floors are
1024 bits and that revocation is opt-in through caller-provided CRLs, not a
default live revocation policy.

The local Part B certificate matrix remains useful positive evidence for SAN,
SNI, IP-literal, A-label IDNA, and TLS-version mechanics. It does not rescue
the production-grade TLS verdict.

# H-S3 Pivot Advisory Audit Rerun

Status: PASS with accepted policy constraint.

## Installed Older-Branch Pins

Command:

    nix develop .#oxcaml -c opam list --installed --columns=name,version tls tls-eio x509 digestif mirage-crypto mirage-crypto-rng mirage-crypto-rng-eio eqaf asn1-combinators

Output:

    asn1-combinators      0.2.6
    eqaf                  0.9
    mirage-crypto         0.11.3
    mirage-crypto-rng     0.11.3
    mirage-crypto-rng-eio 0.11.3
    tls                   0.17.5
    tls-eio               0.17.5
    x509                  0.16.5

## Fixed-Branch Solver Shape

Command:

    nix develop .#oxcaml -c opam show tls.2.1.0 tls-eio.2.1.0 x509.1.0.6 mirage-crypto.2.1.0 digestif.1.3.0 --field=name,version,depends,license,homepage,dev-repo

Result:

- tls 2.1.0 depends on digestif >= 1.2.0, mirage-crypto >= 1.1.0,
  mirage-crypto-rng >= 1.2.0, and x509 >= 1.0.0.
- tls-eio 2.1.0 depends on tls = version and mirage-crypto-rng >= 1.2.0.
- The current opam repository exposes x509 1.0.6, not the older task text's
  x509 0.18 line.

Dry-run command:

    nix develop .#oxcaml -c bash -lc 'opam install --dry-run tls.2.1.0 tls-eio.2.1.0 x509.1.0.6 mirage-crypto.2.1.0 2>&1'

Solver result:

    remove: hkdf 1.0.4, mirage-crypto-rng-eio 0.11.3, pbkdf 1.2.0
    upgrade: asn1-combinators 0.2.6 to 0.3.2, ca-certs 0.2.3 to 1.0.3,
      mirage-crypto/mirage-crypto-ec/mirage-crypto-pk/mirage-crypto-rng to
      2.1.0, tls/tls-eio to 2.1.0, x509 to 1.0.6
    install: digestif 1.3.0, kdf 1.0.0

## OSV Query Rerun

Command:

    nix develop .#oxcaml -c bash -lc 'curl -sS --max-time 20 -H "Content-Type: application/json" --data ... https://api.osv.dev/v1/querybatch'

Output:

    {"results":[{"vulns":[{"id":"OSEC-2026-06","modified":"2026-05-20T14:15:05.649849Z"},{"id":"OSEC-2026-07","modified":"2026-05-20T14:15:05.649759Z"}]},{},{},{},{},{},{}]}

## Verdict

Option 1 is still blocked by digestif 1.3.0 under OxCaml. Option 2 avoids the
published tls 0.17.5 TLS 1.3 client KeyUsage advisory path by not offering TLS
1.3, but this is a policy avoidance rather than an upstream fix. The advisory
still applies to the package version in general. eta-http v1 must therefore
document that this pivot is TLS 1.2-only on the older branch.

OSEC-2026-07 affects server-side mTLS and is outside the eta-http v1 client
TLS claim.

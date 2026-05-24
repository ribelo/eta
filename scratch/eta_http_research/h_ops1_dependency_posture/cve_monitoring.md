# H-Ops1 CVE Monitoring

Date: 2026-05-24

## Advisory Sources

| Source | Coverage | Cadence |
| --- | --- | --- |
| OSV `pkg:opam/*` | OSEC and mirrored ecosystem advisories for opam packages | weekly and before release |
| OCaml Security Group / OSEC | OCaml ecosystem advisories | weekly and before release |
| GitHub Security Advisories | upstream GitHub project advisories | weekly and before release |
| NVD | CVE metadata and aliases | weekly for TLS/crypto packages |
| opam-repository package metadata | new versions, constraints, deprecations | with every dependency bump |
| Upstream release feeds | h2, ocaml-tls, x509, ca-certs, mirage-crypto, decompress, Eio | with every dependency bump |

## Local Scanner Availability

Command:

```sh
command -v osv-scanner opam-audit opam
```

Result: only `opam` was installed before this artifact. There was no local
`osv-scanner` or `opam-audit` binary in PATH.

## OSV Query

Command:

```sh
nix develop -c curl -sS --max-time 30 \
  -H 'Content-Type: application/json' \
  --data @scratch/eta_http_research/h_ops1_dependency_posture/osv-query.json \
  https://api.osv.dev/v1/querybatch
```

Result:

```json
{"results":[{},{},{"vulns":[{"id":"OSEC-2026-06","modified":"2026-05-20T14:15:05.649849Z"},{"id":"OSEC-2026-07","modified":"2026-05-20T14:15:05.649759Z"}]},{},{},{},{},{},{},{},{},{}]}
```

The third result corresponds to `pkg:opam/tls@0.17.5`. No queried h2,
hpack, tls-eio, x509, ca-certs, mirage-crypto, mirage-crypto-rng,
mirage-crypto-rng-eio, decompress, eio, or cstruct advisory was returned by
this OSV run.

## Process

1. Run the OSV query weekly and before eta-http releases.
2. If OSV reports an advisory, map the result to direct eta-http exposure:
   client request path, TLS handshake, certificate validation, body codec,
   HTTP/2 parser/HPACK, or development-only tooling.
3. Check OSEC and upstream release notes for fixed versions and mitigation
   notes.
4. For TLS/X.509/crypto advisories, block release unless the advisory is
   demonstrably server-only or test-only for eta-http.
5. Record every exception in this directory or a successor ADR with affected
   package, fixed version, reason for deferral, and owner.

## Current Exceptions

| Advisory | Package | Current version | Fixed version | Status |
| --- | --- | --- | --- | --- |
| OSEC-2026-06 / CVE-2026-45388 | tls | 0.17.5 | 2.1.0 | Known client TLS risk; upgrade blocked by current OxCaml compatibility branch. |
| OSEC-2026-07 / CVE-2026-45389 | tls | 0.17.5 | 2.1.0 | Server/mTLS-oriented risk; same package pin and same upgrade path. |

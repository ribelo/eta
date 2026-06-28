# H-Ops1 LTS Outlook

Date: 2026-05-24

## 12-Month Risk Ranking

| Area | Risk | Reason |
| --- | --- | --- |
| TLS/X.509/crypto stack | high | Current `tls.0.17.5` has known OSEC advisories and security fixes are on the `tls.2.1.0` line. |
| OxCaml package compatibility | high | The repo pins `ocaml-variants.5.2.0+ox`; security upgrades can be blocked by packages that do not yet solve on this switch. |
| HTTP/2 parser/HPACK stack | medium | `h2.0.13.0` and `hpack.0.13.0` are core parser dependencies; no OSV advisory appeared in this query, but they are input-facing. |
| Compression | medium | `decompress.1.5.3` handles attacker-controlled bytes; no OSV advisory appeared in this query. |
| Eio/runtime stack | medium | Eio is structural and patched for OxCaml in this switch; compatibility risk is higher than license risk. |
| Utility parsers | low | `domain-name`, `ipaddr`, `base64`, `asn1-combinators`, and related helpers have permissive licenses and narrow APIs, but remain input-facing. |
| Test/doc tooling | low | Alcotest and odoc do not ship in the runtime path. |

## Outlook

The most likely unfixed-CVE scenario is not a missing scanner. It is an
available fixed version that cannot be adopted quickly because the OxCaml
switch, TLS branch, and transitive packages do not solve together.

The practical mitigation is to keep the TLS stack isolated behind
`Http.Tls.Config` and `Http.Transport.Connect`, maintain a weekly
OSV/OSEC check, and treat TLS/X.509 advisories as release-blocking until the
fixed branch is proven on the pinned compiler.

---
id: Eta-aea
title: "H-Ops1: eta-http dependency closure, license, build-time, and CVE
  process are acceptable for an Eta core package"
status: open
priority: 2
issue_type: task
created_at: 2026-05-22T15:25:54.624Z
created_by: backlog
updated_at: 2026-05-22T19:03:57.876Z
dependencies:
  - issue_id: Eta-aea
    depends_on_id: Eta-adr
    type: parent-child
    created_at: 2026-05-22T19:03:57.876Z
    created_by: backlog
---

# H-Ops1: eta-http dependency closure, license, build-time, and CVE process are acceptable for an Eta core package

## description

HYPOTHESIS (per Review #2). eta-http's dependency closure (h2/httpaf, tls-eio, ocaml-tls, x509/ca-certs, decompress, plus test tools) has acceptable build-time impact, transitive license compatibility, package-size delta, exact-version pin policy, and a documented CVE-monitoring process. eta-http will become a core Eta substrate so this matters at the same level as eta itself, not as an optional toy. WHY IT MATTERS (per Review #2). The plan has a CVE audit for TLS (H-S3) but no general dependency posture. Without this hypothesis, eta-http ships with implicit operational debt: nobody owns advisory monitoring for h2/decompress/x509; build time grows without measurement; transitive licenses might surprise downstream consumers. BLAST RADIUS. Medium. Failure means eta-http ships and accumulates ops debt over time. FAST FALSIFIER. scratch/eta_http_research/h_ops1_dependency_posture/. Fresh opam switch build of eta-http stub. Measure: (a) opam install closure size (number of new packages, total size), (b) cold build time vs current Eta packages baseline, (c) incremental rebuild time after eta-http source touch, (d) transitive license table (every package + license; flag any GPL/AGPL/copyleft surprise), (e) exact opam version pins or ranges for h2, tls-eio, ocaml-tls, x509, ca-certs, decompress, (f) CVE monitoring sources for each (NVD, GHSA, upstream issue trackers, OCaml Security Group), (g) what 'eta-http LTS' looks like (which transitive deps are most likely to have unfixed CVEs in 12 months).

## design

DISPROOF SIGNATURES. Dependency closure is materially larger than competitor h2 client choices (e.g., 50+ new packages). Or build-time impact is more than 30 seconds cold (subjective threshold; document and justify). Or transitive license surprise (GPL-tainted dep that we did not realize). Or one of h2/tls-eio/decompress has no monitorable advisory source. Or version-pin discipline cannot be expressed in our opam file (e.g., h2 has no stable release line). POSITIVE EVIDENCE NEEDED. closure_table.md lists every transitive package with version, license, source. build_timing.md documents cold vs incremental build measurements. cve_monitoring.md lists advisory sources per dep. version_pin_policy.md documents pin-vs-range per dep with justification. ARTIFACTS. scratch/eta_http_research/h_ops1_dependency_posture/{closure_table.md, build_timing.md, license_audit.md, cve_monitoring.md, version_pin_policy.md, lts_outlook.md, fresh_switch_build.sh, dune, README.md, results.md}. Journal entry V-Http-Ops1.

## acceptance criteria

scratch/eta_http_research/h_ops1_dependency_posture/ exists with all artifacts. results.md documents build-time, package-count, license, and CVE-source decisions. version_pin_policy.md is the document the eta-http opam file is built from. Verdict explicit. Journal entry V-Http-Ops1 added. This hypothesis closes BEFORE the eta-http implementation epic is filed.

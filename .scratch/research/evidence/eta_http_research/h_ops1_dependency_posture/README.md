# H-Ops1 Dependency Posture

Status: Closed as risk-documented, not green.

## Hypothesis

eta-http's dependency closure is operationally acceptable: build time is
acceptable, licenses are visible, CVE monitoring is defined, and version pin
policy is explicit.

## Evidence

- Root `dune-project` / generated `eta.opam` currently declare the eta-http
  direct dependency policy in this worktree.
- `packages/eta-http/audit/dep_usage.md` was refreshed with the repository
  script on 2026-05-24 and reports 343 raw dependency call-site matches.
- `packages/eta-http/audit/eta_escapes.md` was refreshed by the same script
  and reports 7 Eta primitive escapes.
- `closure_table.md` records the observed Linux OxCaml switch versions and
  licenses for the eta-http external runtime/build closure.
- `build_timing.md` records a separate build-dir timing run.
- `cve_monitoring.md` records the advisory process and the OSV query result.
- `version_pin_policy.md` records direct dependency pin/range rationale.
- `lts_outlook.md` records the 12-month risk outlook.

## Verdict

Build time is acceptable for local development: a fresh separate Dune build
directory for `packages/eta-http` took 5.25s real time, and the immediate
incremental rebuild took 0.30s.

The third-party runtime closure observed here is license-benign: ISC, MIT,
BSD-2-Clause, BSD-3-clause, and OCaml LGPL with linking exception. There is
still a repository metadata gap: generated `eta.opam` does not declare
`license`, `maintainer`, `authors`, `homepage`, or `bug-reports`.

The CVE posture is not green. The pinned TLS branch still has known OSEC
advisories against `tls.0.17.5`:

- OSEC-2026-06 / CVE-2026-45388
- OSEC-2026-07 / CVE-2026-45389

H-Ops1 is therefore closed as a documented operational risk register. It is
not evidence that the current TLS dependency posture is acceptable without a
tracked upgrade plan.

## Reproduce

```sh
nix develop -c opam show --just-file --field=name,depends,license: ./eta.opam
nix develop -c opam list --installed --columns=name,version,license:
nix develop -c bash packages/eta-http/audit/run.sh
nix develop -c curl -sS --max-time 30 -H 'Content-Type: application/json' --data @.scratch/research/evidence/eta_http_research/h_ops1_dependency_posture/osv-query.json https://api.osv.dev/v1/querybatch
```

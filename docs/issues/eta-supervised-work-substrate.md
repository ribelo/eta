---
kind: issue
requirements:
  - supcan-iar6
  - supcan-stst
  - supcan-f3ww
  - supcan-zqzf
  - supcan-l1iy
  - supcan-3os1
  - supcan-glb2
  - supcan-3sp7
  - supcan-dyvd
  - supcan-nnq7
  - supcan-eg0p
  - supcan-6zw9
  - supcan-urkv
  - supcan-5oxj
  - supcan-tg7n
  - supcan-qbzk
  - supcan-kptd
  - supcan-0uj5
  - supcan-yncg
  - supcan-xhxq
  - supcan-vb4t
---
# Eta supervised work substrate

Implement the complete
[[docs/wayfinder/eta-supervised-work-substrate/map|Eta supervised work substrate design map]].

The desired-state requirements are in
[[docs/requirements/eta-supervisor/request-cancellation]].

## Public seam

Add request-only cancellation to the existing root `eta` package and
`Supervisor.Scope`. Preserve the rank-two child brand and the existing `cancel`,
`await`, failure, and scope-exit contracts.

## TDD seams

- Test public supervisor behavior in the native common supervisor suite.
- Test the same observable contract in the JavaScript runtime suite.
- Test repeated-request equivalence through the generated law suite.
- Keep the existing negative supervisor-escape fixtures unchanged and passing.

## Law evidence

- Add generated law `M128` for repeated-request idempotence.
- Add registered laws `R181` through `R187` for request timing, terminal
  outcomes, observation fences, ordering, and backend request-only operations.
- Give every new interface claim an exact source span and named executable test.
- Do not add new dated law debt.

## Required gates

- [ ] The focused native supervisor, law, and type-error gates pass under
  OxCaml.
- [ ] The focused native, law, and JavaScript gates pass under upstream OCaml.
- [ ] `dune build @install` and the full OxCaml test suite pass.
- [ ] The OxCaml shipped-package gate passes.
- [ ] The upstream OCaml shipped-package and JavaScript gate passes.
- [ ] The Erg OCaml 5.4 dependency gate passes.
- [ ] Every requirement ID has code or executable evidence.
- [ ] An independent review accepts the implementation against every requirement
  ID.

Archive this issue after all requirements, gates, and review checks pass.

## Comments

The repository-wide requirement ID validator reports 179 existing missing-ID
diagnostics under `docs/requirements/eta-crux`. This branch adds no validator
diagnostic. All 21 `supcan-*` IDs pass shape, uniqueness, ticket-accounting, and
Git-history reuse checks.

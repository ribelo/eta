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

- [x] The focused native supervisor, law, and type-error gates pass under
  OxCaml.
- [x] The focused native, law, and JavaScript gates pass under upstream OCaml.
- [x] `dune build @install` and the full OxCaml test suite pass.
- [x] The OxCaml shipped-package gate passes.
- [x] The upstream OCaml shipped-package and JavaScript gate passes.
- [x] The Erg OCaml 5.4 dependency gate passes.
- [x] Every requirement ID has code or executable evidence.
- [x] An independent review accepts the implementation against every requirement
  ID.

Archive this issue after all requirements, gates, and review checks pass.

## Comments

The repository-wide requirement ID validator reports 179 existing missing-ID
diagnostics under `docs/requirements/eta-crux`. This branch adds no validator
diagnostic. All 21 `supcan-*` IDs pass shape, uniqueness, ticket-accounting, and
Git-history reuse checks.

## Requirement evidence

| Requirement | Evidence | Result |
| --- | --- | --- |
| `supcan-iar6` | Public signature in `lib/eta/supervisor.mli` and smart constructor in `lib/eta/supervisor.ml`. | Pass |
| `supcan-stst` | Request-latch implementation and the native and JavaScript pre-start tests. | Pass |
| `supcan-f3ww` | Promise-held nonwaiting tests on both runtimes. | Pass |
| `supcan-zqzf` | Pre-start tests await the child without a later `cancel` call. | Pass |
| `supcan-l1iy` | M128 covers request counts one through eight and one finalizer event. | Pass |
| `supcan-3os1` | Terminal-winner matrices cover completion, typed failure, defect, and finalizer diagnostics. | Pass |
| `supcan-glb2` | Atomic first publication and terminal-winner matrices. | Pass |
| `supcan-3sp7` | Later `cancel` tests hold cleanup settlement. | Pass |
| `supcan-dyvd` | The clean-interruption case returns `Ok ()` after one finalizer. | Pass |
| `supcan-nnq7` | Later `cancel` preserves typed failure, defect identity, and finalizer rendering. | Pass |
| `supcan-eg0p` | Later `await` covers every documented outcome class. | Pass |
| `supcan-6zw9` | Ordering tests assert the exact request call and return sequence. | Pass |
| `supcan-urkv` | Ordering tests force cleanup completion in reverse request order. | Pass |
| `supcan-5oxj` | M128 awaits active children and requires an available empty fiber census. | Pass |
| `supcan-tg7n` | The public type returns `unit` with an independent outer error type. | Pass |
| `supcan-qbzk` | The rank-two body and existing negative escape fixtures remain unchanged and pass. | Pass |
| `supcan-kptd` | Isolated native and JavaScript `Runtime_contract.cancel` probes. | Pass |
| `supcan-0uj5` | Isolated native and JavaScript `Runtime_contract.fail_scope` probes. | Pass |
| `supcan-yncg` | Equivalent native Eio and JavaScript matrices pass. | Pass |
| `supcan-xhxq` | The existing owner-domain restriction remains unchanged. No runtime token is public. | Pass |
| `supcan-vb4t` | Replacement work starts after request returns while old cleanup remains held. | Pass |

## Law evidence

M128 and R181 through R187 are registered in
`.scratch/research/dx/e22/review/LAWS.md`. The registry contains exact interface
and executable-test spans. The final census is 126 direct claims, 222 external
claim clusters, 2 model claims, and 82 named QCheck properties.

## Verification

All commands used the Nix flake and exited with status 0 at implementation commit
`f745846d`. The final span-only metadata commit is `c18fa277`.

| Compiler | Command | Exit |
| --- | --- | ---: |
| OxCaml `5.2.0+ox` | `nix develop -c dune runtest test/core_eio test/laws test/type_errors --force` | 0 |
| OCaml `5.4.1` | `nix develop .#mainline -c dune runtest test/core_eio test/laws test/js_jsoo --force` | 0 |
| OxCaml `5.2.0+ox` | `nix develop -c dune build @install` | 0 |
| OxCaml `5.2.0+ox` | `nix develop -c dune runtest --force` | 0 |
| OxCaml `5.2.0+ox` | `nix develop -c eta-oxcaml-test-shipped` | 0 |
| OCaml `5.4.1` | `nix develop .#mainline -c eta-mainline-test-shipped` | 0 |
| OCaml `5.4.1` | `nix develop .#ocaml54 -c eta-ocaml54-test-erg` | 0 |

The Erg shell initially lacked the QCheck runner required by its selected audio
law tests. Commit `957ad39d` adds that test dependency. The final Erg gate passes.

## Review

Independent correctness review covered `0521711d..c18fa277`. The review accepts
all 21 requirement IDs and M128 plus R181 through R187. It reports no findings.
An independent law-quality review also reports no findings and accepts the work.

## Resolution

Status: completed.

The public request-only cancellation contract is implemented and verified on
native Eio and JavaScript runtimes. The ticket is ready for archival.

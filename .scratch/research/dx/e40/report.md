# DX-E40 Report — `all` admission split

## Outcome

**E40 BLOCKED pending an orchestrator waiver.** The registered split,
discriminating evidence, law registry, omission census, and all four required
gates are complete, but the disclosed accidental one-line search match from a
scope-forbidden tree cannot be undone.

## Implemented contract

- `Effect.all effects` admits every prebuilt child immediately.
- `Effect.all_bounded ~max_concurrent effects` preserves the E28 worker-pool
  engine under a required positive bound and rejects nonpositive bounds at
  construction.
- `Effect.all_settled` keeps its signature and existing fork-all engine; its docs
  now name the shared immediate-admission model.
- `map_par` is unchanged.

`all` uses one fork per prebuilt child and `par_run_forks` for fail-fast cause
propagation and sibling cleanup. `all_bounded` alone uses `collect_workers`.
There was no hidden `all_settled`/worker-pool tangle.

## Executable evidence

| Obligation | Evidence | Result |
| --- | --- | --- |
| Every `all` child admitted | `all admits every generated child immediately` (sizes 9–12) | PASS |
| `all` coordination immunity | `all admits every generated rendezvous participant without admission deadlock`; shared `all admits full coordination group` | PASS |
| Bounded coordination stall possible | `all_bounded can stall when every admitted child awaits an unadmitted participant`; shared `all_bounded stalls below the coordination group size` | PASS |
| Bound enforced | `all_bounded never exceeds max_concurrent and reaches the bound when children suffice` | PASS |
| Construction rejection | generated nonpositive property plus shared zero/negative examples | PASS |
| Input order | generated reverse-completion properties for `all` and `all_bounded`; shared delayed-order test | PASS |
| Fail-fast/cancellation/finalizers | generated properties for both engines; existing shared recovery/finalizer baselines | PASS |
| `all_settled` admission alignment | generated 9–12-child barrier plus existing capture/order tests | PASS |
| Empty fiber/sleeper census | both generated barrier directions and shared pair | PASS |

Focused commands passed:

```sh
nix develop -c dune build lib/eta/eta.cmxa
nix develop -c dune runtest test/laws test/core_common --force
nix develop -c dune runtest test/core_eio --force
```

Raw focused outputs are in `dossier/deadlock-*.txt`.

## Omission census and migrations

The final lexical census contains **106 omission sites**: all 106 are
safe-to-widen and none has a load-bearing hidden bound. No omission was silently
rebounded. The 55 consumer/example/benchmark sites match the sealed detailed
predictions; the additional verification/new-law sites are individually listed
in `dossier/omission-census.md`.

All seven explicit `~max_concurrent` syntax sites were migrated through the
registered split. Bounded construction and tail-admission witnesses use
`all_bounded`; the old explicit-full-fan-out witnesses became the positive
plain-`all` side of the new barrier guarantee.

## Law registry

The census-complete `effect.mli` rows now state:

- M114/M115: immediate admission and admission-deadlock immunity for `all`;
- M116/M117 and M123–M125: bound, rejection, order, and fail-fast behavior for
  `all_bounded`;
- M126: immediate admission for `all_settled`;
- R127: the named bounded coordination caveat.

The direct census is 115 claims and 77 unique QCheck properties. No stale
omission-means-eight or explicit-length recipe remains. Registry diff:
`dossier/law-registry.diff`.

## Census and footgun deltas

- Public concurrency values: **+1**.
- `all` optional arguments: **-1**.
- Footguns: **-1/+0**.
- Omission migrations to a hidden bound: **0**.
- `all_settled_bounded`: not added; no structural need surfaced.

## Sealed prediction score

| Prediction | Actual | Score |
| --- | --- | --- |
| `all` can use fork-all beside `all_settled`; no engine tangle | Exact | Hit |
| `all_bounded` preserves E28 worker pool and rejects nonpositive values at construction | Exact | Hit |
| Same barrier completes under `all` and times out at `N - 1` under `all_bounded` | Exact in shared and generated tests | Hit |
| Fail-fast, order, cancellation, and finalizers remain | Focused shared and generated suites pass | Hit |
| No omission has a load-bearing hidden bound | 106/106 safe-to-widen | Hit |
| Public delta `+1 val`, `all` loses optional | Exact | Hit |
| Footgun delta `-1/+0` | Exact | Hit |
| Four required gates pass | All exact commands pass | Hit |

## Deviations

- The sealed journal listed every consumer/example/benchmark site and grouped
  verification witnesses. The final review census expands those groups and new
  law witnesses to 106 individual rows; classifications did not change.
- A broad discovery command accidentally returned one matching line from the
  forbidden `docs/research/` tree. No further access or modification occurred,
  and that line was not used as evidence; all decisions rely on the assigned
  sources, product tests, and tracked E40 artifacts.

## Independent review

The independent technical review found no runtime or API defect. It identified
one executable-law gap: the first `all_bounded` order property admitted its
whole generated list in one wave. The property now generates 4–8 children under
a bound of two, proves tail admission, observes child 1 complete before child 0,
still requires input-order results, and finishes with an empty fiber census.
The focused follow-up confirmed that M123 has no remaining technical blocker.

The same review classified the disclosed scope-fence breach as a procedural
blocker requiring an orchestrator waiver.

## Required gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | PASS |

## Recommendation

The product patch is technically ready to promote: `all` is now honest and
deadlock-immune with respect to admission, while callers that own a real load
limit must name it with `all_bounded` and see its coordination caveat. The E40
handoff remains procedurally blocked until the orchestrator accepts or waives
the recorded scope-fence breach.

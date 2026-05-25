# Eta V2 Build Audit

Status: complete for build experiment evidence; ready for merge decision.

Base commit at audit time: `ef0da28d0a8f6ff508e1d3ce41c1373067e27bb8`.

Note on pins: the package rewrite is pinned to the phase-1 commit below.
The phase-A audit row pins the commit that introduced this audit artifact.

## Phase Evidence

| Phase | Status | x-pinned-commit | Evidence |
|---|---|---|---|
| 0 soundness | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | Current soundness gate rejects all negative fixtures against `_build/default/packages/eta/eta.cmxa`. The objective says 9 fixtures; the current tree has 10, including `tracer_portable_closure_negative.ml`. |
| 1 eta core | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | `Effect.t` is now an abstract direct record representation in `packages/eta/effect_direct.ml`; `packages/eta/effect.ml` includes it; `Runtime.run` delegates to `Effect_direct.run`. |
| 2 eta-test | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | Covered by `dune build @runtest`; `eta-test` reports 11 tests passing. |
| 3 eta-stream | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | Covered by `dune build @runtest`; `eta-stream` reports 17 tests passing. |
| 4 eta-http | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | Covered by `dune build @runtest`; `eta-http` reports 111 tests passing, including retry, h1/h2, observability, and pool paths. |
| 5 eta-otel | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | Covered by `dune build @runtest`; `eta-otel` reports 35 tests passing. |
| 6 eta-ai/providers | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | Covered by `dune build @runtest`; `eta-ai` and OpenAI/Anthropic/OpenRouter/OpenAI-compatible provider tests pass. |
| 7 remaining packages | PASS | 32f8222086a8fde9690c92d9b81672cb4cf5fc62 | `eta-redacted`, `eta-schema-test`, and `ppx_eta` tests pass under `dune build @runtest`. |
| A audit | PASS | 45bdd145af286eca2addf72c7dd48c821d8be7dc | Soundness, span propagation, runtime tests, and quick allocation/wall evidence are recorded below. |

## Reproducible Commands

Build:

```sh
source scratch/eta_research/eio_direct_probe/env.sh
dune build packages/eta/eta.cmxa
```

Soundness:

```sh
source scratch/eta_research/eio_direct_probe/env.sh
bash packages/eta/test/soundness/run.sh _build/default/packages/eta/eta.cmxa
```

Full test sweep:

```sh
source scratch/eta_research/eio_direct_probe/env.sh
timeout 180s dune build @runtest
```

Span graph / fork propagation:

```sh
source scratch/eta_research/eio_direct_probe/env.sh
dune exec scratch/eta_research/eio_direct_probe/p5_tracer/fork_propagation.exe
```

Observed output:

```text
P5 PASS - FLS propagates active span through v2 fork
```

Allocation/wall quick audit:

```sh
source scratch/eta_research/eio_direct_probe/env.sh
dune build --profile=release \
  bench/runtime_overhead/runtime_overhead.exe \
  bench/runtime_real/runtime_real.exe
_build/default/bench/runtime_overhead/runtime_overhead.exe --quick \
  --filter 'overhead.eta.bind.100k.prebuilt|overhead.eta.fail_catch.100k.prebuilt|overhead.eta.setup_pure|overhead.eta.pure.reused_rt'
_build/default/bench/runtime_real/runtime_real.exe --quick \
  --filter 'realuse.pipeline.bind_catch.1k|realuse.scope.acquire_release.64'
```

Observed quick results from this worktree:

| Workload | wall_ns | minor_words | major_words |
|---|---:|---:|---:|
| overhead.eta.setup_pure | 140190.124512 | 0 | 0 |
| overhead.eta.pure.reused_rt | 9059.906006 | 0 | 0 |
| overhead.eta.bind.100k.prebuilt | 1096010.208130 | 0 | 0 |
| overhead.eta.fail_catch.100k.prebuilt | 3591060.638428 | 6291435 | 242 |
| realuse.pipeline.bind_catch.1k | 163078.308105 | 0 | 0 |
| realuse.scope.acquire_release.64 | 87022.781372 | 0 | 0 |

Historical P6 eta-otel slice baseline from
`scratch/eta_research/eio_direct_probe/p6_dogfood_slice/results.md`:
AST 474.4 words/run and 12528.9 ns/run; v2 231.5 words/run and
5714.9 ns/run. The shipped package no longer contains the AST control,
so future apples-to-apples comparisons should use a pinned pre-rewrite commit
or the historical P6 lab control.

## Removed

- `packages/eta/effect_ast.ml`
- `packages/eta/runtime_interpret.ml`
- `packages/eta/runtime_concurrency.ml`
- the unused AST interpreter functor in `packages/eta/runtime_supervisor.ml`
- `Runtime.run`'s identity cast from `Effect.t` to the AST

## Added / Reshaped

- `packages/eta/effect_direct.ml`: direct abstract implementation of the
  public `Effect.t` surface.
- Static `name` / `collect_names` metadata is carried in the hidden record
  representation, not via a public AST view.
- Concurrency, timeout, resource, retry/repeat, supervisor, blocking/island,
  and observability behavior now execute directly over Eio.
- `Runtime.run` maps public pools to runtime pools, then delegates to
  `Effect_direct.run`.

## Risk Register

- No phase commit hashes are pinned yet because the worktree had unrelated
  dirty state before this run. Commit these changes in phase-tagged commits
  before merge review.
- The full AST control was removed from `packages/eta`; future allocation
  comparisons need a pinned pre-rewrite commit or the historical P6 lab
  control.
- The benchmark command above is a quick audit sample, not a statistically
  stable benchmark record. Run `bash bench/run.sh` for a full local record.
- Existing alerts in `blocking_runtime.ml` about `Domain.spawn` remain
  unrelated to this v2 port and were present in build output.

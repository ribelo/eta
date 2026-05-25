# Eta V2 Build Audit

Status: shipped locally for linear merge to master.

Base commit for the ship comparison: `aa4b2697ab7a295e2ea669ca0f207c852f2692c9`.
V2 head before merge: `37ab8598dfde56e8c90ad7fc2ba3705654848dca`.

## Phase Evidence

| Phase | Status | x-pinned-commit | Evidence |
|---|---|---|---|
| 0 soundness | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | The soundness gate rejects all 10 current negative fixtures against `_build/default/packages/eta/eta.cmxa`, including `tracer_portable_closure_negative.ml`. |
| 1 eta core | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | `Effect.t` is now an abstract direct record representation in `packages/eta/effect_direct.ml`; `packages/eta/effect.ml` includes it; `Runtime.run` delegates to `Effect_direct.run`. |
| 2 eta-test | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | Covered by `dune build @runtest`; eta-test passes. |
| 3 eta-stream | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | Covered by `dune build @runtest`; eta-stream passes. |
| 4 eta-http | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | Covered by `dune build @runtest`; eta-http retry, h1/h2, observability, and pool paths pass. |
| 5 eta-otel | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | Covered by `dune build @runtest`; eta-otel passes. |
| 6 eta-ai/providers | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | Covered by `dune build @runtest`; eta-ai and provider tests pass. |
| 7 remaining packages | PASS | `e95acf36d138470314793b3280ea2e37c596aaf7` | `eta-redacted`, `eta-schema-test`, and `ppx_eta` tests pass under `dune build @runtest`. |
| A audit | PASS | `37ab8598dfde56e8c90ad7fc2ba3705654848dca` | Soundness, full tests, and n=20 v1/v2 wall/allocation comparison are recorded below. |

## Commands Run

The local ship worktree used the existing OxCaml switch:

```sh
export OPAMROOT=/home/ribelo/projects/ribelo/ocaml/Eta/.opam-oxcaml
eval "$(opam env --switch 5.2.0+ox --set-switch)"
```

Build:

```sh
dune build packages/eta/eta.cmxa
```

Soundness:

```sh
bash packages/eta/test/soundness/run.sh _build/default/packages/eta/eta.cmxa
```

Full test sweep:

```sh
timeout 240s dune build @runtest
```

Focused performance comparison:

```sh
export EIO_BACKEND=posix
dune build --profile=release \
  bench/runtime_overhead/runtime_overhead.exe \
  bench/runtime_real/runtime_real.exe

_build/default/bench/runtime_overhead/runtime_overhead.exe --samples 20 \
  --filter 'overhead.eta.setup_pure|overhead.eta.pure.reused_rt|overhead.eta.bind.100k.prebuilt|overhead.eta.fail_catch.100k.prebuilt'

for row in \
  realuse.fanout.par.success.64x50 \
  realuse.pipeline.bind_catch.1k \
  realuse.retry.flaky.fail4_then_ok \
  realuse.scope.acquire_release.64
do
  _build/default/bench/runtime_real/runtime_real.exe --samples 20 --filter "$row"
done
```

`EIO_BACKEND=posix` was used because the Linux io_uring backend hit
`Unix.ENOMEM("io_uring_queue_init")` when the harness repeatedly created
`Eio_main.run` instances at n=20. Both v1 and v2 were measured with the same
backend.

## V1 vs V2 Performance

Comparison is current master `aa4b269` vs rebased v2 `37ab859`, release
profile, n=20. Wall columns are mean +/- stddev in ns. Allocation columns are
mean words per measured row.

| Workload | v1 wall_ns | v2 wall_ns | v2/v1 | v1 minor | v2 minor | v1 major | v2 major |
|---|---:|---:|---:|---:|---:|---:|---:|
| overhead.eta.bind.100k.prebuilt | 690579 +/- 1080561 | 441456 +/- 173563 | 0.64 | 0 | 0 | 0 | 0 |
| overhead.eta.fail_catch.100k.prebuilt | 2369320 +/- 233629 | 3499746 +/- 66557 | 1.48 | 1048573 | 6291435 | 0 | 242 |
| overhead.eta.pure.reused_rt | 48 +/- 213 | 2229 +/- 2043 | 46.75 | 0 | 0 | 0 | 0 |
| overhead.eta.setup_pure | 37158 +/- 36825 | 40114 +/- 44752 | 1.08 | 0 | 0 | 0 | 0 |
| realuse.fanout.par.success.64x50 | 63050 +/- 36582 | 70143 +/- 48019 | 1.11 | 0 | 0 | 0 | 0 |
| realuse.pipeline.bind_catch.1k | 38278 +/- 30998 | 40245 +/- 37311 | 1.05 | 0 | 0 | 0 | 0 |
| realuse.retry.flaky.fail4_then_ok | 88990 +/- 34508 | 40007 +/- 28342 | 0.45 | 0 | 0 | 0 | 0 |
| realuse.scope.acquire_release.64 | 41056 +/- 45666 | 38433 +/- 26990 | 0.94 | 0 | 0 | 0 | 0 |

Interpretation:

- Bind remains a real win with zero measured allocation.
- Retry remains the strongest real-use win and covers the Phase 4 dagger path.
- Fanout, pipeline, setup, and scope have overlapping stddevs; do not over-read
  those small ratios.
- `pure.reused_rt` is below the timer floor on v1 and about 2.2 us on v2. It
  is a real absolute regression but not a consumer hot path in this evidence set.
- `fail_catch` allocation is a real structural regression: v2 pays about 6x
  minor words and 242 major words for 100k fail/catch round trips.

## Fast-Path Investigation

A pre-merge pure/fail marker fast path was tested and rejected. Adding marker
fields to the direct effect record made the compiler keep `Effect.pure`
construction inside the bind hot path, changing
`overhead.eta.bind.100k.prebuilt` from 0 to 1048575 minor words per row. A
fail-only marker had the same bind allocation pollution.

Conclusion: the pure terminal fast path and fail/catch allocation cleanup need a
representation that preserves bind's zero-allocation path. They are documented
follow-ups, not part of this merge.

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

- The full AST control was removed from `packages/eta`; future allocation
  comparisons need a pinned pre-rewrite commit or the historical P6 lab control.
- `pure.reused_rt` and `fail_catch` are known follow-ups. The attempted
  marker fix was rejected because it regressed bind allocation.
- Existing alerts in `blocking_runtime.ml` about `Domain.spawn` remain
  unrelated to this v2 port and were present in build output.

## Follow-up Resolutions (post-merge)

- **Domain.spawn alerts**: silenced at the call site in
  `packages/eta/blocking_runtime.ml`. The `Domain_isolated` blocking-runtime
  mode is an opt-in escape hatch where spawning a fresh domain per job is
  the deliberate behavior, so `do_not_spawn_domains` and `unsafe_multidomain`
  are suppressed locally with a justifying comment.
  `Domain.Safe.spawn` would require the public Blocking callback type to
  be portable, which would be a public API regression, so it was not used.
- **io_uring ENOMEM in the harness**: `bench/run.sh` now defaults
  `EIO_BACKEND=posix`. Root cause is the kernel `ulimit -l` (memlocked
  memory; 8 MB on most distros). Each `Eio_main.run` under the io_uring
  backend locks pages per ring; n=20 samples * 8 rows accumulate locked
  pages faster than the kernel releases them. Switching to posix removes
  the memlock pressure without affecting comparability — both v1 and v2
  are measured under the same backend. Override is still available by
  exporting `EIO_BACKEND` before invoking the script.

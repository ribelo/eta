# Eta Signal cost probe

This throwaway probe measures the current scalar Signal path at separate
execution seams. It does not change production code or the frozen benchmark.

## Run the probe

Run this command from the repository root:

```sh
SAMPLES=9 nix develop -c bash \
  .scratch/research/eta-signal-execution-model/cost-probe/run.sh \
  > .scratch/research/eta-signal-execution-model/cost-probe/results.csv
```

The script builds the repository and the separate probe project with `-O3`.
It pins each fresh process to CPU 2.

The separate project uses the `eta_signal` package name to access private engine
libraries. It does not publish or install a package.

## Layers

| Layer | Added work |
|---|---|
| `raw` | Current synchronous planning under one batch-held lane |
| `effect` | One prebuilt Eta Effect step for each graph operation |
| `lane` | One uncontended lane acquisition for each fused graph operation |
| `public_sync` | Public `Var.set` and `stabilize` on the synchronous runtime |
| `public_eio` | The same observer-free public path on the Eio runtime |
| `scheduled_eio` | One explicit Eio-backed `Effect.yield` before that path |
| `observer_eio` | Public demand and no-op observer delivery |
| `timer_eio` | One demanded, non-firing timer during the observer path |

The observer-free layers use a private demand reference. This reference keeps
the same output graph necessary without observer delivery.

The `scheduled_eio` row is a diagnostic branch from `public_eio`. The
`observer_eio` row also branches from `public_eio`.

## Evidence

- `results.csv` contains nine samples for every layer and graph depth.
- `summary.csv` contains medians and the declared delta baseline.
- `public-cross-check.csv` contains one frozen public-benchmark sample per depth.

Generated `_build` directories are not evidence and remain ignored.

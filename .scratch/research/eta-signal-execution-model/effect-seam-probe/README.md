# Effect-seam prototype

This throwaway prototype compares private Eta effect seams around one
synchronous Signal kernel. It is not production Signal code.

Run all semantic checks and performance rows:

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/effect-seam-probe/run.sh
```

The script writes raw samples to `results.csv` and process medians to
`summary.csv`.

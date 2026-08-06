# Static kernel probe

This throwaway probe answers issue 06 of the Eta Signal execution-model map.
It is not production Signal code.

The executable contains two prototypes:

- `Plan` creates an immutable prospective array before it installs values.
- `Raw` mutates retained node storage and uses intrusive height queues.

Run the semantic checks and all measurements from the repository Nix shell:

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/static-kernel-probe/run.sh
```

Set `CPU` to select the pinned CPU. Set `SAMPLES` to change the sample count.
Set `PAIRS` to change the comparison-pair count. The defaults are nine samples
and three pairs. The script writes `results.csv` and `summary.csv`.

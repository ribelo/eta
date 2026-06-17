# Hill-Climbing Prompt

Set up and climb the H2 `connections=16`, `streams_per_connection=1` tail
latency attribution hill.

After the H2 owner batch-8 change, the non-excluded 4x4 H2 rows mostly beat the
references or moved in the right direction. The remaining reference-worse tail
latency lives in the excluded 16-connection / 1-stream H2 shape, especially H2
TLS versus Go and H2 plain echo versus Node.

Primary metric:

```text
h2_16x1_eta_ref_p99_ratio_geomean
```

Lower is better, but this hill is attribution-first. Do not optimize production
code until the gap is split between server H2/TLS work, client/load scheduling,
kernel/off-CPU behavior, or benchmark shape artifacts.

Run:

```sh
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-tail-attribution-20260615
```

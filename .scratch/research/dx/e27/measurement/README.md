# DX-E27 allocation measurement

Command (single pinned CPU, ten samples):

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.log
```

| Row | Wall mean ± stddev | Minor words/100k | Major words/100k |
| --- | ---: | ---: | ---: |
| `log.100k.minimum_filtered` | 3,248,906 ± 50,038 ns | 2,097,146 | 120 |
| `logf.100k.minimum_filtered` | 3,466,225 ± 115,605 ns | 2,097,146 | 120 |
| `logf.100k.enabled` | 28,826,022 ± 516,525 ns | 28,311,400 | 3,095 |

The two filtered rows are structurally equivalent prebuilt 100k chains and
have exactly equal measured allocation. Enabled minus disabled is 26,214,254
minor words/100k, or 262.14254 words per formatted record. Raw JSON is in
`runtime-watchlist.txt`.

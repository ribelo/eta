# DX-E27 corrected allocation measurement

Command (single pinned CPU, ten samples):

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.logf
```

| Row | Wall mean ± stddev | Minor words/100k | Major words/100k |
| --- | ---: | ---: | ---: |
| `logf.100k.construct.minimum_filtered` | 4,942,608 ± 66,738 ns | 5,242,866 | 126 |
| `logf.100k.construct.enabled` | 34,380,984 ± 229,968 ns | 33,554,300 | 8,113 |
| `logf.100k.construct.minimum_filtered.width_1m` | 4,902,720 ± 33,284 ns | 5,242,866 | 126 |

Every row constructs 100k formatter closures and `logf` blueprints during the
measured run. Enabled minus filtered is 28,311,434 minor words/100k, or
283.11434 words per formatted record. The adversarial `%1000000d` filtered row
is exactly equal to ordinary filtered construction, so its million-character
padding is not allocated. Corrected raw JSON is in `runtime-watchlist.txt`;
the superseded format4/prebuilt evidence remains in
`runtime-watchlist-format4.txt` for auditability.

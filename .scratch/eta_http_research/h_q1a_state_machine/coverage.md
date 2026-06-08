# H-Q1a Coverage

Property run:

```text
nix develop -c dune exec scratch/eta_http_research/h_q1a_state_machine/fixtures.exe
```

| Property | Seed | Trials | Coverage target | Observed | Shrunk failure |
| --- | ---: | ---: | --- | ---: | --- |
| a permits baseline | 47001 | 300 | cancel/RST sequences >= 30 | 300 | none |
| b no body after RST | 47002 | 300 | RST+DATA sequences >= 30 | 300 | none |
| c window accounting | 47003 | 300 | multi-DATA sequences >= 30 | 137 | none |
| d trailers after END_STREAM | 47004 | 300 | trailer sequences >= 30 | 300 | none |
| e GOAWAY blocks streams | 47005 | 300 | GOAWAY sequences >= 30 | 300 | none |
| f body exhausted once | 47006 | 300 | multi-read sequences >= 30 | 300 | none |
| g retry classifier | 47007 | 300 | retryable outcomes >= 30 | 178 | none |
| h pool arithmetic | 47008 | 300 | open/release sequences >= 30 | 300 | none |
| i server push rejected | 47009 | 120 | PUSH_PROMISE sequences >= 1 | 120 | none |
| j PRIORITY ignored | 47010 | 120 | PRIORITY sequences >= 1 | 120 | none |

No failures occurred, so no regression fixture was emitted. The shrinker is active; a future failure prints the minimal failing prefix as `SHRINK <ops>`.

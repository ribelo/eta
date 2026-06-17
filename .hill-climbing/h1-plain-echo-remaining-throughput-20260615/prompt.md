# Hill-Climbing Prompt

Set up and climb the remaining H1 plain `echo_1k` throughput hill against Go.

Prior art in `.hill-climbing/h1-plain-echo-1k-throughput-20260615/` already
found and kept the first fixed-body allocation/copy win. This session starts
from the current tree after that work and asks whether the remaining Eta/Go
throughput gap is still worth production optimization.

Run:

```sh
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-remaining-throughput-20260615
```

Primary metric:

```text
h1_plain_echo_1k_eta_go_rps_ratio
```

Higher is better. Guard exact-byte correctness, p99, and non-echo H1 plain
diagnostics. Do not special-case `/echo`, the 1 KiB body size, oha, Go, or the
benchmark request shape.

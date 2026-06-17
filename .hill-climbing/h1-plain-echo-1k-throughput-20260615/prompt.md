# Hill-Climbing Prompt

Set up and climb the H1 plain `echo_1k` throughput hill against Go.

The latest broad quick run showed Eta H1 plain `POST /echo` with a 1 KiB body at
about `0.70x` Go throughput under `c=16`, while p99 latency was roughly tied.
This makes the hill potentially worth climbing because it is an Eta-owned H1
request-body echo/write throughput gap rather than another benchmark p99
measurement artifact.

Run:

```sh
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-1k-throughput-20260615
```

Primary metric:

```text
h1_plain_echo_1k_eta_go_rps_ratio
```

Higher is better. Guard correctness, p99, and non-echo H1 plain diagnostics.
Do not special-case `/echo`, the 1 KiB body size, oha, Go, or the benchmark
request shape. The server must still read the full request body and echo the
exact response bytes.

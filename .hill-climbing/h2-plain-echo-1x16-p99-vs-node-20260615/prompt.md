# Hill-Climbing Prompt

Set up and climb the H2 plain `echo_1k` p99 hill against Node for the
single-connection multiplexed shape:

```text
transport=plain
protocol=h2
connections=1
streams_per_connection=16
endpoint=echo_1k
```

Run:

```sh
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-echo-1x16-p99-vs-node-20260615
```

Primary metric:

```text
h2_plain_echo_1x16_eta_node_p99_ratio
```

Lower is better. Guard exact-byte correctness, Eta RPS, non-echo H2 plain
endpoints, and do not special-case `/echo`, 1 KiB bodies, Node, oha, or this
specific stream shape. Production changes require attribution proving the p99
gap lives in Eta-owned HTTP behavior rather than client/socket/runtime
scheduling.

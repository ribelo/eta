# Hill-Climbing Prompt

Use $hill-climbing on `.hill-climbing/h1-tls-echo-1k-tail-20260615`.

Objective: improve `h1_tls_echo_1k_p99_us` without gaming or overfitting the
benchmark. This hill isolates the top remaining non-H2-socket-attributed Eta p99
case from the latest rerank: HTTP/1.1 over TLS, `/echo`, 1 KiB request and
response body, 16 concurrency / 16 keep-alive connections, 24k requests x 9
repeats.

Before climbing, call `create_goal` with an objective to improve this metric
while preserving correctness and guardrails. Read `JOURNAL.md`, split the
hypothesis space, then measure only through:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-tls-echo-1k-tail-20260615
```

Checks are mandatory:

```bash
bash .hill-climbing/h1-tls-echo-1k-tail-20260615/checks.sh
```

In scope:

- `.hill-climbing/h1-tls-echo-1k-tail-20260615/`
- H1/TLS echo attribution helpers
- Minimal Eta HTTP production changes only after attribution proves the latency
  is inside Eta-owned H1/TLS behavior

Off limits:

- weakening request count, endpoint behavior, TLS, keep-alive, or success checks
- special-casing `/echo` or 1 KiB bodies
- accepting a p99 win that materially regresses H1 plain echo, H1 TLS static,
  H1 TLS tiny endpoints, or throughput guards

Update `JOURNAL.md` manually after every experiment with predictions,
falsifiers, results, verdict, and the next hypothesis split.

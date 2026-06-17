# Hill-Climbing Prompt

Use $hill-climbing on `.hill-climbing/h2-echo-4x4-actionable-20260615`.

Objective: improve `h2_plain_echo_4x4_p99_us` without gaming or overfitting the
benchmark. This hill targets Eta H2C `/echo` with a 1 KiB body at 4 connections x
4 streams. It is the current top actionable Eta p99 case after excluding the
known H2 16x1 scheduling-sensitive shape from the ranking.

Before climbing, call `create_goal` with an objective to improve this metric
while preserving correctness and guardrails. Read `JOURNAL.md`, split the
hypothesis space, then measure only through:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-echo-4x4-actionable-20260615
```

Checks are mandatory:

```bash
bash .hill-climbing/h2-echo-4x4-actionable-20260615/checks.sh
```

In scope:

- `.hill-climbing/h2-echo-4x4-actionable-20260615/`
- H2 server/client instrumentation needed to attribute the p99
- Minimal production changes only after attribution proves the latency is inside
  Eta server behavior

Off limits:

- weakening the workload, request count, endpoint behavior, or success checks
- optimizing only oha/client accounting
- accepting a primary p99 win that breaks `h2_echo_4x4_success` or materially
  regresses TLS echo/static/root guards

Update `JOURNAL.md` manually after every experiment with predictions, falsifiers,
results, verdict, and the next hypothesis split.

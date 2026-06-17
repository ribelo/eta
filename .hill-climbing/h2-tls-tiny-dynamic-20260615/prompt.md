# Hill-Climbing Prompt

Climb H2 TLS p99 for small dynamic responses, especially `root`, `user_id`,
and `post_user`.

Workload:

- Eta H2 over TLS via `h2_tls_probe.exe`.
- One TLS connection, 16 H2 streams.
- `oha` fixed-count runs.
- Default: 24,000 requests per endpoint, 9 repeats.
- Endpoints: `root`, `user_id`, `post_user`, `static_1k`, `echo_1k`.

Primary metric:

- `h2_tls_root_p99_us`, lower is better.

Guardrails:

- `h2_tls_success` must stay `1.0`.
- `h2_tls_static_1k_p99_us` and `h2_tls_echo_1k_p99_us` must not materially
  regress.
- `h2_tls_rps_geomean` must not materially regress.

First split to investigate:

- TLS write/flush overhead for tiny responses.
- H2 response header/frame emission overhead.
- Per-request scheduling/wakeup before first write.
- Measurement noise from short responses.

Use only:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-tiny-dynamic-20260615
```

Update `JOURNAL.md` manually after every experiment with hypothesis, prediction,
result, verdict, and keep/revert decision.

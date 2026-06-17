# Hill-Climbing Prompt

Use `$hill-climbing` on `.hill-climbing/stubborn-crimson-latency`.

Call `create_goal` with an objective to reduce `h1_tls_static_1k_p99_ms`
without gaming or overfitting the benchmark. Read `JOURNAL.md`, split the
hypothesis space, run:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id stubborn-crimson-latency
```

Then update `JOURNAL.md` manually after each experiment.

Hill summary:

- Real target: Eta H1 over TLS keep-alive p99 in the broad server-load suite at
  `n=1000`, `c=16`.
- Primary metric: `h1_tls_static_1k_p99_ms`, lower is better.
- Secondary metrics: H1/TLS p99 for `root`, `user_id`, `post_user`, `echo_1k`,
  p50 and RPS for all measured endpoints, and `success`.
- Workload: standalone `h1_tls_probe.exe`, `oha --http-version 1.1 --insecure
  -n 1000 -c 16`, median of 3 repeats, optional CPU pinning matching
  `ETA_SERVER_LOAD_*`.
- Guard: `checks.sh` runs release-profile HTTP Eio/common tests.

Scope:

- In scope: `lib/http_eio/tls/`, `lib/http_eio/server.ml`,
  `lib/http_eio/h1_server_connection.ml`, tests directly covering changed
  behavior, and benchmark harness notes in this session directory.
- Out of scope: handler/body shortcuts, benchmark-only response caching,
  reducing request count or concurrency, weakening TLS semantics, weakening
  tests, or adding optional dependencies to core packages.

The reported broad-suite symptom is endpoint-independent: initial H1/TLS
handshakes land near p99 for `n=1000`, `c=16`. Prefer experiments that
distinguish TLS handshake scheduling / accept-domain behavior from H1 handler
or body work.

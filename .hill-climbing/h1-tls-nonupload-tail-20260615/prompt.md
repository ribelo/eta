# Hill-Climbing Prompt

Use $hill-climbing on `.hill-climbing/h1-tls-nonupload-tail-20260615`.

Objective: improve `h1_tls_static_1k_p99_us` without gaming or overfitting the
benchmark. This hill isolates the top clean Eta p99 cluster after excluding H2
socket-sensitive shapes and H1 upload-sensitive echo: HTTP/1.1 over TLS,
non-upload endpoints, 16 concurrency / 16 keep-alive connections, 24k requests x
9 repeats.

Measure only through:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-tls-nonupload-tail-20260615
```

Checks are mandatory:

```bash
bash .hill-climbing/h1-tls-nonupload-tail-20260615/checks.sh
```

In scope:

- `.hill-climbing/h1-tls-nonupload-tail-20260615/`
- H1/TLS non-upload attribution helpers
- Minimal Eta HTTP production changes only after attribution proves latency is
  inside Eta-owned H1/TLS behavior

Off limits:

- weakening TLS, keep-alive, request count, endpoint behavior, or success checks
- reintroducing upload-sensitive echo as the primary target
- accepting a static p99 win that materially regresses H1 TLS post/user/root,
  H1 plain static, throughput, or correctness

Update `JOURNAL.md` manually after every experiment.

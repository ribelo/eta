# Hill-Climbing Prompt: angular-cyan-prism

Use `$hill-climbing` on `.hill-climbing/angular-cyan-prism`.

Objective: improve or attribute Eta H2C `POST /echo` 1 KiB p99 without gaming the benchmark. The primary metric is `h2_plain_echo_1k_1x16_p99_ms`, but the matrix also measures `4x4`, `16x1`, and H1 plain at total concurrency 16.

Run measurements only through:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id angular-cyan-prism
```

Before production changes, read `JOURNAL.md`, split hypotheses, and update the journal manually after each experiment. Keep the request count, repeats, body size, success checks, and shape matrix stable unless you are explicitly doing a benchmark-setup experiment.

Files in scope:

- `.hill-climbing/angular-cyan-prism/`
- `lib/http_eio/h2_server_connection.ml`
- Existing tests under `test/http_eio` and `test/http_common`
- Minimal testsuite probe instrumentation when needed

Do not optimize handler/body copy paths unless a new measurement falsifies the current conclusion that copies are not the p99 limiter.

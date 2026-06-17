# Hill-Climbing Prompt

Use $hill-climbing on `.hill-climbing/bouncy-cobalt-echo`.

Create a goal with this objective:

Improve `h2_plain_echo_1k_p99_ms` for `.hill-climbing/bouncy-cobalt-echo` by hill-climbing with the provided benchmark facade. Do not game or overfit the benchmark. Preserve correctness by respecting `checks.sh`. Maintain `JOURNAL.md` manually with hypotheses, falsifiers, results, and hypothesis-space updates.

Hill summary:

- Target: Eta H2C `POST /echo` with a 1024-byte request body.
- Load shape: one H2 connection, 16 concurrent streams, repeated `oha` samples.
- Primary metric: `h2_plain_echo_1k_p99_ms`, lower is better.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Status command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py status --id bouncy-cobalt-echo`

Files in scope:

- `lib/http_eio/h2_server_connection.ml`
- `lib/http/server_body.ml`
- `lib/http/server_request_validation.ml`
- H2/server tests under `test/http*` when correctness coverage is needed
- `.hill-climbing/bouncy-cobalt-echo/JOURNAL.md`

Off limits:

- Do not weaken `checks.sh`.
- Do not reduce the request count, stream count, body size, or success validation to make the metric look better.
- Do not special-case the benchmark endpoint in production code.
- Do not mix results from older hill sessions into this hill's baseline.

After every experiment, run only the hill facade for measurement, inspect the appended `log.jsonl` entry, and update `JOURNAL.md` manually.

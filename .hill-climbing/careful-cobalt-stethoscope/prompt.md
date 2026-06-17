# Hill-Climbing Prompt

Use $hill-climbing on `.hill-climbing/careful-cobalt-stethoscope`.

Objective:

Improve `h2_plain_echo_1k_p99_ms` for H2C `POST /echo` 1 KiB under one H2 connection with 16 streams, using the provided diagnostic split. Do not game or overfit the benchmark. Preserve correctness by respecting `checks.sh`. Maintain `JOURNAL.md` manually after every experiment.

Benchmark:

- Run: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Status: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py status --id careful-cobalt-stethoscope`
- Primary phase is uninstrumented.
- Diagnostic phase sets `ETA_H2_ECHO_TRACE_PATH` and emits request-body read, write wait, write completion, and copy metrics.

Likely files:

- `lib/http_eio/h2_server_connection.ml`
- `lib/http/server_body.ml`
- `lib/http/server_response.ml`
- `http-testsuite/lib/eta_server.ml`
- `.hill-climbing/careful-cobalt-stethoscope/JOURNAL.md`

Off limits:

- Do not weaken `checks.sh`.
- Do not reduce primary request count, stream count, body size, or success validation.
- Do not special-case benchmark data in production code.
- Do not accept a target win that regresses root/post_user/static_1k guardrails.

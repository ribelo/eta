# Hill-Climbing Prompt

Use `$hill-climbing` on `.hill-climbing/jittery-cerulean-comet`.

Call `create_goal` with an objective to improve
`h2_plain_echo_1k_p99_ms` without gaming or overfitting the benchmark. Read
`JOURNAL.md`, split the hypothesis space, run:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id jittery-cerulean-comet
```

Then update `JOURNAL.md` manually after each experiment.

Hill summary:

- Real target: H2 plain `echo_1k` p99 under one H2C connection with 16
  concurrent streams.
- Primary metric: `h2_plain_echo_1k_p99_ms`, lower is better.
- Workload: standalone Eta H2C probe, `oha --http-version 2 -c 1 -p 16`,
  POST `/echo` with a 1024-byte body, `n=20000`, median of 7 repeats.
- Secondary endpoints: `root`, `post_user`, and `static_1k` under the same
  shape, used to distinguish shared H2 scheduler/framing overhead from the
  echo request-body/write path.
- Guard: `checks.sh` runs release-profile HTTP Eio/common tests.

Scope:

- In scope: `lib/http_eio/h2_server_connection.ml`,
  `lib/http_eio/h2/multiplexer.ml`, `lib/http_eio/h2/writer.ml`,
  `lib/http/h2/`, `lib/http_eio/write.ml`, and focused tests for changed H2
  behavior.
- Out of scope: lowering concurrency/streams/request count, skipping request
  body reads, benchmark-only response caching, weakening H2 flow control,
  weakening checks, or changing H1/TLS measurement behavior.

First isolate the signal. The broad suite reported noisy p99 repeats
`1.096, 5.229, 3.671 ms`, so do not trust a single broad run as evidence.

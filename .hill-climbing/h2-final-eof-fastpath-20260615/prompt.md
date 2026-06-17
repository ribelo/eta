# Hill-Climbing Prompt

Validate and climb the H2C 1x16 `/echo` final-chunk EOF fast path.

Workload:

- H2C, one connection, 16 concurrent streams.
- `POST /echo`, 1024-byte request body, `content-length: 1024`.
- Repeated traced runs through `h2_probe.exe` and `h2_gap_client.exe`.

Primary metric:

- `h2_body_handler_to_available_p99_us` lower is better.

Secondary constraints:

- `h2_body_final_chunk_fraction` should stay at `1.0` for this workload.
- `h2_body_owner_eof_read_fraction` should stay at `0.0`; a nonzero value means
  `read_all` is again paying the owner-thread EOF read.
- Focused checks must pass.

Scope:

- In scope: `lib/http_eio/h2_server_connection.ml`,
  `lib/http/server_body.ml`, and hill scripts/journal.
- Off limits: weakening correctness checks, changing workload shape to hide
  latency, special-casing `/echo`, or skipping request body validation.

Run only:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-final-eof-fastpath-20260615
```

Update `JOURNAL.md` manually after each experiment with the hypothesis,
prediction, result, verdict, and keep/revert decision.

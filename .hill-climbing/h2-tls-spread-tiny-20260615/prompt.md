# H2 TLS Spread Tiny Hill

Use `$hill-climbing` on `.hill-climbing/h2-tls-spread-tiny-20260615`.
The objective is to reduce Eta H2 TLS tiny dynamic response p99 under
`c=16, connections=16, streams=1` without gaming or overfitting the benchmark.

Run measurements only through:

```bash
python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615
```

Primary metric:

```text
h2_tls_spread_tiny_p99_geomean_us
```

Lower is better. It is the geomean of Eta H2 TLS root, user_id, and post_user
median p99 for `c=16, conn=16, streams=1` from `server_load --quick --references
--h2-only`.

Guardrails:

- `h2_tls_spread_static_1k_p99_us`
- `h2_tls_spread_echo_1k_p99_us`
- `h2_tls_spread_tiny_rps_geomean`
- `h2_tls_spread_success`
- focused checks in `checks.sh`

Likely files in scope:

- `lib/http_eio/h2_server_connection.ml`
- `lib/http/h2/connection.ml`
- `lib/http/h2/connection.mli`
- `lib/http_eio/tls/tls_eio.ml`
- `http-testsuite/test/server_load/run.ml` only for reporting or attribution,
  not for weakening the workload

Off limits:

- Do not remove endpoints or reduce concurrency/request count in the benchmark.
- Do not special-case benchmark paths or server-load clients.
- Do not weaken response validation.
- Do not optimize body endpoints by regressing tiny dynamic responses, or vice
  versa, without documenting the tradeoff and rejecting the change.

Research method:

1. Read `JOURNAL.md`.
2. Split the hypothesis space before editing production code.
3. Prefer attribution probes that separate TLS/write cost, per-connection
   scheduling, client accounting, and over-flushing.
4. Update `JOURNAL.md` manually after every experiment.
5. Keep code changes only when the primary metric improves outside noise and
   guardrails hold.

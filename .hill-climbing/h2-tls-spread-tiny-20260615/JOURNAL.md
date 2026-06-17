# Research Journal: h2-tls-spread-tiny-20260615

## Hill

- Goal: reduce Eta H2 TLS p99 for tiny dynamic responses under the spread-client
  shape `c=16, connections=16, streams=1`, where post-H2O-gather rerank still
  shows Eta several times slower than nginx on p99.
- Primary metric: `h2_tls_spread_tiny_p99_geomean_us`
- Direction: lower
- Benchmark facade:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615`
- Session directory: `.hill-climbing/h2-tls-spread-tiny-20260615/`

## Anti-Gaming Contract

The goal is to improve the real H2 TLS spread-client tiny-response tail, not
merely to improve this script. Do not remove endpoints, reduce concurrency,
change TLS/protocol settings, special-case benchmark paths, cache invalidly,
skip response validation, weaken `server_load`, or trade away correctness.
Improvements must preserve H2 body endpoints and focused HTTP tests.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_tls_spread_tiny_p99_geomean_us` | Primary | lower | Keep only if the movement is outside noise and guardrails hold. | Geomean of Eta root/user_id/post_user median p99 under H2 TLS `c=16, conn=16, streams=1`. |
| `h2_tls_spread_tiny_vs_nginx_p99_ratio_geomean` | Reference | lower | Should move with the primary. | Same endpoints compared with nginx H2 TLS p99. |
| `h2_tls_spread_root_p99_us`, `h2_tls_spread_user_id_p99_us`, `h2_tls_spread_post_user_p99_us` | Diagnostic | lower | No dynamic endpoint should regress materially to make the geomean look better. | Endpoint-level p99 medians. |
| `h2_tls_spread_static_1k_p99_us`, `h2_tls_spread_echo_1k_p99_us` | Guardrail | non-regression | Reject changes that improve tiny responses by hurting body endpoints materially. | Body cases catch write/body-path regressions. |
| `h2_tls_spread_tiny_rps_geomean` | Guardrail | higher | Reject clear throughput regressions unless p99 win is large and explained. | Geomean of dynamic endpoint RPS. |
| `h2_tls_spread_success` | Correctness | equals 1 | Required. | All parsed rows must be successful server-load rows. |

Noise policy:

- Use repeated server-load samples and median p99 from the JSON output.
- Treat one-repeat spikes as attribution evidence only after they reproduce.
- Treat small wins inside the observed repeat spread as inconclusive unless they
  also simplify code and preserve all guardrails.

## Hypothesis Space

Root question:

> What mechanism still causes Eta H2 TLS spread-client tiny responses to have
> much worse p99 than nginx after the H2O-style owner gather?

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | TLS write/flush fixed cost dominates tiny responses | Each connection has one active stream, so tiny responses pay per-connection TLS/write overhead and wakeups without multiplex coalescing. | Server-side write/TLS spans cluster near client p99; plain H2 spread is much better than TLS spread for the same endpoints. | Server spans are far below client p99 or plain shows the same gap. | open |
| H2 | Connection-per-stream scheduling/wakeup dominates | The spread shape creates many owner/writer/reader interactions across 16 connections, causing scheduler or socket readiness stalls. | Slow p99 rows correlate with many connections and shrink under fewer connections/more streams at same concurrency. | `1x16`, `4x4`, and `16x1` show similar p99 after high-count repeats. | open |
| H3 | Benchmark/client accounting dominates | oha or client-side H2/TLS accounting adds tail not visible in Eta spans, especially with many TLS connections. | Custom or alternate client p99 is close to Eta server spans while oha remains high. | Two clients agree with oha and packet/server timestamps match client completion. | open |
| H4 | Eta H2 response emission still over-flushes by connection | H2O-style owner gather helped, but spread shape still emits too many tiny writes per connection. | Write syscall/write-job count per request is higher than references or drops with more buffering. | Write count is already minimal or reducing it does not move p99. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it. | A better split replaces it. | open |

## Experiment Selection Rule

Choose experiments by expected elimination power:

- Prefer attribution before server rewrites.
- Compare `16x1`, `4x4`, and `1x16` before assuming handler/body code.
- Separate server span, kernel/write span, and client-observed p99.
- Keep changes only when they improve the primary metric and preserve checks.

## Running Log

## E1: Baseline From Post-H2O H2 Comparison

### Hypothesis Space Split
- Parent question: what remains after the H2O-style gather improvement?
- Hypothesis under test: the remaining hill is H2 TLS spread-client tiny-response
  p99, not the already-improved one-connection multiplexed path.
- Rival hypotheses: the broad run is too noisy to justify a new hill, or body
  endpoints are now the only true H2 issue.
- Why this split is high value: post-H2O comparison against references shows a
  strong Eta-vs-nginx p99 ratio on root/user/post in `conn=16, streams=1`.

### Prediction Before Run
- Expected primary metric movement: no code change in this setup entry.
- Expected secondary metric movement: the hill should reproduce the high p99
  cluster and emit reference ratios.
- Distinguishing observation: dynamic H2 TLS spread rows remain several times
  nginx p99 while multiplexed dynamic rows are much lower.
- Falsifier: new hill baseline is near nginx or fails to reproduce spread p99.

### Attack
- Change or probe: created the hill facade around `server_load --quick
  --references --h2-only`, reducing the JSON to H2 TLS `c=16, conn=16,
  streams=1` metrics.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615`
- Checks command:
  `.hill-climbing/h2-tls-spread-tiny-20260615/checks.sh`
- Controls held constant: server-load validation, reference lifecycle, pinning,
  endpoint set, request counts, H2/TLS settings.

### Result
- Baseline run at `2026-06-15T13:47:54Z`.
- Primary:
  - `h2_tls_spread_tiny_p99_geomean_us = 1348.739`
  - `h2_tls_spread_tiny_vs_nginx_p99_ratio_geomean = 3.995`
- Endpoint p99:
  - Eta root `1364us`, nginx root `320us`, ratio `4.26x`.
  - Eta user_id `1249us`, nginx user_id `338us`, ratio `3.69x`.
  - Eta post_user `1440us`, nginx post_user `356us`, ratio `4.05x`.
- Guardrails:
  - Eta static_1k p99 `1326us`.
  - Eta echo_1k p99 `1617us`.
  - Eta tiny dynamic RPS geomean `29418`.
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T13:47:54Z`.

### Verdict
- Verdict: corroborated.
- Reason: the new hill reproduces the post-H2O reference gap. The issue is
  concentrated in H2 TLS `conn=16, streams=1` tiny dynamic p99 and remains about
  `4x` nginx.
- Hypothesis space update: proceed with attribution. The next split should test
  whether TLS itself dominates or whether the spread connection shape dominates.
- Commit/revert decision: keep hill setup.
- Next experiment: compare TLS/plain, shape matrix, server write spans, and
  backend sensitivity before editing production code.

## E2: Shape, TLS, and Write-Path Attribution

### Hypothesis Space Split
- Parent question: where does the remaining `conn=16, streams=1` p99 live?
- Hypothesis under test: the hill is dominated by tiny per-connection writes and
  Eio/backend scheduling around those writes, not by H2 handler/body code.
- Rival hypotheses:
  - TLS fixed cost alone dominates.
  - Client/load placement creates most of the p99.
  - H2 frame generation still over-flushes in a way code can directly coalesce.
- Why this split is high value: slow writes on root avoid handler/body paths, so
  they isolate response emission, TLS/raw flow, and scheduler behavior.

### Prediction Before Run
- Expected primary metric movement: no production code change.
- Expected secondary metric movement:
  - Plain spread should still be high if the shape dominates.
  - Server write spans should explain a large share of client p99 if Eta is on
    the hot path.
  - POSIX backend may shift the latency if io_uring completion scheduling is a
    contributor.
- Distinguishing observation:
  - TLS-only: plain spread collapses.
  - Client-only: server write spans are far below client p99.
  - Write/backend: server `flow_write` or writer wait is near p99 and changes by
    backend/pinning.
- Falsifier: all server spans are small and backend/pinning does not move p99.

### Attack
- Shape matrix source: baseline server-load JSON from E1.
- Server root trace:
  `ETA_H2_16X1_TRACE_REQUESTS=12000 ETA_H2_16X1_CONNECTIONS=16 ETA_H2_16X1_STREAMS=1 ETA_H2_16X1_TRACE_MODE=tls bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_tls.sh`
- Plain control: same command with `ETA_H2_16X1_TRACE_MODE=plain`.
- Slow-write probe:
  `ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US=500 ... trace_root_slow_write.sh`
- Pinning/backend probe:
  `ETA_H2_16X1_PINNING_REQUESTS=12000 bash .hill-climbing/h2-16x1-p99-attribution-20260615/pinning_sensitivity.sh`
- Full POSIX hill control:
  `EIO_BACKEND=posix python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615`
- Syscall probe:
  `ETA_H2_16X1_TRACE_REQUESTS=3000 ... trace_root_syscalls.sh`
- Perf sched probe:
  `trace_root_perf_sched.sh`

### Result
- Shape matrix from E1:
  - TLS spread root/user/post p99: `1364/1249/1440us`.
  - Plain spread root/user/post p99: `1161/1257/1108us`.
  - TLS multiplexed `conn=1, streams=16` root/user/post p99:
    `257/293/265us`.
  - Conclusion: TLS adds cost, but the spread shape dominates.
- TLS root trace, default backend:
  - client p99 `1902us`.
  - response-write p99 `1196us`.
  - flow-write p99 `1106us`.
  - write-job wait p99 `66us`.
- Plain root trace:
  - client p99 `1511us`.
  - response-write p99 `1095us`.
  - flow-write p99 `1033us`.
  - write-job wait p99 `52us`.
- Load-range root trace:
  - client p99 `1461us`.
  - response-write p99 `1016us`.
  - flow-write p99 `927us`.
- Slow-write probe:
  - client p99 `1222us`.
  - slow writes above `500us`: `129 / 12000 = 1.075%`.
  - slow-write p50/p95/p99: `1051/1658/1963us`.
  - median slow-write payload: `14` bytes.
- Pinning/backend probe:
  - default custom-client total p99 `3172us`.
  - best widened-load/POSIX total p99 `1497us`.
  - default `flow_to_rx` p99 `2080us`; widened load `flow_to_rx` p99 `11us`.
  - Interpretation: load placement amplifies the symptom but does not remove
    the ~1.5ms server-side/write-side hill.
- POSIX full hill control:
  - primary `1348.739us -> 1285.324us` (`~4.7%` better).
  - tiny RPS geomean `29418 -> 27540` (worse).
  - static p99 `1326us -> 1471us` (worse).
  - echo p99 `1617us -> 1503us` (better).
- Syscall probe, strace-perturbed:
  - client p99 `8078us`.
  - app slow-write p99 `1931us`.
  - raw `write` syscall p99 `114us`.
  - `io_uring_enter` showed large tails, but strace perturbation makes this
    suggestive rather than decisive.
- Perf sched:
  - unavailable: `perf_event_paranoid=2`, `perf_record_status=129`.

### Verdict
- Verdict: split-needed.
- Reason: pure TLS cost is falsified; plain spread is still high. Pure
  client-side accounting is also falsified; server response/flow-write spans are
  a major share of p99. POSIX and load-range controls show scheduling/backend
  sensitivity, but they are not a production fix because they reduce neither the
  reference gap nor all guardrails enough.
- Hypothesis space update:
  - H1 narrows from "TLS dominates" to "tiny raw-flow writes through the current
    backend dominate, with TLS adding some cost."
  - H2 remains live: the spread connection shape creates many independent tiny
    writes that the one-server-core benchmark handles poorly.
  - H3 remains live only as an amplifier, not root cause.
  - H4 narrows: root has only one tiny write, so generic H2 coalescing cannot
    eliminate the hill for empty responses.
- Commit/revert decision: no production code change from this experiment.
- Next experiment: isolate whether the remaining tiny-write delay is specific to
  the H2 server writer architecture by comparing an H2 root response write path
  with an equivalent direct TLS tiny-write loop, or by adding a narrow probe that
  writes the same 14-byte TLS payload pattern outside H2.

## E3: Direct Tiny TLS and Custom H2 Client Split

### Hypothesis Space Split
- Parent question: is the spread p99 caused by the lower Eta TLS/raw-flow write
  path, H2 server architecture, or oha client behavior?
- Hypothesis under test: the lower TLS flow can write 14-byte responses cheaply;
  the remaining delay requires H2-specific request/response machinery or H2
  client/server interaction.
- Rival hypotheses:
  - direct tiny TLS writes reproduce the H2 p99, proving TLS/raw-flow is enough;
  - direct split reader/writer reproduces the H2 p99, proving the architecture
    rather than H2 state is enough;
  - custom H2 client collapses p99, proving oha-specific client accounting.
- Why this split is high value: root responses are effectively one tiny H2
  response write, so an equivalent tiny TLS protocol can isolate the lower layer.

### Prediction Before Run
- Expected primary metric movement: no production optimization in this
  attribution experiment.
- Expected secondary metric movement:
  - If TLS/raw-flow is the hill, direct TLS server-write p99 should be near H2
    flow-write p99.
  - If oha is the hill, the custom H2 spread client should collapse total p99.
  - If H2 machinery is the hill, direct TLS remains low and custom H2 remains
    high.
- Distinguishing observation: direct tiny TLS p99 versus H2 root p99 under the
  same `16 connections x 1 stream` shape.
- Falsifier: direct TLS and custom H2 both collapse, leaving no server-side hill.

### Attack
- Change or probe:
  - added `http-testsuite/test/server_load/tiny_tls_probe.ml`;
  - added `.hill-climbing/h2-tls-spread-tiny-20260615/trace_tiny_tls_write.sh`;
  - added `.hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_spread.sh`.
- Important measurement correction: fixed H2 `flow_write_us` and slow-write
  tracing to start after `trace_write_job_start` has finished writing trace
  lines, so the span brackets the actual `Eio.Flow.write`.
- Benchmark commands:
  - `ETA_TINY_TLS_REQUESTS=12000 ETA_TINY_TLS_CONNECTIONS=16 ETA_TINY_TLS_REPEATS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_tiny_tls_write.sh`
  - `ETA_H2_CUSTOM_SPREAD_REQUESTS=12000 ETA_H2_CUSTOM_SPREAD_CONNECTIONS=16 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_spread.sh`
- Checks command: build probes and focused HTTP tests via hill `checks.sh`.
- Controls held constant: 16 connections, one in-flight request per connection,
  12k requests, server/load pinning.

### Result
- Direct tiny protocol, corrected run:
  - direct TLS sequential: total p99 `437us`, server-write p99 `124us`.
  - direct TLS split reader/writer: total p99 `363us`, server queue-wait p99
    `28us`, server-write p99 `120us`.
  - direct plain split: total p99 `185us`, server queue-wait p99 `29us`,
    server-write p99 `73us`.
- Same script's H2 root trace:
  - oha p99 `1559us`.
  - H2 response-write p99 `1091us`.
  - H2 flow-write p99 `1007us`.
  - H2 write-job wait p99 `55us`.
- Custom H2 spread client:
  - success `1`.
  - total p99 `3296us`.
  - `t1 -> t2` p99 `3284us`.
  - H2 response-write p99 `1174us`.
  - H2 flow-write p99 `1056us`.
  - H2 write-job wait p99 `50us`.
- Checks: probe builds passed during development; full hill checks run after
  final script update.

### Verdict
- Verdict: split-needed.
- Reason: direct Eta TLS writes are cheap, including a split read/write fiber
  variant. oha is not sufficient as an explanation because the custom H2 client
  also shows high p99. The remaining hill is inside H2-specific interaction
  between the server state machine, TLS flow, and H2 client behavior, not generic
  raw TLS writes.
- Hypothesis space update:
  - H1 is mostly falsified as a lower TLS/raw-flow write problem.
  - H3 is mostly falsified as oha-specific, though client-side H2 behavior can
    amplify the tail.
  - H2/H4 remain live but need a narrower split: H2 read/write interleaving,
    state-machine output timing, or protocol-level client/server pacing.
- Commit/revert decision: keep measurement probes and the H2 trace timing fix.
- Next experiment: test whether preventing H2 read-ahead while a response write
  is pending improves the spread hill.

## E4: H2 Reader Ack Fence

### Hypothesis Space Split
- Parent question: is the H2 spread tail caused by the reader issuing the next
  TLS/socket read while response writes are pending?
- Hypothesis under test: waiting for the owner to acknowledge an ingress chunk
  before the reader loops will reduce read/write interleaving and lower p99.
- Rival hypotheses:
  - read-ahead is not the cause;
  - read-ahead is useful and removing it hurts throughput/tail;
  - the real issue is later in H2 output/state-machine pacing.
- Why this split is high value: it directly tests the main architectural
  difference between direct sequential TLS and H2 handling.

### Prediction Before Run
- Expected primary metric movement: lower
  `h2_tls_spread_tiny_p99_geomean_us` if read/write interleaving is causal.
- Expected secondary metric movement: static/echo and RPS should not materially
  regress.
- Distinguishing observation: spread p99 falls without changing H2 frame output.
- Falsifier: primary or guardrails worsen.

### Attack
- Change or probe: temporarily changed H2 `reader_loop` so after enqueuing
  `Ingress`, it awaited the owner ack before looping to the next read.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615`
- Checks command: included in the runner.
- Controls held constant: hill facade and reference comparison unchanged.

### Result
- Baseline from E1: primary `1348.739us`.
- Ack-fence run at `2026-06-15T14:08:44Z`:
  - primary `1377.104us` (worse).
  - root/user/post p99 `1340/1424/1369us`.
  - static_1k p99 `1556us` (worse than baseline `1326us`).
  - echo_1k p99 `1688us` (worse than baseline `1617us`).
  - checks passed.

### Verdict
- Verdict: rejected.
- Reason: the primary moved the wrong way and body guardrails worsened. H2
  read-ahead is not the fix for this hill.
- Hypothesis space update: simple reader ack fencing is falsified. Continue with
  narrower H2 output/state-machine pacing or TLS/H2 interaction probes.
- Commit/revert decision: reverted the ack-fence code. Kept only measurement
  probes and corrected trace timing.
- Next experiment: compare H2 output job bytes/frame patterns and TLS WANT_READ
  behavior during H2 writes against the direct tiny protocol.

## E5: TLS IO Pattern and H2 Response Write Split

### Hypothesis Space Split
- Parent question: why are H2 root writes slow when direct tiny TLS writes are
  cheap?
- Hypothesis under test: H2 root writes differ at the TLS/OpenSSL layer: bigger
  records, WANT_READ/WANT_WRITE retries, or control-frame writes contaminate the
  response p99.
- Rival hypotheses:
  - H2 response writes are the same tiny TLS records as direct writes, and the
    delay is scheduling/fiber/GC pressure around H2.
  - H2 control frames, not response writes, dominate the observed flow p99.
- Why this split is high value: if H2 hits OpenSSL WANT retries or larger TLS
  records, the next code hill is TLS/protocol interaction. If not, the next hill
  is H2 runtime scheduling/pressure.

### Prediction Before Run
- Expected primary metric movement: none; attribution only.
- Expected secondary metric movement:
  - If TLS/OpenSSL behavior differs, H2 should show WANT retries or larger raw
    writes than direct TLS.
  - If control frames dominate, response-only `h2_write_flow_complete
    stream_id=...` p99 should be much lower than all-write p99.
- Distinguishing observation: direct and H2 raw TLS write bytes/durations plus
  response-only H2 flow-write distribution.
- Falsifier: same TLS record size, no WANT retries, and response-only H2 flow
  writes still high.

### Attack
- Change or probe:
  - added `tls_ssl_write_retry` trace lines for OpenSSL WANT_READ/WANT_WRITE
    under `ETA_TLS_IO_TRACE_PATH`;
  - extended `trace_tiny_tls_write.sh` to capture direct/H2 TLS IO logs;
  - parsed H2 response writes separately from control writes.
- Benchmark command:
  `ETA_TINY_TLS_REQUESTS=12000 ETA_TINY_TLS_CONNECTIONS=16 ETA_TINY_TLS_REPEATS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_tiny_tls_write.sh`
- Controls held constant: 16 connections, one active request per connection,
  same server/load pinning.

### Result
- Direct TLS sequential:
  - total p99 `489us`.
  - server-write p99 `114us`.
  - TLS raw-write p99 `136us`.
  - raw TLS bytes p50/p99 `36/36`.
  - WANT_READ/WANT_WRITE `0/0`.
- Direct TLS split:
  - total p99 `499us`.
  - server queue-wait p99 `29us`.
  - server-write p99 `162us`.
  - TLS raw-write p99 `165us`.
  - raw TLS bytes p50/p99 `36/36`.
  - WANT_READ/WANT_WRITE `0/0`.
- H2 root:
  - oha p99 `1559us`.
  - response-write p99 `1175us`.
  - response flow-write p99 `1096us`.
  - write-job wait p99 `56us`.
  - TLS raw-write p99 `1113us`.
  - raw TLS bytes p50/p99 `36/36`.
  - WANT_READ/WANT_WRITE `0/0`.
- H2 response/control split from `server-h2.log`:
  - response flow-write p99 `1096us`, n=`12000`.
  - control flow-write p99 `476us`, n=`17`.
  - response job bytes p50/p99 `14/14`.
  - control job bytes p50/p99 `58/58`.
  - response write-ready p99 `6us`.
  - response job-wait p99 `55us`.

### Verdict
- Verdict: corroborated narrower scheduling/pressure hypothesis.
- Reason: H2 and direct TLS write the same 36-byte TLS records and neither hits
  OpenSSL WANT_READ/WANT_WRITE. Control frames do not explain the response tail:
  response-only flow-write p99 is still about `1.1ms`. The remaining delta is
  not H2 frame size, TLS record size, or OpenSSL retry behavior.
- Hypothesis space update:
  - H1 is falsified for TLS/OpenSSL mechanics.
  - H4 is falsified for control-frame contamination.
  - Live hypothesis: H2-specific fiber/runtime/GC pressure around many tiny
    response writes causes raw flow writes to complete later than the direct
    tiny protocol.
- Commit/revert decision: keep the env-gated TLS IO trace event and parser
  improvements.
- Next experiment: reduce H2 per-request scheduling pressure, starting with
  handler scheduling, but reject anything that hangs or hurts guardrails.

## E6: Env-Gated Inline Closed-Body Handler Probe

### Hypothesis Space Split
- Parent question: does per-request handler fiber scheduling materially cause
  the H2 spread write tail?
- Hypothesis under test: for requests whose body is already closed, running the
  handler path on the owner instead of forking a handler fiber will reduce H2
  tiny-response p99.
- Rival hypotheses:
  - handler scheduling is not the cause;
  - inlining arbitrary handlers on the owner is unsafe and can deadlock or
    starve H2 processing;
  - the real pressure is elsewhere in H2/TLS state-machine interaction.
- Why this split is high value: direct tiny TLS avoids the Eta handler/runtime
  path entirely and is much faster.

### Prediction Before Run
- Expected primary metric movement: lower if handler-fiber scheduling is the
  cause.
- Expected secondary metric movement: checks complete normally.
- Distinguishing observation: full hill run completes with lower primary.
- Falsifier: run hangs, primary worsens, or guardrails fail.

### Attack
- Change or probe: temporarily added `ETA_H2_INLINE_CLOSED_BODY_HANDLER=1` path
  that ran already-closed-body handlers on the owner.
- Benchmark command:
  `ETA_H2_INLINE_CLOSED_BODY_HANDLER=1 python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615`
- Controls held constant: normal hill facade.

### Result
- The run exceeded the normal quick comparison time and remained stuck in
  `server_load/run.exe`; it was stopped manually.
- No valid primary metric was produced.

### Verdict
- Verdict: rejected.
- Reason: inlining the handler on the H2 owner is not a safe production
  direction. The hang is itself a falsifier for this approach.
- Hypothesis space update: handler-fiber overhead remains possible as a cost,
  but owner inlining is not the correct mechanism. Future experiments should
  measure handler/runtime delay or reduce allocation/fiber pressure without
  moving arbitrary handlers onto the owner.
- Commit/revert decision: reverted the inline-handler code completely.
- Next experiment: attribute H2 runtime pressure with low-overhead counters
  around handler fork/run/response-start and GC allocation, then choose a fix
  that preserves handler isolation.

## E7: H2O Reference Audit

### Question
- Can `.reference/h2o` explain the remaining H2 TLS tiny-response spread p99
  after Eta's H2O-style owner gather?

### Findings
- H2O's stream path does not write directly from each response handler. In
  `.reference/h2o/lib/http2/stream.c`, `finalostream_send` flattens response
  headers into the connection write buffer, queues body vectors on the stream,
  and registers the stream for a proceed callback.
- H2O then activates the stream scheduler from
  `.reference/h2o/lib/http2/connection.c::h2o_http2_conn_register_for_proceed_callback`.
  The connection writer drains active streams into `conn->_write.buf` and sends
  one `h2o_socket_write`, moving the buffer to `buf_in_flight`.
- H2O's write trigger is intentionally gathered: `request_gathered_write` arms a
  zero-timeout write only if the socket is not already writing, and the
  non-libuv path can use `h2o_socket_notify_write` to emit on the next write
  notification boundary.
- H2O also has socket-level latency machinery in
  `.reference/h2o/lib/common/socket.c`: TCP info, `TCP_NOTSENT_LOWAT`, suggested
  write size, and suggested TLS record payload size. That path is real prior
  art, but current Eta traces make it less likely as the immediate fix because
  both direct TLS and H2 root write the same 36-byte TLS records and show no
  OpenSSL WANT_READ/WANT_WRITE retries.

### Eta Mapping
- Eta already carries the first-order H2O lesson from the prior hill: bounded
  owner-command gathering (`handle_command_batch`) feeds the existing H2
  contiguous write buffer before one writer-fiber `Eio.Flow.write`.
- The current hill is post-gather. Therefore, "copy H2O's gather" is not the
  next step; it has already been tried and kept.
- Remaining concrete differences worth measuring:
  - H2O keeps protocol emission and socket write orchestration in one event-loop
    object with a `buf_in_flight`; Eta crosses owner fiber -> write-job stream
    -> writer fiber -> TLS flow.
  - H2O's callback completion is event-loop native; Eta observes the tail inside
    `Eio.Flow.write` for H2, while direct tiny TLS writes are much cheaper.
  - H2O has optional kernel/TCP latency tuning; Eta currently does not expose an
    equivalent for this TLS flow.

### Verdict
- Verdict: useful prior art, not an immediate production-code patch.
- Reason: the already-kept H2O-style gather explains the older 16x1 win, but
  the current p99 remains after that boundary. The new split should compare
  Eta's fiber/write-job/TLS-flow orchestration against H2O's single event-loop
  buffered writer, and only then consider socket-level latency tuning.
- Next experiment: add low-overhead counters for one H2 TLS root run around
  owner response completion, write-job enqueue/start, `Eio.Flow.write`, and GC
  stats, then decide whether the remaining p99 is writer-fiber scheduling, GC
  pressure, or socket/TCP latency.

## E8: H2 Runtime and GC Attribution Probe

### Hypothesis Space Split
- Parent question: does the remaining H2 TLS tiny-response tail live before the
  socket write, inside handler/runtime scheduling or GC pressure?
- Hypothesis under test: handler fiber scheduling, handler runtime, response
  preparation, or owner response-command latency accounts for most of the
  missing p99.
- Rival hypotheses:
  - the missing p99 lives in writer-fiber/socket/TLS-flow orchestration after
    the response is already ready;
  - GC collection frequency is the dominant cause;
  - the socket/TCP small-write boundary dominates independently of handler work.
- Why this split is high value: H2O keeps protocol emission and socket write
  orchestration inside one event-loop writer. Eta crosses handler fiber ->
  owner command -> write-job stream -> writer fiber -> TLS flow. This probe
  measures the pre-write part of that chain.

### Prediction Before Run
- If handler/runtime scheduling is the hill, handler queue/runtime/prepare or
  response-owner wait p99 should approach the client/write p99.
- If GC frequency is the hill, increasing the minor heap should reduce
  collection count and lower write/client p99.
- Falsifier: handler/runtime segments stay far below p99 and a larger minor
  heap does not improve the tail.

### Attack
- Change or probe:
  - added env-gated `ETA_H2_RUNTIME_TRACE_PATH` aggregate checkpoints in
    `lib/http_eio/h2_server_connection.ml`;
  - added
    `.hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_runtime_probe.sh`;
  - checkpoints flush every 128 completed handlers so the existing trace harness
    can kill the server after oha while still preserving latest per-connection
    aggregate rows.
- Benchmark command:
  `ETA_H2_RUNTIME_REQUESTS=12000 ETA_H2_RUNTIME_CONNECTIONS=16 ETA_H2_RUNTIME_STREAMS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_runtime_probe.sh`
- GC split command:
  `OCAMLRUNPARAM=s=4194304 ETA_H2_RUNTIME_REQUESTS=12000 ETA_H2_RUNTIME_CONNECTIONS=16 ETA_H2_RUNTIME_STREAMS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_runtime_probe.sh`
- Checks command:
  `bash .hill-climbing/h2-tls-spread-tiny-20260615/checks.sh`

### Result
- Default probe, result dir
  `.hill-climbing/h2-tls-spread-tiny-20260615/runtime-probe-results/20260615-163124`:
  - success `1`, 16 connections, checkpoint coverage `10458/12000` requests.
  - oha p99 `1795us`.
  - response write-complete p99 `1133us`.
  - flow-write p99 `1022us`.
  - write-job wait p99 `240us`.
  - ingress owner-ack p99 `222us`.
  - handler queue p99 max across connections `1us`.
  - handler runtime p99 max `1us`.
  - handler prepare p99 max `1us`.
  - response-owner wait p99 max `272us`, median connection p99 `193.5us`.
  - handler total p99 max `273us`.
- Larger minor heap probe:
  - oha p99 worsened to `2962us`.
  - response write-complete p99 worsened to `2111us`.
  - flow-write p99 worsened to `1881us`.
  - handler/runtime/prepare remained `1us` p99 max.
  - minor and major collection counts dropped, so collection frequency reduction
    did not translate to a tail win.
- Checks: passed. `git diff --check` passed.

### Verdict
- Verdict: handler/runtime and GC-frequency hypotheses rejected for the current
  hill.
- Reason: handler queue, runtime, and preparation are microsecond-scale, while
  the observed tail remains in `Eio.Flow.write` after the response is already
  ready. The response-owner command wait is nonzero but still far below the
  client/write p99 and does not explain the ~1ms flow-write p99. Enlarging the
  minor heap reduced collection counts but worsened the write/client tail.
- Caveat: GC word deltas are process-global and overlap across concurrent
  connections, so the per-request word figures are qualitative only. The
  collection-count falsifier is stronger than the word-per-request estimate.
- Hypothesis space update:
  - H2 handler scheduling/runtime is no longer a plausible primary hill.
  - GC frequency is not the immediate fix.
  - The next live split is writer-fiber/socket orchestration: either the
    owner->write-job->writer fiber boundary is adding tail, or the kernel/TCP
    small TLS record write boundary is.
- Commit/revert decision: keep the env-gated runtime probe and script; reject
  the `OCAMLRUNPARAM` tuning as a fix.
- Next experiment: run a writer-boundary probe. Best options are an env-gated
  owner-inline H2 write path for tiny writes, or a strace/perf syscall split
  around raw socket writes. Keep it attribution-first and reject any change that
  hangs or hurts guardrails.

## E9: Strace Syscall Boundary Probe

### Hypothesis Space Split
- Parent question: can syscall-level tracing separate kernel write time from
  Eta/Eio writer scheduling time without modifying production code?
- Hypothesis under test: running the H2 TLS root probe under `strace` will show
  whether syscall submission itself has millisecond p99.
- Rival hypotheses:
  - `strace` distorts Eio/io_uring enough that the measurement is unusable;
  - the relevant latency is in io_uring completion/scheduler behavior, not in a
    simple `write(2)`/`sendmsg(2)` duration.

### Attack
- Change or probe: added
  `.hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_syscall_probe.sh`.
  The first attempt with 4000 requests left the strace wrapper/server child
  alive after oha exited, so the script was fixed to run strace in its own
  process group and kill the group on cleanup. The successful probe used 500
  requests to cap overhead.
- Command:
  `ETA_H2_SYSCALL_REQUESTS=500 ETA_H2_SYSCALL_CONNECTIONS=16 ETA_H2_SYSCALL_STREAMS=1 ETA_H2_SYSCALL_TIMEOUT=5s bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_syscall_probe.sh`

### Result
- Result dir:
  `.hill-climbing/h2-tls-spread-tiny-20260615/syscall-probe-results/20260615-163742`.
- Under strace:
  - oha p99 `11785us`.
  - response write-complete p99 `6874us`.
  - flow-write p99 `5907us`.
  - write-job wait p99 `493us`.
  - traced `write` p99 `109us`, but these writes include tracing/logging and do
    not isolate socket writes.
  - traced `io_uring_enter` p99 `46264us` from only 70 samples, consistent with
    heavy tracing distortion rather than a usable request-level attribution.
- Cleanup check: no strace, probe server, oha, or server-load process remained.

### Verdict
- Verdict: rejected as an attribution method.
- Reason: strace changes the hill by an order of magnitude. The run confirms
  that syscall tracing at this layer is too intrusive for p99 attribution with
  Eio/io_uring.
- Hypothesis space update: keep writer/socket orchestration live, but do not use
  strace as evidence for it. The next better split is an env-gated writer-boundary
  A/B inside Eta, or a lower-overhead eBPF/perf off-CPU sample if available.
- Commit/revert decision: keep the process-group-safe script only as a
  documented negative probe; do not use its latency numbers for optimization
  decisions.
- Next experiment: env-gated writer-boundary A/B. Test whether removing the
  owner -> write-job stream -> writer-fiber hop for tiny H2 writes improves p99,
  while rejecting immediately if it hangs or regresses guardrails.

## E10: Env-Gated Direct Owner Tiny-Write A/B

### Hypothesis Space Split
- Parent question: is the remaining tail caused by the owner -> write-job stream
  -> writer-fiber hop?
- Hypothesis under test: for tiny H2 write jobs, writing directly from the owner
  fiber will reduce dynamic H2 TLS spread p99 without hurting body endpoints.
- Rival hypotheses:
  - the write-job hop adds measurable wait but is not the dominant p99 source;
  - owner-direct writes improve tiny root but hurt body endpoint scheduling;
  - the true hill is TLS/socket completion timing after the write starts.

### Prediction Before Run
- If the writer-fiber hop is the hill, direct owner writes should collapse
  `write_job_wait_us`, lower flow/client p99, and preserve static/echo guardrails.
- Falsifier: guard endpoints regress, or flow/client p99 remains dominated by
  `Eio.Flow.write` after write-job wait disappears.

### Attack
- Change or probe:
  - temporarily added env-gated `ETA_H2_DIRECT_OWNER_WRITE_MAX_BYTES=256`;
  - first version direct-wrote all small H2 write jobs;
  - second version narrowed to small write jobs containing an END_STREAM frame;
  - both variants were measured through the focused runtime trace and the real
    hill facade.
- Naive full-hill command:
  `ETA_H2_DIRECT_OWNER_WRITE_MAX_BYTES=256 python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-spread-tiny-20260615`
- Refined full-hill command: same command after adding the END_STREAM condition.

### Result
- Focused paired trace, naive direct owner writes:
  - baseline just before A/B: oha p99 `2131us`, write-complete p99 `1329us`,
    flow-write p99 `1181us`, write-job wait p99 `269us`.
  - direct-owner: oha p99 `1554us`, write-complete p99 `1106us`, flow-write p99
    `1087us`, write-job wait p99 `1us`.
  - Conclusion: the hop is measurable, but flow-write p99 remains around 1ms.
- Full hill, naive direct owner writes:
  - primary `1273.757us` versus baseline `1348.739us`.
  - static_1k p99 `1612us`.
  - echo_1k p99 `2972us`.
  - Verdict inside experiment: rejected because echo guardrail regressed badly.
- Focused trace, END_STREAM-narrowed direct owner writes:
  - oha p99 `1711us`.
  - write-complete p99 `1274us`.
  - flow-write p99 `1260us`.
  - write-job wait p99 `1us`.
- Full hill, END_STREAM-narrowed direct owner writes:
  - primary `1326.608us`.
  - root/user/post p99 `1206/1419/1365us`.
  - static_1k p99 `1927us`.
  - echo_1k p99 `1906us`.
  - dynamic RPS geomean `28036`, below the baseline `29418`.
  - checks passed, but guardrails failed.

### Verdict
- Verdict: rejected and reverted.
- Reason: removing the writer-fiber hop collapses write-job wait, proving that
  part of the latency is real, but it does not remove the dominant flow-write
  tail and it regresses body guardrails. This is not a production climb.
- Hypothesis space update:
  - owner -> writer-fiber queueing contributes tens to hundreds of microseconds
    in p99, but is not the remaining ~1ms hill.
  - The remaining hill is after write start: TLS flow/socket completion timing
    or Eio scheduling around small TLS record writes.
  - Owner-direct writes are not the fix because they trade tail between endpoint
    classes.
- Commit/revert decision: removed the env-gated direct-write behavior from the
  code. Keep only the journal evidence.
- Next experiment: lower-overhead write-completion attribution inside the TLS
  wrapper or Eio backend boundary, not strace and not owner-direct writes.

## E11: Low-Overhead TLS Aggregate Write Split

### Hypothesis Space Split
- Parent question: does the H2 TLS tiny-response p99 live inside OpenSSL,
  TLS write mutex contention, BIO draining, or the raw Eio flow write?
- Hypothesis under test: in the 1-connection / 16-stream H2 TLS root shape,
  the remaining tail is visible inside TLS aggregate write timings.
- Rival hypotheses:
  - TLS/OpenSSL is cheap and the gap is above or below the TLS wrapper;
  - the prior synchronous H2 trace was adding p99 overhead;
  - direct tiny TLS has similar raw-write outliers, but H2 1x16 may not.

### Attack
- Change or probe:
  - added `ETA_TLS_AGG_TRACE_PATH`, an env-gated aggregate TLS probe in
    `lib/http_eio/tls/tls_eio.ml`;
  - added `.hill-climbing/h2-tls-spread-tiny-20260615/trace_tls_aggregate_probe.sh`;
  - adjusted the H2 side to default to the real hill shape: 1 connection,
    16 streams;
  - switched the H2 trace harness toward buffered phase tracing for lower
    overhead and added missing write-ready/write-complete phase events.
- Command:
  `ETA_TLS_AGG_REQUESTS=12000 ETA_TLS_AGG_CONNECTIONS=16 ETA_TLS_AGG_REPEATS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_tls_aggregate_probe.sh`

### Result
- Final 1x16 run:
  - oha p99 `1114us`.
  - H2 server response-start -> write-complete p99 `497us` in the buffered
    phase trace sample.
  - H2 flow-write p99 `56us`.
  - H2 TLS aggregate raw-write p99 `16us`.
  - H2 TLS aggregate SSL-write p99 `1us`.
  - H2 TLS aggregate write-mutex wait p99 `13us`.
  - Direct tiny TLS comparator p99 `1014us`, with raw-write p99 connection max
    `947us`.
- Result dir:
  `.hill-climbing/h2-tls-spread-tiny-20260615/tls-aggregate-results/20260615-170329`.
- Caveat: the buffered phase trace can lose the final not-yet-flushed chunk when
  the probe kills the server, so use the TLS aggregate metrics as the hard
  evidence here and the phase rows as directional.

### Verdict
- Verdict: TLS/OpenSSL/write-mutex/raw-write rejected for the H2 1x16 hill.
- Reason: in the actual H2 1x16 TLS root shape, the TLS p99 is tiny compared
  with the client-observed p99. The previous larger flow/server spans were at
  least partly trace-method dependent.
- Hypothesis space update:
  - do not optimize OpenSSL calls, TLS mutexes, or response body copies for this
    hill;
  - the remaining gap is either client-side receive/wakeup/accounting, kernel
    TCP scheduling, or H2 request/response turn timing above the TLS raw write.
- Commit/revert decision: keep the env-gated aggregate TLS probe and harness;
  it is measurement-only and establishes a reusable boundary check.
- Next experiment: run the exact H2 TLS root shape through a second H2 client
  with client-side checkpoints to decide whether the ~1ms p99 is oha-specific.

## E12: Custom H2 TLS 1x16 Client Attribution

### Hypothesis Space Split
- Parent question: is the remaining ~1ms H2 TLS root p99 an oha/client
  accounting artifact, or real client-observed 1x16 behavior?
- Hypothesis under test: a tiny custom H2 TLS client with per-request
  checkpoints will reproduce or reject oha's p99 in the same 1-connection /
  16-stream root shape.
- Rival hypotheses:
  - oha is uniquely slow or accounts H2 multiplexed completions differently;
  - Eta's server write path is still hiding a p99 not visible in TLS aggregate;
  - the gap is between server write completion and client raw receive wakeup.

### Attack
- Change or probe:
  - added
    `.hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_1x16_tls_root.sh`;
  - reused `http-testsuite/test/server_load/h2_gap_client.ml` in TLS mode with
    `GET /`, empty body, 12k requests, 16 concurrent streams on one connection;
  - recorded client checkpoints `t0` request queued, `t1` request fully written,
    `rx_headers` raw response HEADERS observed, `t2` response handler called,
    and `t3` response body complete.
- Command:
  `ETA_H2_CUSTOM_1X16_REQUESTS=12000 ETA_H2_CUSTOM_1X16_CONCURRENCY=16 ETA_H2_CUSTOM_1X16_REPEATS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_1x16_tls_root.sh`

### Result
- Result dir:
  `.hill-climbing/h2-tls-spread-tiny-20260615/custom-h2-1x16-tls-root-results/20260615-170618`.
- Custom client:
  - success `1`, samples `12000`, errors `0`.
  - total p50/p95/p99: `100us / 222us / 1124us`.
  - request queued -> request written p99: `33us`.
  - request written -> response handler p99: `1115us`.
  - request written -> raw response headers observed p99: `1112us`.
  - raw response headers -> response handler p99: `5us`.
  - response handler -> body complete p99: `1us`.
- Server-side in the same run:
  - response-start -> write-complete p99: `122us`.
  - write-ready p99: `46us`.
  - write-job wait p99: `10us`.
  - flow-write p99: `31us`.

### Verdict
- Verdict: oha-specific accounting rejected; production server write path
  rejected for this hill.
- Reason: a second H2 TLS client reproduces the ~1.1ms p99, but nearly all of
  it is request-written -> client raw response headers observed. The server
  write path completes around `122us` p99 in the same shape, and client H2 demux
  after raw receive is only `5us` p99.
- Hypothesis space update:
  - the live hill is below Eta's H2/TLS application write boundary: kernel TCP
    scheduling, client read wakeup, or loopback/TLS record delivery timing for
    one busy TCP connection with 16 streams;
  - server handler/body/copy/TLS-write optimizations are not justified by this
    evidence.
- Commit/revert decision: keep the custom 1x16 client hill as the guardrail for
  future socket/kernel experiments.
- Next experiment: an H2O-inspired socket/kernel matrix: compare TLS vs plain
  and 1x16 vs 4x4 vs 16x1 using the custom client's `t1 -> rx_headers` metric,
  then test TCP-not-sent / write-read wakeup hypotheses only if the gap follows
  a specific shape.

## E13: Custom H2 Shape Matrix

### Hypothesis Space Split
- Parent question: does the `request written -> response headers observed`
  p99 gap follow TLS overhead, H2 multiplexing on one connection, or client/load
  scheduling across connections?
- Hypothesis under test: if the hill is H2 multiplexing or TLS record timing,
  1x16 TLS should be uniquely bad.
- Rival hypotheses:
  - the gap is mostly client/load scheduling and gets worse with more client
    connections pinned to one load core;
  - the gap is generic loopback request/response wakeup timing and appears in
    both plain and TLS;
  - only the broad oha run is noisy.

### Attack
- Change or probe:
  - added
    `.hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_shape_matrix.sh`;
  - ran the same custom checkpoint client against six cases:
    TLS/plain crossed with `1x16`, `4x4`, and `16x1`;
  - primary metric: custom client `t1_rx_headers_p99_us`.
- Command:
  `ETA_H2_SHAPE_MATRIX_REQUESTS=12000 ETA_H2_SHAPE_MATRIX_REPEATS=1 bash .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_shape_matrix.sh`

### Result
- Result dir:
  `.hill-climbing/h2-tls-spread-tiny-20260615/custom-h2-shape-matrix-results/20260615-170916`.
- All cases: success `1`, samples `12000`, errors `0`.
- p99 by case:

  | Case | total p99 | t1 -> rx_headers p99 | request-write p99 | demux/body p99 |
  | --- | ---: | ---: | ---: | ---: |
  | TLS 1x16 | `642us` | `524us` | `24us` | `1-4us` |
  | TLS 4x4 | `1605us` | `1587us` | `22us` | `1-4us` |
  | TLS 16x1 | `2410us` | `2394us` | `20us` | `1-4us` |
  | Plain 1x16 | `711us` | `617us` | `19us` | `1-6us` |
  | Plain 4x4 | `1129us` | `1107us` | `12us` | `1-4us` |
  | Plain 16x1 | `2457us` | `2445us` | `14us` | `1-4us` |
- Repeat check, 3 repeats / 36k samples per case:
  - TLS 1x16: total p99 `846us`, `t1 -> rx_headers` p99 `760us`.
  - TLS 4x4: total p99 `1951us`, `t1 -> rx_headers` p99 `1938us`.
  - TLS 16x1: total p99 `6211us`, `t1 -> rx_headers` p99 `6196us`.
  - Plain 1x16: total p99 `699us`, `t1 -> rx_headers` p99 `634us`.
  - Plain 4x4: total p99 `1209us`, `t1 -> rx_headers` p99 `1200us`.
  - Plain 16x1: total p99 `2113us`, `t1 -> rx_headers` p99 `2097us`.
  - Result dir:
    `.hill-climbing/h2-tls-spread-tiny-20260615/custom-h2-shape-matrix-results/20260615-171034`.

### Verdict
- Verdict: H2 multiplexing-specific and TLS-specific hypotheses rejected.
- Reason: 1x16 is the best shape, not the worst, and plain shows the same
  structure. In every shape the p99 is dominated by `t1 -> rx_headers`, while
  request write and client H2 demux/body completion stay tiny.
- Hypothesis space update:
  - the broad p99 sensitivity is primarily connection-count / load-client /
    kernel wakeup behavior, not Eta's H2 response generation or TLS write path;
  - any remaining H2 TLS tiny-response comparison should be treated as a
    benchmark/client/kernel attribution problem before changing server code.
- Commit/revert decision: keep the matrix script as the next-hill classifier.
- Next experiment: repeat the matrix median-of-N or run the same shapes with
  oha and custom client side-by-side if we need to align benchmark reporting.
  Do not optimize Eta server production code on this hill without new evidence
  that moves the delay back inside the server boundary.

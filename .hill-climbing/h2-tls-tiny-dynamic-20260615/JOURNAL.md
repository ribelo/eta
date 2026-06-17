# Research Journal: h2-tls-tiny-dynamic-20260615

## Hill

- Goal: improve H2 TLS p99 for tiny dynamic responses under one TLS connection
  with 16 concurrent H2 streams.
- Primary metric: `h2_tls_root_p99_us`
- Direction: lower.
- Benchmark facade: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-tiny-dynamic-20260615`
- Session directory: `.hill-climbing/h2-tls-tiny-dynamic-20260615/`

## Anti-Gaming Contract

Do not change the workload shape, endpoint semantics, expected response bodies,
TLS/H2 settings, request count, or repeat count to improve the metric. Do not
special-case benchmark paths in production code. Do not weaken checks or ignore
static/echo/RPS regressions.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_tls_root_p99_us` | Primary | lower | Optimize only if this improves beyond noise | Root tiny dynamic response |
| `h2_tls_user_id_p99_us` | Secondary | lower | Should move with root if tiny dynamic path is the hill | Small dynamic body |
| `h2_tls_post_user_p99_us` | Secondary | lower | Should not regress | Empty POST response |
| `h2_tls_static_1k_p99_us` | Guard | non-regression | Material regression rejects change | Body-heavy enough to catch write regressions |
| `h2_tls_echo_1k_p99_us` | Guard | non-regression | Material regression rejects change | Body read/write guard |
| `h2_tls_rps_geomean` | Guard | higher/non-regression | Material regression rejects change | Median repeat geomean across endpoints |
| `h2_tls_success` | Guard | exactly 1.0 | Must stay 1.0 | All endpoint runs return all expected 200 responses and bytes |

Noise policy:

- Use 9 repeats by default and compare median p99.
- Treat one-repeat outliers as noise until they reproduce.
- Prefer attribution before optimizing server code.

## Hypothesis Space

Root question:

> Why does Eta H2 TLS lose p99 on tiny dynamic responses while beating or tying
> heavier H2 TLS body endpoints?

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | TLS write/flush overhead | Tiny responses pay fixed TLS write/wakeup cost proportionally | Root/user/post p99 high; static/echo less affected | Server spans show delay before TLS write is tiny | open |
| H2 | H2 header/frame emission overhead | Root is mostly response headers plus tiny DATA | Header/frame encode or response start-to-ready dominates | Response start-to-write-ready is tiny | open |
| H3 | Scheduling before first write | Handler completion to writer wake dominates small responses | Server handler done to write job start dominates | Write job starts promptly | open |
| H4 | Measurement noise | Short responses make oha/client/kernel noise visible | 9-repeat medians are stable and shape-specific | Repeats are noisy without endpoint consistency | open |
| H_other | Residual explanation not modeled | Unknown | Current hill does not distinguish it | A better split replaces it | open |

## Experiment Selection Rule

- First establish baseline variance with the fixed facade.
- Split server-side response start/write/TLS phases before optimizing.
- Keep benchmark shape stable across experiments.
- Keep changes only when root p99 improves, guardrails pass, and the mechanism
  still serves real H2 TLS tiny-response latency.

## Experiment Entry Template

```markdown
## E<N>: <short name>

### Hypothesis Space Split
- Parent question:
- Hypothesis under test:
- Rival hypotheses:
- Why this split is high value:

### Prediction Before Run
- Expected primary metric movement:
- Expected secondary metric movement:
- Distinguishing observation:
- Falsifier:

### Attack
- Change or probe:
- Benchmark command:
- Checks command:
- Controls held constant:

### Result
- Primary metric:
- Secondary metrics:
- Checks:
- `log.jsonl` reference:

### Verdict
- Verdict: rejected | corroborated | inconclusive | split-needed
- Reason:
- Hypothesis space update:
- Commit/revert decision:
- Next experiment:
```

## Running Log

Append completed entries below. Keep entries concise, falsifiable, and useful to
a fresh agent.

## E1: Baseline Fixed H2 TLS Tiny Hill

### Hypothesis Space Split
- Parent question: is the tiny H2 TLS p99 hill stable under a high-count,
  repeated 1x16 workload?
- Hypothesis under test: H4 measurement noise versus a reproducible endpoint
  shape.
- Rival hypotheses: TLS write/flush overhead, H2 response emission, and
  response scheduling/wakeup.
- Why this split is high value: user-facing quick numbers showed root as the
  obvious loser, but the new workload has higher request count and 9 repeats.

### Prediction Before Run
- Expected primary metric movement: none; baseline setup only.
- Expected secondary metric movement: root/user/post should show whether the
  hill is tiny-response-specific while static/echo act as guards.
- Distinguishing observation: two full runs should produce comparable median
  p99s.
- Falsifier: repeat medians swing enough that attribution would be premature.

### Attack
- Change or probe: created `.hill-climbing/h2-tls-tiny-dynamic-20260615` with
  `oha` H2 TLS 1 connection / 16 streams, 24k requests per endpoint, 9 repeats.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-tiny-dynamic-20260615`
- Checks command: `.hill-climbing/h2-tls-tiny-dynamic-20260615/checks.sh`
- Controls held constant: fixed endpoint set, expected response body bytes,
  TLS/H2, and optional taskset pinning.

### Result
- Primary metric: best run `h2_tls_root_p99_us=603`; latest run
  `h2_tls_root_p99_us=624`.
- Secondary metrics from latest run:
  - `h2_tls_user_id_p99_us=895`
  - `h2_tls_post_user_p99_us=199`
  - `h2_tls_static_1k_p99_us=1008`
  - `h2_tls_echo_1k_p99_us=824`
  - `h2_tls_rps_geomean=80634`
  - `h2_tls_success=1`
- Checks: passed.
- `log.jsonl` reference: runs at `2026-06-15T10:23:48Z` and
  `2026-06-15T10:25:08Z`.

### Verdict
- Verdict: split-needed.
- Reason: root is reproducibly around 0.6 ms p99, but the larger workload also
  exposes guard tails for static/echo and a high user_id tail. The hill is
  broader than the quick comparison suggested.
- Hypothesis space update: H4 is partially rejected for median p99, but repeat
  outliers remain. Next split should attribute server response start/write/TLS
  phases under trace.
- Commit/revert decision: keep hill setup.
- Next experiment: trace response start -> H2 write ready -> writer job wait ->
  TLS flow write complete for root/user/post/static/echo.

## E2: Server-Side H2 TLS Tiny Trace Split

### Hypothesis Space Split
- Parent question: does the visible server response path explain the H2 TLS
  tiny-response p99 gap?
- Hypothesis under test: H1/H2/H3, where TLS write/flush, H2 frame emission, or
  server writer scheduling dominates the client p99.
- Rival hypotheses: client receive/demux/accounting, kernel scheduling, or
  benchmark timing noise outside the server spans.
- Why this split is high value: if server spans are near the client p99, optimize
  server code; if they are much smaller, move to attribution outside handlers.

### Prediction Before Run
- Expected primary metric movement: none; trace only.
- Expected secondary metric movement: none.
- Distinguishing observation: server accepted->write-complete p99 and writer
  wait p99 should either approach or fail to approach `oha` p99.
- Falsifier: server write-complete p99 near `oha` p99.

### Attack
- Change or probe: used existing `ETA_H2_ECHO_TRACE_PATH` response checkpoints
  while running the H2 TLS probe per endpoint.
- Benchmark command: ad hoc trace run under
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/trace-results/20260615-122629`.
- Checks command: trace only; no production code kept from this probe.
- Controls held constant: H2 TLS, 1 connection / 16 streams, same endpoint set.

### Result
- Primary metric: no metric change.
- Trace p99 summary, microseconds:

| Endpoint | `oha` p99 | accepted->start | ready wait | job wait | TLS flow write | write complete |
|----------|-----------|-----------------|------------|----------|----------------|----------------|
| root | 1706 | 60 | 50 | 18 | 39 | 143 |
| user_id | 1401 | 57 | 43 | 10 | 36 | 130 |
| post_user | 805 | 396 | 222 | 43 | 163 | 470 |
| static_1k | 1086 | 79 | 50 | 14 | 42 | 148 |
| echo_1k | 1236 | 355 | 21 | 14 | 56 | 137 |

- Checks: build/run trace completed.
- `log.jsonl` reference: not a hill-runner metric run; trace artifacts are under
  the path above.

### Verdict
- Verdict: rejected for H1/H2/H3 as whole explanations.
- Reason: visible server response work is far below `oha` p99 for root/user and
  still materially below `oha` p99 for post/static/echo. Writer job wait is tens
  of microseconds, not hundreds or milliseconds.
- Hypothesis space update: move the hill to client/accounting/kernel timing.
  Keep server optimization paused until the missing gap is located.
- Commit/revert decision: keep trace instrumentation only if already env-gated;
  no production optimization from this result.
- Next experiment: compare against a custom H2 TLS client with request/write,
  response headers, and response body completion checkpoints.

## E3: Custom H2 TLS Client Checkpoint Probe

### Hypothesis Space Split
- Parent question: is the gap between server write-complete and client-observed
  p99 visible in a second client, and which client checkpoint owns it?
- Hypothesis under test: `oha` accounting/demux artifact versus real H2/TLS
  receive/write scheduling outside Eta server spans.
- Rival hypotheses: server-side response frame/TLS write still hidden from trace,
  endpoint handler/body path, or unstable measurement noise.
- Why this split is high value: it directly records `t0` queued, `t1` request
  written, `t2` response headers received, and `t3` body complete.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: if custom-client p99 is near server span, `oha` is
  suspect; if custom-client p99 also has large tails, split by `t0->t1`,
  `t1->t2`, and `t2->t3`.
- Falsifier: custom-client p99 cleanly matches server span with no client-side
  outliers.

### Attack
- Change or probe: extended `h2_gap_client` to support TLS, GET/no-body, dynamic
  paths, and raw frame receive checkpoints.
- Benchmark command: custom diagnostic under
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/checkpoint-results/20260615-123836`.
- Checks command: build passed for `h2_gap_client.exe` and `h2_tls_probe.exe`.
- Controls held constant: H2 TLS, 16 streams. Diagnostic used 96 requests per
  connection and 20 repeats because this client closes no-body requests with
  empty DATA frames, tripping the server empty-DATA security burst above 100
  streams per connection.

### Result
- Primary metric: no metric change.
- Valid rows: 1920/1920 for each endpoint.
- Checkpoint p99 summary, microseconds:

| Endpoint | total p50 | total p95 | total p99 | max | `t0->t1` p99 | `t1->t2` p99 | `t2->t3` p99 |
|----------|-----------|-----------|-----------|-----|--------------|--------------|--------------|
| root | 118 | 274 | 437 | 4779 | 44 | 397 | 1 |
| user_id | 116 | 247 | 4151 | 11867 | 60 | 307 | 8 |
| post_user | 182 | 369 | 451 | 10469 | 64 | 434 | 1 |

- Outlier inspection:
  - root repeat 20 had a cluster at ~4.7 ms, split between delayed client write
    (`t0->t1`) and delayed response receive (`t1->t2`).
  - user_id repeat 13 had ~11.8 ms total dominated by `t0->t1`; another outlier
    showed ~4.1 ms in `t1->t2`.
  - post_user repeat 13 had ~10.4 ms outliers in `t1->t2`/client completion.
- Checks: full hill checks passed after the diagnostic-client edits.
- `log.jsonl` reference: diagnostic-only, not a primary hill run.

### Verdict
- Verdict: corroborated for client/kernel attribution; split-needed for exact
  source.
- Reason: the second client also sees rare millisecond-scale tails, but they
  occur before request bytes are written or between request write and response
  header observation. The app-level response body completion segment is tiny for
  these endpoints.
- Hypothesis space update: handler/body/copy path is not the next target. The
  remaining hill is client write scheduling, TLS/H2 receive wakeup, or kernel
  scheduling around one-connection H2 TLS multiplexing.
- Commit/revert decision: keep diagnostic-client TLS/checkpoint support.
- Next experiment: run off-CPU/scheduler or packet timestamp checks around the
  `t0->t1` and `t1->t2` outlier clusters before changing server code.

## E4: Split Client Transmit Ready From TLS Write

### Hypothesis Space Split
- Parent question: when the custom client sees `t0->t1` or `t1->t2` tails, are
  they TLS/socket write cost, writer scheduling, raw receive delay, or H2 client
  dispatch delay?
- Hypothesis under test: TLS write/flush is a material client-side tail.
- Rival hypotheses: writer wake scheduling, raw receive/kernel delay, H2 client
  demux/dispatch delay after bytes are already read.
- Why this split is high value: `t1` was measured after `Eio.Flow.write`, so it
  combined "writer selected this stream" and "write returned".

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: `tx_ready->t1` p99 should either dominate
  `t0->t1` or stay small.
- Falsifier: TLS write p99 is tiny while millisecond tails remain elsewhere.

### Attack
- Change or probe: appended `tx_ready_us` to `h2_gap_client` output, captured
  after H2 bytes are prepared and just before `Eio.Flow.write`.
- Benchmark command: custom diagnostic under
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/checkpoint-results/20260615-124150`.
- Checks command: full hill checks passed after this edit.
- Controls held constant: H2 TLS, 16 streams, 96 requests per connection, 20
  repeats.

### Result
- Primary metric: no metric change.
- Valid rows: 1920/1920 for each endpoint.
- Checkpoint p99 summary, microseconds:

| Endpoint | total p50 | total p95 | total p99 | max | `t0->tx_ready` p99 | `tx_ready->t1` p99 | `t1->t2` p99 | `t2->t3` p99 |
|----------|-----------|-----------|-----------|-----|--------------------|--------------------|--------------|--------------|
| root | 151 | 286 | 491 | 5419 | 36 | 34 | 352 | 1 |
| user_id | 156 | 274 | 4028 | 10036 | 71 | 33 | 379 | 9 |
| post_user | 186 | 348 | 3766 | 10176 | 34 | 41 | 471 | 1 |

- Outlier inspection:
  - root still had a repeat-20 cluster split between raw receive delay
    (`t1->t2` with raw header gap around 5.4 ms) and writer scheduling
    (`t0->tx_ready` around 5.1 ms).
  - user_id/post_user repeat-13 clusters showed `tx_ready->t1` near 6-10 us and
    raw header gaps near 160-170 us, while app-level response callback/body
    completion was delayed around 10 ms for some streams.
- Checks: full hill checks passed after this edit.
- `log.jsonl` reference: diagnostic-only, not a primary hill run.

### Verdict
- Verdict: TLS write/flush rejected as the normal client-side p99 owner.
- Reason: `tx_ready->t1` p99 is only tens of microseconds. The p99 tail is mostly
  receive/dispatch, and the rare multi-ms clusters alternate between writer
  scheduling, raw receive delay, and H2 client dispatch after raw bytes are read.
- Hypothesis space update: next high-value climb is scheduler/off-CPU or H2
  client dispatch attribution. Server handler/body/TLS write optimization remains
  paused.
- Commit/revert decision: keep `tx_ready_us` diagnostic support.
- Next experiment: capture scheduler/off-CPU data around the repeat-level
  clusters, or add client-side reader checkpoints around raw read ->
  `H2.Connection.read` -> response callback.

## E5: Split Raw Read From H2 Feed/Callback

### Hypothesis Space Split
- Parent question: after raw response bytes arrive at the custom client, does
  `H2.Connection.read` or callback dispatch add the missing tail?
- Hypothesis under test: H2 client demux/dispatch after raw read is the p99
  owner.
- Rival hypotheses: raw receive delay, scheduler/off-CPU stalls around TLS
  read/write, or server/network timing outside app spans.
- Why this split is high value: E4 showed rare cases where raw frame timestamps
  and app callbacks could diverge. This adds feed start/end timestamps.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: `rx_feed_end->t2` should dominate if H2 dispatch
  after feed owns the tail.
- Falsifier: `rx_feed_end->t2` is near zero while `t1->rx_headers` or write
  return stalls dominate.

### Attack
- Change or probe: appended `rx_feed_start_us` and `rx_feed_end_us` to
  `h2_gap_client` output.
- Benchmark command: custom diagnostic under
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/checkpoint-results/20260615-124437`.
- Checks command: full hill checks passed after this edit.
- Controls held constant: H2 TLS, 16 streams, 96 requests per connection, 20
  repeats.

### Result
- Primary metric: no metric change.
- Valid rows: 1920/1920 for each endpoint.
- Checkpoint p99 summary, microseconds:

| Endpoint | total p99 | `t0->tx_ready` p99 | `tx_ready->t1` p99 | `t1->rx_headers` p99 | `rx_feed` p99 | `rx_feed_end->t2` p99 | `t2->t3` p99 | max |
|----------|-----------|--------------------|--------------------|----------------------|---------------|------------------------|--------------|-----|
| root | 4137 | 38 | 30 | 4117 | 14 | 0 | 1 | 46734 |
| user_id | 1431 | 54 | 59 | 533 | 24 | 0 | 12 | 10802 |
| post_user | 547 | 33 | 34 | 507 | 34 | 0 | 1 | 10437 |

- Outlier inspection:
  - root repeat 19 had a ~46 ms `t1->rx_headers` cluster with feed/callback
    still around microseconds.
  - user_id repeat 12 had a ~10.6 ms `tx_ready->t1` cluster, meaning the TLS
    write call returned late for that rare repeat.
  - post_user repeat 12 had both ~10.3 ms write-return and raw-receive clusters.
- Checks: full hill checks passed after this edit.
- `log.jsonl` reference: diagnostic-only, not a primary hill run.

### Verdict
- Verdict: H2 feed/dispatch rejected as the normal p99 owner.
- Reason: `rx_feed_end->t2` is 0 us at p99; callbacks run during feed. The
  normal p99 is dominated by raw receive latency after request write, while rare
  repeat-level stalls can also occur inside the client TLS/socket write call.
- Hypothesis space update: the missing H2 TLS tiny-response p99 is now localized
  outside Eta handler/body/header emission and outside H2 client feed dispatch.
  Next proof should use scheduler/off-CPU or packet timestamps to decide between
  server not actually putting bytes on the wire promptly, client not being
  scheduled to read, or kernel/TLS timing.
- Commit/revert decision: keep feed checkpoint support.
- Next experiment: run packet/timestamp or `perf sched`/off-CPU capture for the
  1x16 H2 TLS shape, keyed to repeat-level outlier clusters.

## E6: Correlate Client Checkpoints With Server H2/TLS I/O

### Hypothesis Space Split
- Parent question: when the client sees `t1->rx_headers` p99, are bytes leaving
  the server late, arriving late, or is the server still waiting to accept and
  process the request?
- Hypothesis under test: post-server-write delivery or client H2 dispatch owns
  the missing p99.
- Rival hypotheses: server ingress scheduling, TLS plaintext read, H2 request
  acceptance, handler response start, or writer flow completion.
- Why this split is high value: it aligns client checkpoints with server H2
  stream IDs and TLS raw read/write timings. `perf sched` would have been useful,
  but `perf sched record` cannot access `sched:sched_switch` in this environment.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: if bytes leave server late, `response_start` or
  `write_flow_complete` will be late relative to client `t1`. If delivery is
  late, `write_flow_complete->rx_headers` will dominate. If client H2 dispatch is
  late, `rx_feed_end->t2` will dominate.
- Falsifier: timestamps cannot be matched by stream ID and wall-clock order.

### Attack
- Change or probe:
  - Added `ETA_TLS_IO_TRACE_PATH` raw TLS read/write timing.
  - Added absolute timestamps to existing H2 write trace lines.
  - Added H2 ingress plaintext read and owner ACK trace lines.
- Benchmark command: custom diagnostic under
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/correlated-trace-results/20260615-125320`.
- Checks command: full hill checks passed after this trace edit.
- Controls held constant: H2 TLS, 16 streams, 96 requests per connection, 20
  repeats.

### Result
- Primary metric: no metric change.
- Valid rows: 1920/1920 for each endpoint.
- Correlated p99 summary, microseconds:

| Endpoint | total p99 | client `t1->server plain read` | plain read -> request accepted | accepted -> response start | response start -> flow complete | flow complete -> client rx | server plain-read wait | owner ACK |
|----------|-----------|--------------------------------|--------------------------------|----------------------------|---------------------------------|--------------------------|------------------------|-----------|
| root | 990 | 302 | 156 | 117 | 180 | 43 | 83 | 127 |
| user_id | 2192 | 511 | 133 | 94 | 161 | 29 | 1879 | 128 |
| post_user | 908 | 318 | 326 | 374 | 319 | 16 | 107 | 210 |

- Previous same-run parse against `h2_write_flow_complete` showed
  `flow_complete->rx_headers` p99 of `12us` root, `38us` user_id, and `33us`
  post_user, with server flow-write p99 below `178us`.
- Outlier inspection:
  - root repeat 12 had a ~7.6 ms client writer scheduling cluster before bytes
    were written.
  - root repeat 17 had a ~2.7 ms post-flow client receive cluster.
  - user_id repeat 11 had a ~6.4 ms client writer scheduling/plain-read wait
    cluster.
  - post_user repeat 17 spread through request acceptance and response start.
- Checks: full hill checks passed after this edit.
- `log.jsonl` reference: diagnostic-only, not a primary hill run.

### Verdict
- Verdict: split-needed, but server-write/network-delivery is rejected as the
  normal p99 owner.
- Reason: after server `h2_write_flow_complete`, client raw receive is tens of
  microseconds at p99. The remaining normal p99 is spread across request arrival
  into server plaintext, H2 request acceptance, response start, and response flow
  completion. Rare max outliers are repeat-level scheduler stalls on either
  client writer scheduling, server plaintext read, or post-flow receive.
- Hypothesis space update: the next optimizable server-side candidate is not TLS
  write or H2 feed/dispatch; it is ingress/read-owner scheduling and tiny
  response start/write batching under one H2 TLS connection. Any production fix
  should target one of those spans and prove movement in the primary hill.
- Commit/revert decision: keep env-gated trace support.
- Next experiment: make one narrowly-scoped server-side experiment against
  ingress owner scheduling or response start/write batching, then compare
  `h2_tls_root_p99_us` and guardrails.

## E7: Double-Buffer H2 Ingress Reads

### Hypothesis Space Split
- Parent question: is per-read owner ACK backpressure in the server reader loop
  delaying request acceptance under one TLS connection with 16 H2 streams?
- Hypothesis under test: the reader blocking after every plaintext read, solely
  to preserve ownership of one reusable ingress buffer, contributes materially
  to tiny-response p99.
- Rival hypotheses: response write batching, handler scheduling, TLS write, or
  client-only measurement noise.
- Why this split is high value: E6 localized p99 before or around request
  acceptance and response start. The read loop had a concrete ownership fence:
  read -> copy to one reusable buffer -> enqueue Ingress -> wait for owner ACK
  before issuing the next read.

### Prediction Before Run
- Expected primary metric movement: lower root p99 if ingress read/owner
  backpressure is a real hill.
- Expected secondary metric movement: user_id should improve with root; static
  should improve or hold; echo should not materially regress.
- Distinguishing observation: root/user p50 and p99 improve together, not only
  rare max outliers.
- Falsifier: no primary movement, failed checks, or broad guard regression.

### Attack
- Change or probe: changed the server reader loop to use two reusable ingress
  buffers. The reader only waits before reusing a still-owned buffer, preserving
  explicit owner ACK semantics while allowing one read-ahead.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-tiny-dynamic-20260615`
- Checks command: same runner, plus explicit
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/checks.sh`.
- Controls held constant: primary hill workload unchanged: H2 TLS, 1 connection,
  16 streams, 24k requests per endpoint, 9 repeats.

### Result
- Primary metric:
  - baseline best `h2_tls_root_p99_us=603`
  - run 1 `h2_tls_root_p99_us=204`
  - run 2 `h2_tls_root_p99_us=199`
- Latest secondary/guard metrics:
  - `h2_tls_user_id_p99_us=223` versus baseline `895`
  - `h2_tls_post_user_p99_us=304` versus baseline `199`
  - `h2_tls_static_1k_p99_us=557` versus baseline `1008`
  - `h2_tls_echo_1k_p99_us=839` versus baseline `824`
  - `h2_tls_rps_geomean=121727` versus baseline `80634`
  - `h2_tls_success=1`
- Checks: passed on both full hill runs and direct check command.
- `log.jsonl` reference: runs at `2026-06-15T10:57:50Z` and
  `2026-06-15T10:58:16Z`.

### Verdict
- Verdict: corroborated and kept for the primary hill; follow-up needed for
  post_user.
- Reason: root p99 improved by about 67% from the best baseline, user_id and
  static improved strongly, and throughput rose about 51%. The one caveat is
  post_user p99: it remains below the original quick-run target, but regressed
  versus this hill's fresh baseline.
- Hypothesis space update: per-read owner ACK backpressure was a real H2 TLS
  tiny-response hill. The next local hill is either recovering post_user p99
  under the double-buffer reader, or proving that the POST/no-body shape is now
  a separate request-body EOF scheduling case.
- Commit/revert decision: keep the double-buffer ingress change for now; do not
  call the whole H2 TLS tiny-dynamic hill complete until post_user is recovered
  or explicitly re-ranked.
- Next experiment: isolate `post_user` with the correlated trace under the
  double-buffer reader and split request-body EOF scheduling from response start.

## E8: Already-Closed Empty Request Body Fast Path

### Hypothesis Space Split
- Parent question: why did POST/no-body lag after the double-buffer ingress
  change while root/user improved sharply?
- Hypothesis under test: `post_user` still pays an owner roundtrip for
  `Body.read_all` even when the request body is already at EOF.
- Rival hypotheses: response start/write batching, TLS delivery, or client
  scheduling noise.
- Why this split is high value: `post_user` is the only tiny dynamic endpoint
  that reads the request body before returning an empty response.

### Prediction Before Run
- Expected primary metric movement: root should stay near the E7 range.
- Expected secondary metric movement: `post_user` p99 should improve if the EOF
  body read roundtrip was real.
- Distinguishing observation: request body read trace calls disappear for
  already-closed zero-length bodies.
- Falsifier: body read trace remains or full hill `post_user` does not improve.

### Attack
- Change or probe:
  - Focused post_user trace showed `Body.read_all` returning EOF through an H2
    owner roundtrip: read p50 `118us`, p99 `319us`.
  - Added a fast path at request creation: when the stream already has
    END_STREAM and parsed `content-length` is absent or `0`, expose
    `Server.Body.empty ()`; otherwise keep the owner-backed body reader.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-tls-tiny-dynamic-20260615`
- Checks command: same runner, plus explicit
  `.hill-climbing/h2-tls-tiny-dynamic-20260615/checks.sh`.
- Controls held constant: H2 TLS, 1 connection, 16 streams, 24k requests per
  endpoint, 9 repeats.

### Result
- Focused diagnostic after the change:
  - `read_call_streams=0`
  - post_user total p50 improved from `444us` to `319us`
  - diagnostic p99 stayed noisy due client scheduling outliers.
- Full hill run 1:
  - `h2_tls_root_p99_us=213`
  - `h2_tls_user_id_p99_us=213`
  - `h2_tls_post_user_p99_us=243`
  - `h2_tls_static_1k_p99_us=536`
  - `h2_tls_echo_1k_p99_us=866`
  - `h2_tls_rps_geomean=126228`
- Full hill run 2:
  - `h2_tls_root_p99_us=222`
  - `h2_tls_user_id_p99_us=210`
  - `h2_tls_post_user_p99_us=225`
  - `h2_tls_static_1k_p99_us=487`
  - `h2_tls_echo_1k_p99_us=841`
  - `h2_tls_rps_geomean=124958`
- Checks: passed on both full hill runs and direct check command.
- `log.jsonl` reference: runs at `2026-06-15T11:04:28Z` and
  `2026-06-15T11:04:56Z`.

### Verdict
- Verdict: corroborated and kept.
- Reason: the targeted body EOF roundtrip was eliminated, `post_user` recovered
  from E7's `304us` to `225us` in the latest full run, and root/user remain far
  below baseline. Root latest is slightly above E7's best `199us`, but still
  around a 63% improvement from baseline best `603us`, with higher RPS geomean.
- Hypothesis space update: the H2 TLS tiny dynamic hill is now climbed. The
  remaining local p99 leader in this hill is `echo_1k`, not root/user/post.
- Commit/revert decision: keep the empty already-closed request body fast path.
- Next experiment: rerun a broad server-load view or set up the next hill around
  the current top p99 after these changes.

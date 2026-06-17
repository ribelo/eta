# Research Journal: h2-16x1-p99-attribution-20260615

## Hill

- Goal: prove and reduce the current broad-suite H2 16-connections /
  1-stream p99 hill after the H2 TLS tiny-dynamic 1x16 fix.
- Primary metric: `h2_tls_16x1_root_p99_us`
- Direction: lower.
- Benchmark facade: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-p99-attribution-20260615`
- Session directory: `.hill-climbing/h2-16x1-p99-attribution-20260615/`

## Anti-Gaming Contract

Do not change endpoint semantics, expected body bytes, H2/TLS protocol settings,
connection count, streams-per-connection, default request count, or repeat count
to make the metric look better. Do not special-case benchmark paths in
production code. If the result proves a measurement artifact, fix the benchmark
contract explicitly and document why; do not hide the artifact by weakening
checks or dropping cases.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_tls_16x1_root_p99_us` | Primary | lower | Optimize only if median p99 improves beyond noise | H2 TLS, 16 connections, 1 stream each, 24k requests x 9 repeats |
| `h2_tls_16x1_user_id_p99_us` | Secondary | lower | Should move with root if the tiny dynamic path is real | Small dynamic GET |
| `h2_tls_16x1_post_user_p99_us` | Secondary | lower/non-regression | Should not regress | Empty POST response |
| `h2_tls_16x1_static_1k_p99_us` | Guard | non-regression | Material regression rejects change | Static 1k body |
| `h2_tls_16x1_echo_1k_p99_us` | Guard | non-regression | Material regression rejects change | Request body read/write path |
| `h2_plain_16x1_root_p99_us` | Attribution | lower/non-regression | Distinguishes TLS-only from H2/multi-connection scheduling | H2C same shape |
| `h2_tls_16x1_root_broad_p99_us` | Diagnostic | lower | Broad quick-suite 3200-request root probe | Detects startup/floor artifacts |
| `h2_tls_16x1_root_broad_to_steady_p99_ratio` | Diagnostic | lower | High ratio points to broad-floor measurement issue | Broad p99 / steady p99 |
| `h2_16x1_success` | Guard | exactly 1.0 | Must stay 1.0 | All requests, statuses, and response bytes match |

Noise policy:

- Use 24k requests x 9 repeats as the primary steady-state signal.
- Keep the 3200-request broad-floor probe only as diagnostic attribution.
- Treat one-repeat outliers as noise until reproduced in the median.
- Prefer attribution over production optimization until startup, scheduling, and
  TLS/H2-specific causes are separated.

## Hypothesis Space

Root question:

> Why did the broad rerank move the top p99 to H2 16 connections / 1 stream,
> especially H2 TLS root at about 1.9 ms?

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Broad-floor measurement artifact | Initial TLS handshake, H2 preface, SETTINGS, or first request per connection still occupy enough samples to leak into p99 at 3200 requests | Broad-floor p99 is high while 24k steady p99 collapses | 24k steady p99 remains high and endpoint/shape consistent | open |
| H2 | Multi-connection H2 scheduling | 16 independent H2 owner/writer/read loops contend or wake poorly even after startup | H2 TLS and H2C 16x1 stay high at 24k, and all endpoints move together | Plain H2 16x1 is low or high-count TLS root collapses | open |
| H3 | TLS fixed overhead per connection | TLS record/read/write or handshake-adjacent behavior hurts 16x1 more than H2C | H2 TLS high-count p99 is much worse than H2C same shape | TLS and plain show similar steady p99 | open |
| H4 | Endpoint tiny-response path | Header/tiny DATA emission is still worse than body endpoints in 16x1 | root/user/post are high while static/echo are materially lower | all endpoints are elevated similarly | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it | A better split replaces it | open |

## Experiment Selection Rule

Choose experiments by expected elimination power:

- Prefer experiments where live hypotheses predict different observations.
- Prefer cheap falsifiers before expensive rewrites.
- Prefer instrumentation when current hypotheses are indistinguishable.
- Reject or narrow hypotheses when their falsifiers fire.
- Split broad hypotheses when results are inconclusive.
- Keep changes only when they improve the hill and preserve checks.

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

Append completed entries below. Keep entries concise, falsifiable, and useful to a fresh agent.

## E0: Broad Rerank Seed

### Hypothesis Space Split
- Parent question: after the H2 TLS 1x16 tiny-dynamic hill, what is the next
  absolute Eta p99 leader?
- Hypothesis under test: the next hill is still a tiny-response 1x16 H2 TLS
  issue.
- Rival hypotheses: broad-suite startup/floor artifact, H2 16x1 scheduling, or
  a body-path guard becoming dominant.
- Why this split is high value: it prevents optimizing the old hill after the
  ranking changed.

### Prediction Before Run
- Expected primary metric movement: none; setup/rerank only.
- Expected secondary metric movement: none.
- Distinguishing observation: top p99 cases should identify the next hill shape.
- Falsifier: 1x16 H2 TLS tiny dynamic endpoints remain the clear top cases.

### Attack
- Change or probe: ran Eta-only quick server-load rerank after the H2 TLS 1x16
  fixes.
- Benchmark command:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --out http-testsuite/results/manual-server-load-20260615-after-h2tls-tiny`
- Checks command: previous H2 TLS tiny hill checks passed before rerank.
- Controls held constant: broad quick suite shape and pinning.

### Result
- Top broad p99 cases at c=16, conn=16, streams=1:
  - H2 TLS root: `1876us` median p99, repeats `1876,1840,2213`
  - H2 TLS echo_1k: `1650us`, repeats `5218,1568,1650`
  - H2 plain echo_1k: `1642us`, repeats `1519,3213,1642`
  - H2 TLS user_id: `1598us`, repeats `1598,1326,1780`
  - H2 TLS post_user: `1444us`, repeats `1390,1444,1626`
  - H2 TLS static_1k: `1424us`, repeats `1622,1424,1369`
- H2 TLS 1x16 root in the same broad rerank is no longer the leader.
- Checks: rerank completed successfully.
- `log.jsonl` reference: not a hill-runner metric run; JSON result path above.

### Verdict
- Verdict: split-needed.
- Reason: the current broad leader is H2 16x1 across endpoints, not the old H2
  TLS 1x16 tiny-response path. Because H2 TLS and H2C 16x1 both appear near the
  top, the first split must distinguish request-floor/startup leakage from real
  steady-state multi-connection scheduling.
- Hypothesis space update: seed this new hill with a 24k x 9 steady benchmark
  plus a 3200-request broad-floor root diagnostic.
- Commit/revert decision: keep the previous H2 TLS tiny fixes; create a new hill
  rather than reusing old session.
- Next experiment: run the new hill facade once as E1 baseline.

## E1: H2 16x1 Steady Baseline

### Hypothesis Space Split
- Parent question: is the broad H2 16x1 p99 leader a short-run artifact or a
  real steady-state hill?
- Hypothesis under test: H1 broad-floor measurement artifact.
- Rival hypotheses: multi-connection H2 scheduling, TLS overhead, and endpoint
  tiny-response path.
- Why this split is high value: broad quick uses only 3200 requests for the
  16-connection shape. The hill facade uses 24k x 9, keeping startup/setup far
  away from p99.

### Prediction Before Run
- Expected primary metric movement: no code change; baseline only.
- Expected secondary metric movement: if H1 is the whole story, steady p99s
  should collapse across H2 TLS and H2C.
- Distinguishing observation: broad-floor root p99 should be much higher than
  steady root p99 if quick-suite startup leakage owns the hill.
- Falsifier: steady p99 remains elevated across endpoints and protocols.

### Attack
- Change or probe: created `measure.sh` for H2 TLS and H2C, 16 connections,
  1 stream each, 24k requests x 9 repeats, plus 3200-request root diagnostic.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-p99-attribution-20260615`
- Checks command:
  `.hill-climbing/h2-16x1-p99-attribution-20260615/checks.sh`
- Controls held constant: endpoint set, H2 settings, c=16/conn=16/streams=1,
  expected response bodies, and pinning.

### Result
- Primary metric: `h2_tls_16x1_root_p99_us=755`.
- H2 TLS steady p99s:
  - root `755us`
  - user_id `1305us`
  - post_user `1242us`
  - static_1k `1310us`
  - echo_1k `1755us`
- H2C steady p99s:
  - root `1230us`
  - user_id `1281us`
  - post_user `1196us`
  - static_1k `1285us`
  - echo_1k `1679us`
- Broad-floor diagnostics:
  - H2 TLS root broad p99 `1640us`
  - H2C root broad p99 `832us`
  - TLS broad/steady root ratio `2.17`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T11:13:35Z`.

### Verdict
- Verdict: split-needed.
- Reason: H1 is corroborated for the broad quick root number, but not as the
  whole explanation. High request count lowers TLS root materially, yet steady
  H2 16x1 p99 remains elevated across endpoints. TLS is not the sole owner
  because H2C is also high. Tiny response is not the sole owner because body
  endpoints are as high or higher.
- Hypothesis space update: reject H3/H4 as whole explanations; keep H2
  multi-connection scheduling/client/kernel timing as the live parent.
- Commit/revert decision: keep hill setup.
- Next experiment: attribute root 16x1 p99 with server write/ingress spans, but
  watch for trace perturbation.

## E2: Full H2 Trace Is Too Intrusive

### Hypothesis Space Split
- Parent question: can existing full H2 trace identify whether root p99 lives in
  server response generation, writer queueing, flow writes, or client/kernel
  timing?
- Hypothesis under test: server response/write spans explain the p99.
- Rival hypotheses: the trace itself perturbs scheduling enough to invalidate
  the observed p99.
- Why this split is high value: the prior 1x16 hill already had H2/TLS trace
  points, so this was the cheapest first attribution attempt.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: traced oha p99 should stay near untraced baseline
  if the trace is usable.
- Falsifier: traced p99 materially exceeds untraced baseline.

### Attack
- Change or probe: ran H2 TLS and H2C root, 16x1, 24k requests, with
  `ETA_H2_ECHO_TRACE_PATH`.
- Benchmark command:
  `.hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_tls.sh`
- Checks command: hill checks passed before and after.
- Controls held constant: root endpoint, H2 16x1, request count, pinning.

### Result
- H2 TLS full trace:
  - oha p99 `1838us`
  - `write_complete_response_us` p99 `1237us`
  - `flow_write_us` p99 `1150us`
  - `write_job_wait_us` p99 `55us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/trace-results/20260615-131623`
- H2C full trace:
  - oha p99 `1591us`
  - `write_complete_response_us` p99 `1181us`
  - `flow_write_us` p99 `1106us`
  - `write_job_wait_us` p99 `51us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/trace-results/20260615-131651`
- The full trace writes about 17 MB per 24k-root run and raises TLS root p99
  far above the untraced baseline.
- Checks: passed.
- `log.jsonl` reference: diagnostic-only, not a hill-runner metric run.

### Verdict
- Verdict: inconclusive for metric magnitude, useful for hypothesis split.
- Reason: full trace says writer queueing is not the owner and points at the
  flow-write window, but it also materially perturbs the workload. Do not use
  its absolute p99 as optimization evidence.
- Hypothesis space update: add low-volume slow-write tracing to test whether
  >1% of root writes exceed a threshold without logging every H2 event.
- Commit/revert decision: do not optimize server code from full trace; add
  env-gated slow-write trace only.
- Next experiment: run slow-write trace with threshold `500us`.

## E3: Low-Volume Slow-Write Trace

### Hypothesis Space Split
- Parent question: does H2 16x1 root p99 coincide with slow tiny writes without
  the intrusive full trace?
- Hypothesis under test: a >1% tail of tiny H2 writes spends more than `500us`
  inside `Eio.Flow.write`, enough to explain root p99.
- Rival hypotheses: oha/client accounting only, H2 response readiness, writer
  queueing, or TLS-only overhead.
- Why this split is high value: slow-write trace logs only tail events, so it
  preserves p50 and keeps trace volume small.

### Prediction Before Run
- Expected primary metric movement: no improvement; attribution only.
- Expected secondary metric movement: none.
- Distinguishing observation: `slow_write_fraction` should be near or above 1%
  and slow durations should be in the same range as oha p99.
- Falsifier: few or no slow writes while oha p99 remains high.

### Attack
- Change or probe:
  - Added `ETA_H2_SLOW_WRITE_TRACE_PATH` and
    `ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US`.
  - Added
    `.hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_slow_write.sh`.
  - Ran H2 TLS and H2C root 16x1 with threshold `500us`.
- Benchmark command:
  `bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_slow_write.sh`
- Checks command:
  `.hill-climbing/h2-16x1-p99-attribution-20260615/checks.sh`
- Controls held constant: root endpoint, H2 16x1, 24k requests, pinning.

### Result
- H2 TLS slow-write trace:
  - oha p50 `167us`, p95 `457us`, p99 `1448us`
  - slow writes above `500us`: `321/24000`, fraction `1.3375%`
  - slow-write p50 `1161us`, p95 `1899us`, p99 `2659us`
  - median slow write size `14` bytes
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/slow-write-results/20260615-132236`
- H2C slow-write trace:
  - oha p50 `131us`, p95 `375us`, p99 `1370us`
  - slow writes above `500us`: `273/24000`, fraction `1.1375%`
  - slow-write p50 `1248us`, p95 `1690us`, p99 `1838us`
  - median slow write size `14` bytes
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/slow-write-results/20260615-132343`
- Post-instrumentation normal hill run:
  - primary `h2_tls_16x1_root_p99_us=1055us`
  - previous best remains `755us`
  - checks passed
  - `log.jsonl` reference: run at `2026-06-15T11:25:33Z`.

### Verdict
- Verdict: corroborated for attribution, no metric improvement.
- Reason: more than 1% of tiny 14-byte H2 writes cross `500us` in both TLS and
  H2C, and the slow durations are large enough to own p99. TLS-only, H2 frame
  readiness, and writer queue wait are rejected as whole explanations.
- Hypothesis space update: the live hill is tiny H2 response `Flow.write`
  off-CPU/socket/client-backpressure timing under 16 independent sequential H2
  connections. Next split should compare syscall/kernel wait against scheduler
  delay or a second H2 client; do not chase handlers/body copies.
- Commit/revert decision: keep the env-gated slow-write trace helper; no
  production optimization accepted yet.
- Next experiment: run syscall/off-CPU attribution for root 16x1 writes, or
  build a 16-connection custom H2 client to compare against oha.

## E4: Syscall Attribution For Slow Writes

### Hypothesis Space Split
- Parent question: are the app-level slow H2 writes slow because the kernel
  write/submit syscalls block, or because Eio waits off-CPU for completion around
  otherwise short syscalls?
- Hypothesis under test: kernel syscall duration owns the slow-write p99.
- Rival hypotheses: Eio scheduler/completion wait, client receive/backpressure,
  or oha accounting.
- Why this split is high value: if syscall time owns the tail, optimize socket
  writes/backpressure. If syscall time is short, optimize scheduling/completion
  attribution before touching response code.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: counts of syscalls above `500us` should be in the
  same range as app-level slow writes if syscalls own the tail.
- Falsifier: hundreds of app-level slow writes but only a few long syscalls.

### Attack
- Change or probe:
  - Added
    `.hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_syscalls.sh`.
  - Runs the H2 root 16x1 probe under `strace -ff -ttt -T` while also enabling
    low-volume slow-write trace.
  - Fixed traced-server cleanup by running the server in a process group.
- Benchmark command:
  `bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_syscalls.sh`
- Checks command: previous check run passed after instrumentation; helper is
  diagnostic-only.
- Controls held constant: root endpoint, H2 16x1, 24k requests, pinning.

### Result
- H2 TLS default backend:
  - oha p99 `1657us`
  - slow writes above `500us`: `395/24000`, fraction `1.6458%`
  - slow-write p50 `1240us`, p95 `1918us`, p99 `2343us`
  - `io_uring_enter`: `2088` calls, `8` above `500us`, p99 `35us`
  - `write`: `2294` calls, `0` above `500us`, p99 `113us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/syscall-results/20260615-133334`
- H2C default backend:
  - oha p99 `1681us`
  - slow writes above `500us`: `322/24000`, fraction `1.3417%`
  - slow-write p50 `1379us`, p95 `2107us`, p99 `2388us`
  - `io_uring_enter`: `2097` calls, `2` above `500us`, p99 `31us`
  - `write`: `440` calls, `0` above `500us`, p99 `138us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/syscall-results/20260615-133319`

### Verdict
- Verdict: rejected for syscall duration as the normal owner.
- Reason: app-level slow writes happen hundreds of times, but long syscalls do
  not. `io_uring_enter` and `write` p99s are tens to low hundreds of
  microseconds while `Eio.Flow.write` spans over `500us` more than 1% of the
  time.
- Hypothesis space update: the live owner is completion/scheduler/off-CPU wait
  around tiny writes, not long write syscalls. TLS remains rejected as the whole
  explanation because H2C behaves similarly.
- Commit/revert decision: keep syscall helper under the hill; no production
  optimization accepted.
- Next experiment: split Eio backend/scheduler behavior with `EIO_BACKEND=posix`
  and then decide whether to optimize Eta scheduling, benchmark backend choice,
  or client attribution.

## E5: Eio Backend Split

### Hypothesis Space Split
- Parent question: is the slow tiny-write tail specific to the default
  io_uring-backed Eio path?
- Hypothesis under test: default backend completion scheduling is a major owner
  of the app-level slow-write count.
- Rival hypotheses: generic socket/client backpressure, oha accounting, or Eta
  H2 response code.
- Why this split is high value: changing only `EIO_BACKEND` separates Eta H2
  logic from backend I/O completion behavior.

### Prediction Before Run
- Expected primary metric movement: diagnostic only; do not treat backend change
  as a benchmark win unless the hill contract is explicitly changed.
- Expected secondary metric movement: if default completion scheduling owns the
  tail, slow-write fraction drops under posix.
- Distinguishing observation: `slow_write_fraction` under posix is materially
  lower than default.
- Falsifier: posix has the same slow-write fraction and p99 shape.

### Attack
- Change or probe: ran slow-write helper with `EIO_BACKEND=posix` for H2 TLS and
  H2C root 16x1, then one posix syscall trace.
- Benchmark commands:
  - `EIO_BACKEND=posix bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_slow_write.sh`
  - `EIO_BACKEND=posix ETA_H2_16X1_TRACE_MODE=plain bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_slow_write.sh`
  - `EIO_BACKEND=posix bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_syscalls.sh`
- Checks command: diagnostic-only; no production code changed in this step.
- Controls held constant: root endpoint, H2 16x1, 24k requests, pinning.

### Result
- H2 TLS posix slow-write trace:
  - oha p99 `1348us`
  - slow writes above `500us`: `79/24000`, fraction `0.3292%`
  - slow-write p50 `1104us`, p95 `1612us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/slow-write-results/20260615-133350`
- H2C posix slow-write trace:
  - oha p99 `1338us`
  - slow writes above `500us`: `74/24000`, fraction `0.3083%`
  - slow-write p50 `1168us`, p95 `1893us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/slow-write-results/20260615-133443`
- H2 TLS posix syscall trace under strace:
  - oha p99 `2730us` under strace perturbation
  - slow writes above `500us`: `84/24000`, fraction `0.3500%`
  - `writev`: `24081` calls, `1` above `500us`, p99 `7us`
  - `ppoll`: `10655` calls, `10` above `500us`, p99 `3us`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/syscall-results/20260615-133508`

### Verdict
- Verdict: corroborated for backend/scheduler involvement, split-needed for
  residual p99.
- Reason: posix reduces app-level slow-write incidence from about `1.3-1.6%` to
  about `0.3%`, so default backend completion scheduling is a major part of the
  slow-write hill. However, oha p99 remains around `1.34ms` with slow writes now
  below 1% of samples, so the residual p99 is not explained by server write
  spans alone.
- Hypothesis space update: split the hill into two layers:
  - default backend app-level write completion tail, likely Eio/io_uring
    scheduling/completion behavior;
  - residual client/accounting/scheduling p99 visible even when server slow
    writes fall below p99.
- Commit/revert decision: keep diagnostic helpers; no production optimization
  accepted from backend choice alone.
- Next experiment: build a true 16-connection custom H2 client that can send
  no-body requests with HEADERS `END_STREAM`, or add low-volume client-side
  receive checkpoints to prove whether residual p99 is oha/client-side.

## E6: Custom 16x1 H2 Client With True Empty Requests

### Hypothesis Space Split
- Parent question: is the residual H2 16x1 p99 an `oha` accounting/demux
  artifact, or does a second H2 client reproduce it?
- Hypothesis under test: `oha` is the sole owner of the residual p99.
- Rival hypotheses: client receive scheduling, server ingress scheduling,
  network/kernel timing, or server write completion.
- Why this split is high value: a custom client can checkpoint request write,
  raw response-frame receipt, H2 feed, response handler dispatch, and body EOF.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: if `oha` owns the tail, custom-client total p99
  should collapse and/or client demux should show no gap.
- Falsifier: custom-client p99 remains high with the same 16x1 shape.

### Attack
- Change or probe:
  - Added `?end_stream:bool` to low-level
    `Eta_http.H2.Connection.Client.request` so no-body requests can set
    END_STREAM on the HEADERS frame.
  - Updated `h2_gap_client` to use `~end_stream:true` for zero-byte request
    bodies instead of sending empty DATA frames.
  - Added
    `.hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`,
    which runs 16 independent one-stream custom clients for 24k total root
    requests.
  - Added a focused H2 writer test for HEADERS END_STREAM, but the full
    `test/http/run.exe` target remains blocked by unrelated HPACK header-type
    errors in existing test modules.
- Benchmark commands:
  - `bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `ETA_H2_16X1_TRACE_MODE=plain bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
- Checks command:
  - `nix develop -c dune build http-testsuite/test/server_load/h2_gap_client.exe`
  - `nix develop -c dune runtest --profile release test/http_common test/http_eio`
- Controls held constant: root endpoint, H2 16x1 total shape, 24k total
  requests, pinning.

### Result
- H2 TLS custom client with server slow-write trace:
  - rows/valid/bad: `24000/24000/0`
  - total p99 `2913us`
  - `t1->t2` p99 `2901us`
  - `t0->t1` p99 `21us`
  - `t2->t3` p99 `1us`
  - `rx_headers->t2` p99 `4us`
  - server slow writes above `500us`: `7/24000`, fraction `0.0292%`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-134226`
- H2C custom client with server slow-write trace:
  - rows/valid/bad: `24000/24000/0`
  - total p99 `2282us`
  - `t1->t2` p99 `2274us`
  - `t0->t1` p99 `13us`
  - `t2->t3` p99 `1us`
  - `rx_headers->t2` p99 `4us`
  - server slow writes above `500us`: `30/24000`, fraction `0.1250%`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-134240`
- Verification:
  - `h2_gap_client.exe` builds.
  - `test/http_common` and `test/http_eio` pass.
  - Full `test/http/run.exe` is blocked before this test by unrelated HPACK
    header type mismatches in `test_eta_http_h2_hpack.ml` and
    `test_eta_http_h2_server.ml`.

### Verdict
- Verdict: rejected for `oha` as the sole owner; split-needed.
- Reason: a second H2 client reproduces p99 in both TLS and H2C. The tail is
  dominated by time from request body fully written to response handler
  (`t1->t2`), while client write-side, H2 feed/demux, and body EOF are
  microsecond-scale. In the custom-client shape, server slow writes fall below
  p99, so residual p99 is not explained by server write spans either.
- Hypothesis space update: the live residual owner is before client raw response
  receipt: server request ingress/acceptance scheduling, client read scheduling,
  kernel delivery, or cross-process load scheduling under 16 independent
  sequential clients.
- Commit/revert decision: keep true empty-request client support and diagnostic
  helper; it removes the empty-DATA diagnostic limitation and is protocol-correct.
- Next experiment: add low-volume server ingress/acceptance slow traces, then
  rerun the custom 16x1 client to split `t1->server ingress`, request accepted,
  response ready, and client raw receive.

## E7: Join Custom Client To Buffered Server Phase Trace

### Hypothesis Space Split
- Parent question: where does custom-client `t1->t2` live for H2 16x1 root?
- Hypothesis under test: server request acceptance or tiny response generation
  owns the residual p99.
- Rival hypotheses: client/server scheduling before server ingress,
  post-server-write client receive scheduling, kernel delivery, or cross-process
  load scheduling.
- Why this split is high value: E6 proved the residual p99 is not `oha` and not
  H2 client feed/demux. Joining client local port + stream ID to server phase
  timestamps can split the gap without changing production behavior.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: none.
- Distinguishing observation: p99 should concentrate in one or two joined
  segments: `t1->ingress`, ingress->accepted, accepted->response_start,
  response_start->flow_complete, or flow_complete->client raw headers.
- Falsifier: phase rows cannot be joined completely or server accept/response
  phases dominate.

### Attack
- Change or probe:
  - Appended `local_port` to `h2_gap_client` TSV output.
  - Added buffered, env-gated `ETA_H2_PHASE_TRACE_PATH` server events for
    ingress read, request accepted, response start, and write-flow complete.
  - Updated the custom 16x1 helper to join client rows to server events by
    `(local_port, stream_id)`.
- Benchmark commands:
  - `bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `ETA_H2_16X1_TRACE_MODE=plain bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
- Checks command:
  - `bash .hill-climbing/h2-16x1-p99-attribution-20260615/checks.sh`
  - `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-p99-attribution-20260615`
- Controls held constant: root endpoint, total 16x1 shape, 24k requests,
  one stream per connection, pinning, and endpoint semantics.

### Result
- H2 TLS custom join:
  - rows/valid/joined: `24000/24000/24000`
  - total p99 `2870us`; `t1->t2` p99 `2860us`
  - `t1->ingress_returned` p99 `869us`
  - ingress_returned->accepted p99 `19us`
  - accepted->response_start p99 `4us`
  - response_start->flow_complete p99 `135us`
  - flow_complete->client raw headers p99 `1554us`
  - server slow writes above `500us`: `4/24000`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-135636`
- H2C custom join:
  - rows/valid/joined: `24000/24000/24000`
  - total p99 `2954us`; `t1->t2` p99 `2944us`
  - `t1->ingress_returned` p99 `1004us`
  - ingress_returned->accepted p99 `27us`
  - accepted->response_start p99 `4us`
  - response_start->flow_complete p99 `121us`
  - flow_complete->client raw headers p99 `1564us`
  - server slow writes above `500us`: `20/24000`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-135645`
- Verification:
  - `h2_gap_client.exe`, `h2_tls_probe.exe`, and `h2_probe.exe` build.
  - 16x1 hill checks passed.
  - Normal runner with phase trace disabled passed at
    `2026-06-15T11:57:59Z`; primary `1201us`, best remains `755us`.

### Verdict
- Verdict: rejected for server accept/handler/tiny response as the normal owner;
  split-needed for scheduler/delivery.
- Reason: server ingress->accepted and accepted->response_start are
  microsecond-scale at p99 in both TLS and H2C. Server response
  start->flow-complete is also far below the client p99. The largest normal
  owner is after server write completion before client raw header observation,
  with a secondary contribution before server ingress sees the request.
- Hypothesis space update: TLS, handler/body/header emission, and H2 client
  feed/demux are rejected as whole explanations. The live hill is
  cross-process scheduling / socket readiness / client read scheduling around
  16 independent sequential H2 connections. Production server optimization is
  not justified until that layer is separated from the benchmark client and OS
  scheduler.
- Commit/revert decision: keep the buffered phase trace and local-port
  diagnostic support; do not change production behavior from this result.
- Next experiment: compare the same custom 16x1 shape with server and client on
  different CPU pinning layouts, then optionally run `perf sched`/off-CPU if the
  environment permits it. If `flow_complete->rx_headers` moves with pinning, the
  hill is load scheduling rather than Eta H2 logic.

## E8: Pinning And Backend Split

### Hypothesis Space Split
- Parent question: is the residual 16x1 tail a benchmark/load scheduling
  artifact, an Eio backend completion issue, or an Eta H2 server issue?
- Hypothesis under test: pinning 16 client processes to one load core owns the
  custom-client `flow_complete->rx_headers` p99.
- Rival hypotheses: server write-completion scheduling, Eio backend behavior,
  or a true Eta H2 multi-connection server bottleneck.
- Why this split is high value: E7 showed the largest normal segment after
  server write completion. Moving only client CPU placement should affect that
  segment if the client load side is the owner.

### Prediction Before Run
- Expected primary metric movement: diagnostic only; no production code change.
- Expected secondary metric movement: wider client CPU placement should reduce
  post-write receive delay. Posix backend should reduce server write completion
  if default backend completion owns it.
- Distinguishing observation: segment ownership moves with pinning/backend.
- Falsifier: segment distributions stay the same across pinning/backend splits.

### Attack
- Change or probe:
  - Custom TLS 16x1 with default server core and clients spread across
    `ETA_SERVER_LOAD_LOAD_CORE=3-6`.
  - Custom TLS 16x1 with server on `2-3` and clients on `4-7`.
  - Custom TLS 16x1 with `EIO_BACKEND=posix`.
  - Custom TLS 16x1 with both `EIO_BACKEND=posix` and clients on `3-6`.
  - Eta H2-only broad quick rerank with `ETA_SERVER_LOAD_LOAD_CORE=3-6`.
- Benchmark commands:
  - `ETA_SERVER_LOAD_LOAD_CORE=3-6 bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `ETA_SERVER_LOAD_SERVER_CORE=2-3 ETA_SERVER_LOAD_LOAD_CORE=4-7 bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `EIO_BACKEND=posix bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `EIO_BACKEND=posix ETA_SERVER_LOAD_LOAD_CORE=3-6 bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `ETA_SERVER_LOAD_LOAD_CORE=3-6 nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --h2-only --out http-testsuite/results/manual-server-load-20260615-h2-loadcore-range`
- Checks command: `git diff --check`; previous 16x1 checks and normal runner
  passed after the instrumentation.
- Controls held constant: endpoint semantics, H2 shape, request counts, and
  server implementation.

### Result
- Custom TLS, default backend, clients on `3-6`:
  - total p99 `1789us`
  - `flow_complete->rx_headers` p99 collapsed from `1554us` to `26us`
  - response_start->flow_complete p99 rose to `1010us`
  - server slow writes above `500us`: `353/24000`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-135902`
- Custom TLS, server `2-3`, clients `4-7`:
  - total p99 `1997us`
  - `flow_complete->rx_headers` p99 `27us`
  - response_start->flow_complete p99 `1178us`
  - server slow writes above `500us`: `412/24000`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-135918`
- Custom TLS, `EIO_BACKEND=posix`, one client core:
  - total p99 `2813us`
  - response_start->flow_complete p99 `94us`
  - `flow_complete->rx_headers` p99 `1824us`
  - server slow writes above `500us`: `6/24000`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-135927`
- Custom TLS, `EIO_BACKEND=posix`, clients on `3-6`:
  - total p99 `1818us`
  - response_start->flow_complete p99 `318us`
  - `flow_complete->rx_headers` p99 `18us`
  - server slow writes above `500us`: `66/24000`
  - trace path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-135934`
- H2-only broad quick with load core range:
  - H2 TLS root 16x1 improved from `1336us` to `1152us`
  - H2 TLS post_user 16x1 improved from `1561us` to `1340us`
  - H2 plain root 16x1 improved from `1240us` to `832us`
  - H2 plain post_user 16x1 improved from `1074us` to `758us`
  - H2 TLS echo_1k 16x1 worsened/noisy from `1496us` to `1840us`
  - result path:
    `http-testsuite/results/manual-server-load-20260615-h2-loadcore-range/server_load.json`

### Verdict
- Verdict: corroborated for scheduling/backpressure as the live owner;
  rejected for a pure load-core artifact.
- Reason: spreading client processes nearly eliminates
  `flow_complete->rx_headers`, proving that segment is load/client scheduling
  sensitive. The tail then moves into server write completion, and posix reduces
  that write-completion tail when clients are on one core. Combining posix with
  spread clients keeps post-write receive low but leaves residual before or
  inside server write completion. Broad H2 p99 improves in several 16x1 cases
  with load-core range, but does not collapse and remains noisy.
- Hypothesis space update: the hill is not handler/body/header emission and not
  TLS-specific. It is an OS/Eio scheduling and socket readiness interaction
  exposed by 16 independent sequential H2 connections. Any next production
  experiment should target server write scheduling/backpressure only if it
  improves the normal hill with the current benchmark contract; otherwise the
  benchmark should report pinning sensitivity explicitly.
- Commit/revert decision: keep diagnostic phase tracing. No production behavior
  optimization accepted from pinning/backend diagnostics.
- Next experiment: either capture scheduler/off-CPU data for default backend
  writes, or add a benchmark-side pinning-sensitivity report so 16x1 p99 is not
  misread as handler latency.

## E9: Reproducible Pinning Helper And Perf Sched Probe

### Hypothesis Space Split
- Parent question: can the E8 pinning/backend result be reproduced by a stable
  hill helper, and can scheduler/off-CPU data be captured on this host?
- Hypothesis under test: the 16x1 custom-client tail is materially sensitive to
  client CPU placement and Eio backend, and scheduler tracepoints can identify
  the precise off-CPU owner.
- Rival hypotheses: E8 was an ad hoc noisy run; or scheduler capture is
  unavailable in this environment.
- Why this split is high value: it converts the scheduling conclusion into a
  reusable diagnostic and checks whether deeper off-CPU proof is available
  before more production experiments.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic only.
- Expected secondary metric movement: helper should reproduce the same segment
  ownership changes as E8.
- Distinguishing observation: `flow_complete->rx_headers` p99 should collapse
  under load-core range, while default/posix one-core cases keep that segment
  high.
- Falsifier: helper cannot reproduce the segment movement or fails validation.

### Attack
- Change or probe:
  - Added `pinning_sensitivity.sh` to run four stable custom-client cases:
    default, load-core range, posix, and posix + load-core range.
  - Added `trace_root_perf_sched.sh` to attempt `perf sched record` around the
    same custom-client shape and report a clean permission block when tracepoints
    are unavailable.
- Benchmark commands:
  - `bash .hill-climbing/h2-16x1-p99-attribution-20260615/pinning_sensitivity.sh`
  - `ETA_H2_16X1_PERF_REQUESTS=24000 bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_perf_sched.sh`
- Checks command:
  - `bash -n .hill-climbing/h2-16x1-p99-attribution-20260615/pinning_sensitivity.sh`
  - `bash -n .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_perf_sched.sh`
  - `git diff --check`
- Controls held constant: root endpoint, H2 TLS, total 16x1 custom-client shape,
  24k requests, and endpoint semantics.

### Result
- Pinning helper full run:
  - result path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/pinning-results/20260615-140352`
  - default: total p99 `2642us`,
    `flow_complete->rx_headers` p99 `1559us`,
    response_start->flow_complete p99 `141us`,
    slow writes `25/24000`
  - load range: total p99 `2002us`,
    `flow_complete->rx_headers` p99 `26us`,
    response_start->flow_complete p99 `987us`,
    slow writes `308/24000`
  - posix: total p99 `2676us`,
    `flow_complete->rx_headers` p99 `1782us`,
    response_start->flow_complete p99 `110us`,
    slow writes `10/24000`
  - posix + load range: total p99 `1859us`,
    `flow_complete->rx_headers` p99 `34us`,
    response_start->flow_complete p99 `332us`,
    slow writes `88/24000`
  - emitted metrics:
    - `h2_16x1_pinning_default_to_best_total_ratio=1.42`
    - `h2_16x1_pinning_flow_rx_reduction_ratio=59.96`
- Perf sched probe:
  - result path:
    `.hill-climbing/h2-16x1-p99-attribution-20260615/perf-sched-results/20260615-140405`
  - `perf_event_paranoid=2`
  - `perf sched record` failed with status `129`
  - captured reason: no permission to read `sched:sched_switch`
- Verification:
  - both new helper scripts pass `bash -n`
  - `git diff --check` passes
  - `checks.sh` now includes a reduced pinning-helper smoke and passed at
    `2026-06-15T12:05:41Z`

### Verdict
- Verdict: corroborated for pinning/backend sensitivity; blocked for perf
  scheduler tracepoints in this environment.
- Reason: the stable helper reproduces the E8 segment movement. Client CPU
  spread removes the post-server-write receive tail, but exposes server write
  completion/backpressure under the default backend. Posix reduces server write
  completion in the one-core case but not the post-write receive tail. `perf
  sched` cannot be used here without host tracing permissions.
- Hypothesis space update: continue treating 16x1 p99 as a scheduling/socket
  readiness hill. The next code-facing experiment, if any, should target default
  backend server write completion under spread-client conditions and must prove
  movement in the normal 16x1 hill. Otherwise the safer measurement fix is to
  report pinning sensitivity alongside H2 16x1 p99.
- Commit/revert decision: keep both diagnostic helpers; no production behavior
  optimization accepted.
- Next experiment: run a narrow server write batching/backpressure experiment
  only if it improves default-backend spread-client `response_start->flow_complete`
  and the normal 16x1 runner guardrails.

## E10: Server-Load H2 16x1 Analysis Report

### Hypothesis Space Split
- Parent question: should the 16x1 hill be handled as a production write-path
  optimization now, or should the benchmark report the proven pinning
  sensitivity first?
- Hypothesis under test: current server-load output makes the 16x1 p99 easy to
  misread as handler latency because the scheduling-sensitive shape is only
  visible by manually regrouping raw rows.
- Rival hypotheses: the existing `metadata.pinning` field is enough, or a
  narrow server write change is already justified.
- Why this split is high value: E7-E9 rejected handler/body/header/TLS as whole
  explanations and showed strong client/load scheduling sensitivity. Reporting
  that in the benchmark result prevents chasing the wrong hill.

### Prediction Before Run
- Expected primary metric movement: none; reporting-only.
- Expected secondary metric movement: none.
- Distinguishing observation: quick H2 server-load JSON should include a compact
  H2 16x1 ranking with repeat p99s and a pinning-sensitivity note.
- Falsifier: generated JSON omits the analysis, misranks cases, or breaks
  checks.

### Attack
- Change or probe:
  - Added `analysis.h2_16x1_p99` to `server_load.json`.
  - The analysis filters passing H2 cases with `c=16`, `connections=16`, and
    `streams_per_connection=1`, ranks by median p99 in microseconds, preserves
    repeat p99s, and includes a note to inspect `metadata.pinning`.
- Benchmark commands:
  - `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --smoke --eta-only --out http-testsuite/results/manual-server-load-20260615-analysis-smoke`
  - `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --h2-only --out http-testsuite/results/manual-server-load-20260615-analysis-h2-quick`
- Checks command:
  - `nix develop -c dune build http-testsuite/test/server_load/run.exe`
  - `bash .hill-climbing/h2-16x1-p99-attribution-20260615/checks.sh`
  - `git diff --check`
- Controls held constant: all benchmark workload shapes and request counts.

### Result
- Smoke JSON:
  - `analysis.h2_16x1_p99.case_count=0`
  - pinning metadata present:
    `{"enabled":true,"server_core":"2","load_core":"3"}`
  - result path:
    `http-testsuite/results/manual-server-load-20260615-analysis-smoke/server_load.json`
- H2 quick JSON:
  - `analysis.h2_16x1_p99.case_count=10`
  - top entry in this run:
    H2 plain `post_user`, median p99 `1619.886us`, repeats
    `1619.886, 2199.414, 1062.852`
  - H2 TLS root appears with median p99 `1301.518us`, repeats
    `3832.595, 1098.390, 1301.518`
  - result path:
    `http-testsuite/results/manual-server-load-20260615-analysis-h2-quick/server_load.json`
- Verification:
  - `run.exe` builds.
  - `checks.sh` passed at `2026-06-15T12:09:54Z`.
  - `git diff --check` passed.

### Verdict
- Verdict: corroborated and kept.
- Reason: the benchmark result now surfaces the exact scheduling-sensitive shape
  and repeat spread, with pinning context immediately adjacent in metadata. This
  is the correct climb for a hill whose attribution points outside handlers and
  into scheduler/socket readiness.
- Hypothesis space update: a production server write experiment remains possible
  only under the stricter rule from E9: it must improve default-backend
  spread-client write-completion and the normal 16x1 runner. Until then, the
  benchmark now carries the measurement caveat explicitly.
- Commit/revert decision: keep reporting change.
- Next experiment: rerun broad comparisons with the new analysis block and pick
  the next true code hill after excluding pinning-sensitive 16x1 noise.

## E11: H2O-Style Owner Burst Write Gathering

### Hypothesis Space Split
- Parent question: is part of H2 16x1 p99 caused by Eta flushing H2 writes too
  eagerly after each owner command, where H2O gathers pending stream output
  before one connection write?
- Hypothesis under test: bounded owner-command write gathering reduces 16x1 p99
  by coalescing response HEADERS/DATA frames in the existing contiguous H2 write
  buffer.
- Rival hypotheses: 16x1 remains dominated by client/socket scheduling, or
  gathering delays heavier streams and only improves root by shifting unfairness.
- Why this split is high value: `.reference/h2o` uses a connection-level output
  buffer plus a zero-delay gathered write. Relevant prior art:
  - `.reference/h2o/lib/http2/connection.c`: `request_gathered_write` links a
    zero-timeout write timer when the socket is not already writing.
  - `.reference/h2o/lib/http2/connection.c`: `do_emit_writereq` runs the stream
    scheduler, appends frames into `_write.buf`, then sends one socket write and
    moves that buffer to `_write.buf_in_flight`.
  - `.reference/h2o/lib/http2/stream.c`: response send queues body vectors on
    the stream, activates the scheduler, and lets the connection writer emit
    pending data.

### Prediction Before Run
- Expected primary metric movement: lower `h2_tls_16x1_root_p99_us` if eager
  owner-command flushing contributes to p99.
- Expected secondary metric movement: non-root H2 TLS 16x1 endpoints and RPS
  should not materially regress; otherwise the gather budget is too blunt.
- Distinguishing observation: a bounded budget improves the cluster, while an
  overly large budget improves root but hurts post/static/echo.
- Falsifier: repeated runs show primary movement only by regressing guard
  endpoints or checks fail.

### Attack
- Change or probe: added a deferrable H2 write flush in
  `lib/http_eio/h2_server_connection.ml`. The owner handles the blocking command
  plus up to a bounded number of immediately available owner commands with
  `defer_write_flush=true`, then calls `flush_writes_now` once. This preserves
  the existing contiguous write-job copy and does not use the previously
  rejected zero-copy iovec path.
- Budget variants:
  - `32`: first probe.
  - `8`: reduced gather after guard concerns.
  - `4`: current kept candidate.
- Benchmark command for each variant:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-p99-attribution-20260615`
- Checks command: included in the runner; also explicitly built
  `http-testsuite/test/server_load/h2_probe.exe`,
  `http-testsuite/test/server_load/h2_tls_probe.exe`, `test/http_eio`, and
  `test/http_common`.

### Result
- Historical baseline rows from this hill:
  - `2026-06-15T11:13:35Z`: root `754.693us`, user `1305.235us`,
    post `1242.205us`, static `1310.034us`, echo `1755.355us`,
    RPS geomean `55068.489`.
  - `2026-06-15T11:25:33Z`: root `1055.367us`, user `1353.397us`,
    post `1259.808us`, static `1369.938us`, echo `1771.988us`,
    RPS geomean `53656.334`.
  - `2026-06-15T11:57:59Z`: root `1201.336us`, user `1246.642us`,
    post `1186.196us`, static `1297.650us`, echo `1804.458us`,
    RPS geomean `54953.643`.
- Budget `32`:
  - run 1: root `697.983us`, user `1225.251us`, post `1209.090us`,
    static `1227.314us`, echo `1617.019us`, RPS geomean `56272.332`.
  - run 2: root `826.859us`, user `1333.868us`, post `1241.392us`,
    static `1385.737us`, echo `1838.453us`, RPS geomean `54726.989`.
  - Verdict inside experiment: promising primary, too much guard noise.
- Budget `8`:
  - root `1077.619us`, user `1256.290us`, post `1168.873us`,
    static `1246.191us`, echo `1628.781us`, RPS geomean `56027.983`.
  - Verdict inside experiment: primary win weakened, guards still mixed.
- Budget `4`:
  - root `593.264us`, user `1288.973us`, post `1172.590us`,
    static `1262.232us`, echo `1614.114us`, RPS geomean `55796.154`.
  - H2 plain root also improved to `639.562us`; plain echo was `1580.299us`.
- Checks: passed for every valid run.

### Verdict
- Verdict: corroborated and kept as a production candidate.
- Reason: the H2O-inspired gather boundary improves the primary by about 21%
  versus the best prior root baseline and improves it by about 51% versus the
  worst recent baseline. With budget `4`, post/static/echo and RPS geomean are
  better than the first recorded baseline, and user is within normal 16x1 noise.
  The experiment also explains why bigger budgets are risky: they can shift
  delay to heavier endpoints.
- Hypothesis space update: 16x1 is not only client/socket scheduling. Eta's
  owner-command flush boundary is a real contributor. Keep H2O-style bounded
  gathering, but do not pursue buffer-detach/zero-copy yet because the earlier
  iovec experiment regressed and H2O's buffer-swap strategy would need a
  separate spare-buffer design in OCaml.
- Commit/revert decision: keep the budget `4` code.
- Next experiment: run a fresh broad Eta-only rerank with the budget `4` gather
  to verify the improvement survives the server-load matrix and does not create
  a new top regression outside 16x1.

## E12: Broad Rerank and Gather A/B

### Hypothesis Space Split
- Parent question: does the H2O-style owner-command gather survive outside the
  focused hill runner, or did it only win one noisy measurement?
- Hypothesis under test: budget `4` gather is a real improvement for H2 p99 and
  not just a root-only transfer of latency to other endpoints.
- Rival hypotheses:
  - broad quick sampling is too noisy to validate this change;
  - gathering helps the one-connection multiplexed shape but regresses the
    spread `16 connections x 1 stream` shape;
  - the H2O idea is useful prior art, but this Eta implementation should be
    rejected.

### Prediction Before Run
- If the change is real, same-machine A/B should show lower median p99 or higher
  RPS with gather enabled across the H2 TLS tiny-response cluster.
- If the broad quick result is the only evidence and it is mixed, the change is
  not good enough to keep.
- Falsifier: controlled A/B shows p99 regressions in H2 TLS root/user/post or
  lower H2 TLS RPS geomean.

### Attack
- Broad guardrail:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --out http-testsuite/results/manual-server-load-20260615-after-h2o-gather`
- Controlled A/B:
  - gather on: owner loop calls `handle_command_batch`.
  - gather off: owner loop calls `handle_command`.
  - multiplexed shape:
    `ETA_H2_16X1_CONNECTIONS=1 ETA_H2_16X1_STREAMS=16 ETA_H2_16X1_REQUESTS=12000 ETA_H2_16X1_REPEATS=5 ETA_H2_16X1_BROAD_REQUESTS=1600 ETA_H2_16X1_BROAD_REPEATS=1 bash .hill-climbing/h2-16x1-p99-attribution-20260615/measure.sh`
  - spread shape:
    `ETA_H2_16X1_REQUESTS=12000 ETA_H2_16X1_REPEATS=5 ETA_H2_16X1_BROAD_REQUESTS=1600 ETA_H2_16X1_BROAD_REPEATS=1 bash .hill-climbing/h2-16x1-p99-attribution-20260615/measure.sh`

### Result
- Broad quick result path:
  `http-testsuite/results/manual-server-load-20260615-after-h2o-gather/server_load.json`
- Broad quick, multiplexed `conn=1, streams=16` H2 TLS:
  - root `388us`, user `540us`, post `388us`, static `594us`,
    echo `692us`.
  - Compared with the prior broad compare file, this is mixed rather than a
    standalone proof.
- Broad quick, spread `conn=16, streams=1` H2 TLS:
  - root `1501us`, user `1401us`, post `1310us`, static `1247us`,
    echo `1684us`.
  - This shape remains the top noisy p99 cluster and should not be confused with
    the earlier one-connection multiplexing question.
- Controlled A/B, multiplexed `conn=1, streams=16`:
  - H2 TLS gather off: RPS geomean `116124`, root `207us`, user `220us`,
    post `321us`, static `542us`, echo `672us`.
  - H2 TLS gather on: RPS geomean `122826`, root `188us`, user `195us`,
    post `279us`, static `504us`, echo `684us`.
  - H2 plain gather off: RPS geomean `147362`, root `224us`, user `199us`,
    post `203us`, static `343us`, echo `1579us`.
  - H2 plain gather on: RPS geomean `166161`, root `187us`, user `185us`,
    post `170us`, static `468us`, echo `1418us`.
- Controlled A/B, spread `conn=16, streams=1`:
  - H2 TLS gather off: RPS geomean `51827`, root `1315us`, user `1217us`,
    post `1215us`, static `1331us`, echo `1789us`.
  - H2 TLS gather on: RPS geomean `54022`, root `1064us`, user `1171us`,
    post `1155us`, static `1201us`, echo `1647us`.
  - H2 plain gather off: RPS geomean `71167`, root `1148us`, user `1205us`,
    post `1039us`, static `1316us`, echo `1412us`.
  - H2 plain gather on: RPS geomean `72015`, root `1034us`, user `1202us`,
    post `1072us`, static `1216us`, echo `1495us`.

### Verdict
- Verdict: keep the budget `4` gather.
- Reason: broad quick alone was too noisy, but controlled same-machine A/B
  corroborated the change. H2 TLS improved for both the one-connection
  multiplexed shape and the spread shape, including root/user/post. RPS geomean
  also improved in both H2 TLS samples.
- Guardrail note: H2 plain is mixed on individual endpoints, especially
  `static_1k` in the multiplexed sample and `post_user`/`echo_1k` in the spread
  sample, but H2 plain RPS geomean improved and the main H2 TLS hill moved the
  right way.
- Hypothesis space update: H2O's connection-level gathered write boundary maps
  to Eta. The right Eta-sized version is a small bounded owner-command batch
  feeding the existing contiguous write buffer, not a new priority scheduler and
  not the previously rejected zero-copy iovec path.
- Commit/revert decision: keep.
- Next experiment: rerank against references after this candidate and separate
  the remaining spread-shape H2 TLS p99 from multiplexed H2 scheduling.

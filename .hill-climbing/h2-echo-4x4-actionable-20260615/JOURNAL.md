# Research Journal: h2-echo-4x4-actionable-20260615

## Hill

- Goal: determine and improve the top actionable Eta H2 tail-latency hill after
  excluding the known H2 16x1 socket-readiness artifact. The first concrete hill
  is H2C `/echo` with a 1 KiB body at 4 connections x 4 streams.
- Primary metric: `h2_plain_echo_4x4_p99_us`.
- Direction: lower is better.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h2-echo-4x4-actionable-20260615`
- Session directory: `.hill-climbing/h2-echo-4x4-actionable-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_echo_4x4_p99_us` | Primary | lower | Keep changes only when repeated runs move this down beyond noise and checks pass. | H2C `/echo`, 1 KiB request/response body, 4 connections x 4 streams, 24k requests x 9 repeats by default. |
| `h2_echo_4x4_success` | Correctness gate | higher | Must remain `1.0`. Reject any change that lowers it. | Verifies status, error count, success rate, and expected response bytes for all measured cases. |
| `h2_tls_echo_4x4_p99_us` | Guard | lower / no regression | Reject a primary win that materially hurts this unless the journal proves the regression is unrelated noise. | Keeps H2 TLS body path from regressing. |
| `h2_plain_echo_1x16_p99_us` | Guard / classifier | lower / compare | Used to distinguish the new 4x4 hill from the previous 1x16 scheduling-sensitive hill. | Not the primary target. |
| `h2_plain_static_4x4_p99_us` | Guard / classifier | lower / no regression | Helps separate body echo read/write issues from generic 1 KiB response write issues. | H2C static 1 KiB. |
| `h2_plain_post_4x4_p99_us` | Guard / classifier | lower / no regression | Helps separate request-body handling from tiny dynamic response handling. | Empty POST response. |
| `h2_plain_root_4x4_p99_us` | Guard / classifier | lower / no regression | Helps catch generic H2 response scheduling regressions. | Empty root response. |
| `h2_echo_4x4_rps_geomean` | Throughput guard | higher / no material regression | Reject p99 wins that trade away meaningful throughput without an explicit hypothesis and evidence. | Geomean across plain/TLS echo 4x4 per repeat, then median. |

Noise policy:

- Establish baseline variance before trusting small wins.
- For short noisy workloads, use repeated samples and compare medians in `measure.sh`.
- Treat changes inside the noise floor as inconclusive unless they simplify code or improve a secondary constraint without hurting the primary metric.

## Hypothesis Space

Root question:

> What mechanism currently limits the hill?

Maintain a partition of plausible explanations. Keep `H_other` for residual uncertainty until a better split replaces it.

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Echo body path still dominates 4x4 p99 | Request-body read, echo response construction, or response-body write has a tail under multi-connection H2. | Echo 4x4 is worse than root/post/static 4x4, and probes inside body read/write correlate with p99. | Static/root/post tails are similar or worse, or body-path instrumentation is micro-scale while client p99 remains high. | open |
| H2 | H2 stream scheduling / writer fairness dominates | Multi-stream scheduling, write queue behavior, or frame flush cadence creates occasional delays. | Echo and static tails move together, and server enqueue-to-write or write-complete spans show outliers. | Echo alone is bad while static/root stay low, or server scheduling spans stay micro-scale during p99 events. | open |
| H3 | Measurement/client/kernel artifact remains | oha accounting, client demux, CPU pinning, or socket readiness contributes most of the tail. | Shape/pinning/client changes move p99 more than server code changes, and server spans do not contain the missing latency. | Independent client/server traces put the missing p99 inside Eta server spans. | open |
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

## E1: Hill Setup Baseline

### Hypothesis Space Split
- Parent question: is H2 plain echo 4x4 a stable, actionable hill after removing
  the known 16x1 artifact from the target set?
- Hypothesis under test: H3, measurement/client/kernel artifact remains a live
  rival and must be separated before production optimization.
- Rival hypotheses: H1 body path, H2 H2 writer/scheduler fairness.
- Why this split is high value: the previous 16x1 work proved that apparent H2
  p99 hills can be dominated by scheduling outside the handler/body path.

### Prediction Before Run
- Expected primary metric movement: none; this is the baseline.
- Expected secondary metric movement: none.
- Distinguishing observation: 4x4 echo p99 should be reproducible enough to rank
  against root/post/static and 1x16 echo.
- Falsifier: unstable repeats or guard metrics showing the same tail everywhere,
  which would make immediate server optimization low-confidence.

### Attack
- Change or probe: create a stable measurement facade for H2C/TLS 4x4 endpoint
  p99 plus H2C echo 1x16 guard.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-echo-4x4-actionable-20260615`
- Checks command: `bash .hill-climbing/h2-echo-4x4-actionable-20260615/checks.sh`
- Controls held constant: oha, pinned server/load cores by default, request
  count/repeats fixed by `measure.sh`.

### Result
- Primary metric: `h2_plain_echo_4x4_p99_us=1703.586us`.
- Secondary metrics:
  - `h2_plain_echo_1x16_p99_us=1707.534us`.
  - `h2_plain_echo_4x4_to_1x16_p99_ratio=0.997688`.
  - `h2_tls_echo_4x4_p99_us=1188.181us`.
  - `h2_plain_static_4x4_p99_us=1076.968us`.
  - `h2_plain_post_4x4_p99_us=804.849us`.
  - `h2_plain_user_id_4x4_p99_us=862.589us`.
  - `h2_plain_root_4x4_p99_us=398.762us`.
  - `h2_echo_4x4_success=1.0`.
- Checks: passed. `checks.sh` built probes, ran the reduced measurement smoke,
  asserted required metrics, and passed
  `nix develop -c dune runtest --profile release test/http_eio test/http_common`.
- `log.jsonl` reference: run at `2026-06-15T12:21:40Z`, primary `1703.586`.
  Full baseline TSV:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/results/20260615-142101/h2-echo-4x4-summary.tsv`.

### Verdict
- Verdict: corroborated.
- Reason: the hill is measurable and worth attribution. Echo 4x4 is far above
  root 4x4 and still above static/post/user guards. The 4x4 and 1x16 echo p99s
  are almost identical, so this is not simply the old single-connection H2
  multiplexing shape collapsing away under 4x4.
- Hypothesis space update: H1 and H2 remain live because 1 KiB body cases are
  worse than tiny root. H3 remains live because the 4x4/1x16 similarity and root
  occasional outliers still require server/client/kernel attribution before any
  production optimization.
- Commit/revert decision: keep setup.
- Next experiment: instrument H2 echo 4x4 enough to split request-body read,
  response-body write/flush, and client-observed completion, reusing the prior
  server/client timestamp approach but for 4x4.

## E2: 4x4 Custom Client Attribution

### Hypothesis Space Split
- Parent question: where does H2 plain echo 4x4 p99 live?
- Hypothesis under test: H1 body/copy path is the dominant tail.
- Rival hypotheses: H2 H2 owner/read/write scheduling, H3 client/socket/kernel
  scheduling.
- Why this split is high value: optimizing copies already failed on the previous
  echo hill; the next production change should only happen if the latency is
  inside an Eta-owned segment.

### Prediction Before Run
- Expected primary metric movement: none; attribution only.
- Expected secondary metric movement: none.
- Distinguishing observation: if H1 dominates, handler request-body read/copy or
  accepted-to-response-start should explain most of client p99.
- Falsifier: body copy/read spans remain micro-scale while p99 sits in server
  ingress/write or client receive.

### Attack
- Change or probe: added
  `.hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_custom_client.sh`.
  It runs 4 TCP connections x 4 concurrent H2 streams using
  `h2_gap_client.exe`, records client checkpoints, and joins server phase trace
  by client local port plus stream id.
- Benchmark command:
  `bash .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_custom_client.sh`
- Checks command: pending after helper addition.
- Controls held constant: 24k requests, H2C, `/echo`, 1 KiB request body,
  1 KiB response body, pinned server/load cores unless explicitly varied.

### Result
- Detailed trace with handler/body events:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-142623`
  - total p99 `2315us`.
  - `t1_t2_us_p99=2303us`; `t2_t3_us_p99=3us`; response-body receive is not the
    tail.
  - handler request-body read p99 `286us`.
  - body chunk reader wait p99 `3us`; body copy p99 `1us`.
  - accepted-to-response-start p99 `338us`.
  - response-start-to-flow-complete p99 `1090us`.
  - flow-complete-to-rx-headers p99 `803us`.
- Phase-only trace, avoiding the heavy 407k-line detailed event log:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-142706`
  - total p99 `2453us`.
  - `t1_t2_us_p99=2330us`; `t2_t3_us_p99=2us`.
  - `t1_to_ingress_returned_us_p99=969us`.
  - `accepted_to_response_start_us_p99=182us`.
  - `response_start_to_flow_complete_us_p99=652us`.
  - `flow_complete_to_rx_headers_us_p99=1020us`.
- Client spread across cores `3-6`:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-142725`
  - total p99 `1822us`.
  - post-write client receive gap collapsed:
    `flow_complete_to_rx_headers_us_p99=0us`.
  - server-side span remained high:
    `t1_to_flow_complete_us_p99=1848us`.
- `EIO_BACKEND=posix`:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-142752`
  - total p99 `1623us`.
  - `t1_to_ingress_returned_us_p99=792us`.
  - `response_start_to_flow_complete_us_p99=470us`.
  - `flow_complete_to_rx_headers_us_p99=780us`.
- Static 1 KiB comparison, same 4x4 client shape:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-142849`
  - total p99 `1377us`.
  - `accepted_to_response_start_us_p99=17us`.
  - `t1_to_ingress_returned_us_p99=641us`.
  - `response_start_to_flow_complete_us_p99=642us`.
  - `flow_complete_to_rx_headers_us_p99=1006us`.

### Verdict
- Verdict: H1 rejected as primary; H2 corroborated; H3 partially corroborated.
- Reason: the handler/body copy path is too small to explain the echo p99.
  The client-observed tail is almost entirely before response headers, with
  meaningful contributions from server ingress readiness, owner/request
  acceptance, response write/flush, and client/socket receive scheduling.
  Client spreading removes the post-write receive gap but does not remove the
  server-side `t1 -> flow_complete` tail. Static 1 KiB has a similar response
  write/client receive shape but lower ingress/request-acceptance cost, so echo's
  extra tail is primarily inbound DATA/request scheduling rather than response
  body copying.
- Hypothesis space update: stop chasing handler/body copy. The next production
  experiment should attack H2 connection scheduling around reader -> owner ->
  writer handoff, with separate guards for echo 4x4 and static 4x4. H3 remains a
  guardrail because pinning changes client receive attribution.
- Commit/revert decision: keep attribution helper; no production code change.
- Next experiment: test a tightly scoped H2 owner/write scheduling change or
  scheduling policy change that reduces `t1_to_ingress_returned_us` and
  `response_start_to_flow_complete_us` without regressing static/TLS guards.

## E3: Four-Buffer H2 Ingress Window

### Hypothesis Space Split
- Parent question: is the echo 4x4 tail caused by the reader waiting too often
  for owner ack before it can read more socket data?
- Hypothesis under test: increasing the per-connection ingress handoff window
  from two buffers to four reduces ingress-read p99 and therefore echo p99.
- Rival hypotheses: the tail is caused by owner/write scheduling, kernel socket
  readiness, or client receive timing, not by the number of available handoff
  buffers.
- Why this split is high value: the trace showed high `t1_to_ingress_returned`
  p99 for echo/static, and the current reader has exactly two owned buffers.

### Prediction Before Run
- Expected primary metric movement: lower `h2_plain_echo_4x4_p99_us`.
- Expected secondary metric movement: static 4x4 and TLS echo should not regress;
  1x16 echo may improve if reader handoff is shared root cause.
- Distinguishing observation: p99 decreases without throughput loss.
- Falsifier: primary regresses or guardrails degrade.

### Attack
- Change or probe: temporarily changed the H2 reader's owned ingress buffers from
  two to four and rotated with modulo instead of `land 1`.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-echo-4x4-actionable-20260615`
- Checks command: runner check gate.
- Controls held constant: official hill facade, 24k x 9, same guards.

### Result
- Primary metric: regressed from best `1703.586us` to `1834.130us`.
- Secondary metrics:
  - `h2_plain_echo_1x16_p99_us=1805.966us`, worse than prior `1707.534us`.
  - `h2_plain_static_4x4_p99_us=990.906us`, better than prior `1076.968us`.
  - `h2_tls_echo_4x4_p99_us=1132.047us`, better than prior `1188.181us`.
  - `h2_echo_4x4_rps_geomean=61896.619`, lower than prior `62871.315`.
  - `h2_echo_4x4_success=1.0`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T12:31:55Z`, primary `1834.130`.

### Verdict
- Verdict: rejected.
- Reason: the primary hill regressed and throughput fell. Some guards improved,
  which suggests the buffer window changes scheduling shape, but it is not a
  valid fix for the selected hill.
- Hypothesis space update: simple reader-buffer widening is not the right lever.
  Keep H2 owner/read/write scheduling as the target, but prefer changes that
  alter work ordering/fairness rather than buffering more unread ingress.
- Commit/revert decision: reverted the four-buffer production change.
- Next experiment: inspect/write-test a narrower owner scheduling change, or
  build a trace that attributes owner command queue wait directly before trying
  another production tweak.

## E4: Owner Queue And Writer Queue Split

### Hypothesis Space Split
- Parent question: is the remaining H2 echo 4x4 tail inside Eta's owner command
  queue or writer queue?
- Hypothesis under test: H2 owner/read/write scheduling is still actionable, and
  specifically queue wait before ingress handling or before write execution
  explains p99.
- Rival hypotheses: socket read readiness, kernel/client scheduling, or actual
  flow writes explain the tail.
- Why this split is high value: E2 showed high `t1_to_ingress_returned` and
  `response_start_to_flow_complete`, but those segments still mixed queue wait
  with socket/write work.

### Prediction Before Run
- Expected primary metric movement: none; this is attribution instrumentation.
- Expected secondary metric movement: none.
- Distinguishing observation: if owner/write queue wait dominates, new phase
  metrics should show large p99 in `ingress_queue_wait_us` or
  `write_job_wait_us`.
- Falsifier: both queue waits stay small while p99 remains high.

### Attack
- Change or probe: added env-gated phase trace points under
  `ETA_H2_PHASE_TRACE_PATH`:
  - `h2_phase_ingress_handle_start` with ingress command queue wait.
  - `h2_phase_write_job_start` with writer job queue wait.
  - parser metrics for write-job start, queue wait, and actual `flow_write_us`.
- Benchmark command:
  `ETA_H2_ECHO_4X4_TRACE_EVENTS=0 bash .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_custom_client.sh`
- Static comparison:
  `ETA_H2_ECHO_4X4_TRACE_EVENTS=0 ETA_H2_ECHO_4X4_TRACE_METHOD=GET ETA_H2_ECHO_4X4_TRACE_BODY_BYTES=0 ETA_H2_ECHO_4X4_TRACE_PATH=/static/1k.bin ETA_H2_ECHO_4X4_TRACE_EXPECTED_BYTES=1024 bash .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_custom_client.sh`
- Checks command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-echo-4x4-actionable-20260615`
- Controls held constant: same 4x4 custom-client shape, phase-only trace, no
  detailed event trace, no production optimization.

### Result
- Echo trace:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-143527`
  - total p99 `1962us`.
  - `t1_t2_us_p99=1950us`; `t2_t3_us_p99=2us`.
  - `t1_to_ingress_returned_us_p99=844us`.
  - `ingress_queue_wait_us_p99=31us`.
  - `ingress_handle_start_to_accepted_us_p99=4us`.
  - `accepted_to_response_start_us_p99=169us`.
  - `response_start_to_write_job_start_us_p99=214us`.
  - `write_job_wait_us_p99=34us`.
  - `flow_write_us_p99=263us`.
  - `flow_complete_to_rx_headers_us_p99=845us`.
- Static 1 KiB trace:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-143542`
  - total p99 `1428us`.
  - `t1_to_ingress_returned_us_p99=649us`.
  - `ingress_queue_wait_us_p99=28us`.
  - `accepted_to_response_start_us_p99=17us`.
  - `response_start_to_write_job_start_us_p99=248us`.
  - `write_job_wait_us_p99=29us`.
  - `flow_write_us_p99=248us`.
  - `flow_complete_to_rx_headers_us_p99=989us`.
- Official hill facade, tracing disabled:
  - run at `2026-06-15T12:36:59Z`, primary `1620.190us`, checks passed.
  - `h2_echo_4x4_success=1.0`.
  - `h2_tls_echo_4x4_p99_us=1177.954us`.
  - `h2_plain_static_4x4_p99_us=965.797us`.

### Verdict
- Verdict: queue-wait hypothesis rejected; socket/readiness hypothesis
  corroborated.
- Reason: owner command queue and writer queue waits are both tens of
  microseconds at p99. They cannot explain the ~1.4-2.0ms client-observed p99.
  The remaining large segments are server socket read readiness
  (`t1_to_ingress_returned`), client-visible receive after server flow write,
  and rarer actual flow-write stalls visible near p99.9. Eta already sets
  `TCP_NODELAY` on accepted TCP flows, so the obvious socket option lever is not
  missing.
- Hypothesis space update: do not spend the next experiment on queue/fairness
  rewrites. Keep the phase instrumentation because it prevents future false
  attribution. The next decision should be either a lower-level socket/kernel
  attribution probe or moving to the next actionable Eta-owned hill.
- Commit/revert decision: keep env-gated attribution instrumentation and helper
  parser; no production optimization was made.
- Next experiment: run a same-shape second-client/kernel attribution or rerank
  actionable hills excluding cases where the dominant p99 is outside Eta-owned
  queues and handlers.

## E5: Fresh Rerank And Worth-Climbing Decision

### Hypothesis Space Split
- Parent question: should H2 plain echo 4x4 remain the active production
  optimization hill?
- Hypothesis under test: H2 plain echo 4x4 is still a high-confidence Eta-owned
  hill.
- Rival hypotheses: the remaining tail is mostly socket/client/kernel
  scheduling, or the broad-suite ranking is currently dominated by noisy H2
  4x4 samples rather than stable endpoint-specific work.
- Why this split is high value: E4 rejected the obvious owner/writer queue
  explanation, so another production tweak would be speculative unless the
  rerank shows a clear and stable Eta-owned target.

### Prediction Before Run
- Expected primary metric movement: none; decision-only rerank.
- Expected secondary metric movement: none.
- Distinguishing observation: if the hill is worth production optimization, it
  should remain a stable top case and attribution should point inside Eta-owned
  request/response work.
- Falsifier: top cases are noisy and the current hill's traces keep putting the
  missing latency in socket/readiness/client-observed segments.

### Attack
- Change or probe: ran a fresh Eta-only quick server-load rerank after excluding
  the known H2 16x1 scheduling-sensitive shape.
- Benchmark command:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --out http-testsuite/results/manual-server-load-20260615-actionable-rerank-2`
- Checks command: not a production-change check; the run completed and wrote
  `http-testsuite/results/manual-server-load-20260615-actionable-rerank-2/server_load.json`.
- Controls held constant: existing server-load quick profile and current dirty
  tree.

### Result
- Top actionable p99 cases after 16x1 exclusion:
  - H2 plain root 4x4: `1116.355us`, repeats
    `[3951.668, 1116.355, 710.980]`.
  - H2 plain echo_1k 4x4: `991.576us`, repeats
    `[1185.418, 891.064, 991.576]`.
  - H2 plain echo_1k 1x16: `976.949us`, repeats
    `[976.949, 1000.944, 938.545]`.
  - H2 plain static_1k 4x4: `953.293us`, repeats
    `[893.088, 2027.447, 953.293]`.
  - H2 TLS echo_1k 4x4: `951.350us`, repeats
    `[926.572, 992.148, 951.350]`.
- Current hill status: latest official hill run is passing with
  `h2_plain_echo_4x4_p99_us=1620.190us`,
  `h2_echo_4x4_success=1.0`, and checks passed.
- Attribution status from E4 remains unchanged: owner queue p99 and writer queue
  p99 are both only tens of microseconds, while large spans remain in socket
  readiness, actual flow write, and client-observed receive.

### Verdict
- Verdict: split-needed.
- Reason: H2 echo 4x4 is still real enough to measure, but not yet a
  high-confidence production optimization hill. The latest broad rerank shows
  H2 4x4 cases are still the high-p99 cluster, but root/static have noisy repeats
  and the current echo attribution does not put the missing millisecond inside
  Eta handler, body, owner queue, or writer queue work.
- Hypothesis space update: keep this session as an attribution hill, not as a
  mandate for speculative server-code optimization. A production change is only
  justified if a lower-level socket/write probe moves the large p99 segment back
  into Eta-owned behavior.
- Commit/revert decision: no production change.
- Next experiment: either add a lower-level socket/write timestamp sanity check
  for the H2 4x4 cluster, or set up the next stable Eta-owned hill after
  excluding H2 cases whose current p99 is dominated by socket/readiness
  attribution.

## E6: Syscall-Level Socket/Write Sanity Probe

### Hypothesis Space Split
- Parent question: does the remaining H2 echo 4x4 p99 live in kernel socket
  read/write syscall duration, or above/beside the raw syscalls?
- Hypothesis under test: the server is blocked in actual TCP read/write syscalls
  for the missing millisecond-scale p99.
- Rival hypotheses: the tail is scheduling/readiness around the H2/Eio event
  loop, client-observed timing, or io_uring wakeup/accounting that is not a
  simple slow `read`/`write` syscall.
- Why this split is high value: E4 showed owner/writer queues are not the
  dominant wait, but `flow_write_us` and ingress-readiness spans were still
  mixed with runtime/kernel behavior.

### Prediction Before Run
- Expected primary metric movement: none; attribution helper only.
- Expected secondary metric movement: none.
- Distinguishing observation: if raw TCP syscalls dominate, `strace` should show
  TCP read/write syscall p99 near the client-observed p99.
- Falsifier: TCP read/write syscall p99 remains tens of microseconds while
  client/app spans remain around 1-2ms.

### Attack
- Change or probe: added an env-gated server `strace` mode to
  `trace_echo_4x4_custom_client.sh`, plus
  `trace_echo_4x4_syscalls.sh` as a small wrapper. The wrapper defaults to a
  short sample, disables detailed event trace, enables slow-write tracing at
  threshold `0`, and drops the first 8 requests per client from latency
  distributions so startup does not dominate tiny samples.
- Default-backend command:
  `ETA_H2_ECHO_4X4_TRACE_REQUESTS=256 bash .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_syscalls.sh`
- Posix syscall command:
  `ETA_H2_ECHO_4X4_TRACE_REQUESTS=256 ETA_H2_ECHO_4X4_STRACE_EIO_BACKEND=posix bash .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_syscalls.sh`
- Checks command:
  `bash .hill-climbing/h2-echo-4x4-actionable-20260615/checks.sh`
- Controls held constant: same custom 4x4 H2C `/echo` shape, 1 KiB request and
  response, no production behavior change.

### Result
- Default backend trace:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-144925`
  - `success=1`.
  - `total_us_p99=1053us`.
  - `t1_t2_us_p99=1044us`.
  - `t1_to_ingress_returned_us_p99=607us`.
  - `response_start_to_write_job_start_us_p99=375us`.
  - `write_job_wait_us_p99=178us`.
  - `flow_write_us_p99=494us`.
  - TCP syscall counts were zero because the normal backend uses io_uring for
    socket I/O under this trace.
- Posix backend trace:
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/20260615-144911`
  - `success=1`.
  - `total_us_p99=1960us`.
  - `t1_t2_us_p99=1954us`.
  - `t1_to_ingress_returned_us_p99=1032us`.
  - `response_start_to_write_job_start_us_p99=933us`.
  - `write_job_wait_us_p99=263us`.
  - `flow_write_us_p99=344us`.
  - `flow_complete_to_rx_headers_us_p99=330us`.
  - `strace_tcp_read_syscall_p99_us=17us`.
  - `strace_tcp_write_syscall_p99_us=17us`.
  - `strace_wait_syscall_p99_us=5us`.
- Checks: passed. `git diff --check` passed.

### Verdict
- Verdict: raw TCP syscall-duration hypothesis rejected.
- Reason: in the posix run, steady-state client p99 remains about `2ms`, but raw
  TCP read/write syscall p99 is only `17us`. The normal backend cannot be split
  by TCP fd syscall because it routes through io_uring, but its app/client phase
  shape is consistent with the earlier traces: p99 is in ingress readiness,
  response scheduling/write completion, and client-observed delivery, not a
  long blocking TCP `write`.
- Hypothesis space update: do not optimize handler/body/copy, H2 owner queue,
  writer queue, or raw TCP syscall duration for this hill. The remaining H2 echo
  4x4 work is runtime/socket-readiness attribution, not an obvious Eta HTTP
  production-code hill.
- Commit/revert decision: keep the attribution helper; no production code
  change.
- Next experiment: move to the next stable Eta-owned hill unless future evidence
  specifically attributes the H2 4x4 cluster to Eta HTTP code rather than
  Eio/kernel/client scheduling.

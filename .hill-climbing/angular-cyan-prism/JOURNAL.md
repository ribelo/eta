# Research Journal: angular-cyan-prism

## Hill

- Goal: attribute and improve the remaining Eta H2C `POST /echo` 1 KiB p99 tail by comparing stream shapes at the same total concurrency.
- Primary metric: `h2_plain_echo_1k_1x16_p99_ms`
- Direction: lower
- Benchmark facade: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id angular-cyan-prism`
- Session directory: `.hill-climbing/angular-cyan-prism/`

## Anti-Gaming Contract

The goal is to improve the real H2 plain echo tail, not merely to make this script look better. Do not reduce request count, reduce repeats, change body size, weaken success checks, special-case `/echo`, cache invalidly, skip response work, or trade away H1/H2 correctness. Benchmark changes are setup changes and must be documented separately from production experiments.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_echo_1k_1x16_p99_ms` | Primary | lower | Keep production changes only if this improves beyond repeat noise, checks pass, and the shape matrix does not show a worse broad regression. | H2C, one connection, sixteen streams, 24k requests x 9 repeats. |
| `h2_plain_echo_1k_1x16_p995_ms` | Tail detail | lower | Used to detect whether p99 movement hides a worse deeper tail. | Computed from raw `oha --db-url` samples. |
| `h2_plain_echo_1k_4x4_p99_ms` | Attribution | lower/stable | If this collapses versus 1x16, suspect single-connection H2 multiplexing/fairness/wakeup behavior. | Same total concurrency: four connections x four streams. |
| `h2_plain_echo_1k_16x1_p99_ms` | Attribution | lower/stable | If this collapses versus 1x16, suspect per-connection multiplexing more than broad H2 request handling. | Same total concurrency: sixteen connections x one stream. |
| `h1_plain_echo_1k_16_p99_ms` | Attribution guardrail | lower/stable | If H1 has similar tail, suspect broader echo/write timing or client/kernel measurement noise. | HTTP/1.1, sixteen keep-alive connections. |
| `*_p99_mad_ms`, `*_p99_min_ms`, `*_p99_max_ms` | Noise | lower/stable | Wide spread requires confirmation before accepting a code change. | Median-of-9 repeats plus repeat range. |
| `*_ok`, `success` | Correctness | exactly 1 | Any zero invalidates the run. | Checks expected status/body success through `oha` distributions and raw sample count. |

Noise policy:

- Treat p99 changes below the repeat MAD as inconclusive unless the change also simplifies code and does not hurt any shape.
- Prefer explanations where the same production change improves multiple repeats, not just the best repeat.
- If 1x16 is the only bad shape, do not optimize handler/body copies; split H2 multiplexing and writer wakeups next.
- If all shapes show the same tail, do not touch H2-specific code until client/load/kernel noise is ruled out.

## Hypothesis Space

Root question:

> What mechanism currently causes the remaining H2 plain echo_1k p99 tail?

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Single-connection multiplexing/fairness | Sixteen streams on one H2 connection create scheduling or writer fairness outliers. | 1x16 p99 is materially worse than 4x4 and 16x1. | 4x4/16x1 are equally bad. | open |
| H2 | Per-connection writer wakeup/batching | Write fiber wake or batching under H2 creates tail independent of stream fanout. | H2 shapes share the tail, while H1 is materially better. | H1 has similar p99 or only 1x16 is bad. | open |
| H3 | Client/load/kernel artifact | `oha`, local scheduling, or kernel timing produces rare outliers unrelated to Eta H2 internals. | All H2 shapes and H1 show similar p99/max spread. | Shape-specific collapse. | open |
| H4 | H2 stream-local stall | A small set of server stream IDs repeatedly account for slow server-side phases. | Slow stream IDs cluster in traced stream metrics. | Slow IDs are uniformly distributed or server phases stay far below client p99. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it. | A better split replaces it. | open |

## Experiment Selection Rule

- First run establishes the stream-shape matrix baseline.
- If 1x16 is uniquely worse, instrument H2 enqueue-to-writer-wake-to-write-complete before changing scheduling.
- If all shapes are noisy, add a client/load artifact control before production changes.
- Keep production changes only when the primary improves and the attribution story remains coherent.

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

## E0: stream-shape matrix baseline

### Hypothesis Space Split
- Parent question: Is the remaining H2 echo p99 tied to one H2 connection with many streams, to H2 broadly, or to local client/kernel noise?
- Hypothesis under test: baseline attribution only.
- Rival hypotheses: H1 single-connection multiplexing/fairness, H2 writer wakeup/batching, H3 client/load/kernel artifact, H4 stream-local stall.
- Why this split is high value: it compares 1x16, 4x4, 16x1, and H1 at the same total concurrency before another production change.

### Prediction Before Run
- Expected primary metric movement: none.
- Expected secondary metric movement: shape ratios should identify whether the tail is 1x16-specific, H2-specific, or broad.
- Distinguishing observation: 4x4/16x1 collapse implies H2 multiplexing/fairness; H1 collapse implies H2-specific rather than broad echo/client noise.
- Falsifier: all shapes have the same p99 spread.

### Attack
- Change or probe: fresh matrix facade using raw `oha --db-url` samples for p99.5 and max per repeat.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id angular-cyan-prism`
- Checks command: `dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: 1 KiB POST `/echo`, total concurrency 16, 24k requests x 9 repeats per shape.

### Result
- Primary metric: `h2_plain_echo_1k_1x16_p99_ms=1.707913`, p99.5 `2.175597`, p99 MAD `0.179143`.
- Secondary metrics: H2 4x4 p99 `1.067630` (ratio `0.625108`); H2 16x1 p99 `1.155517` (ratio `0.676567`); H1 16 p99 `0.243254` (ratio `0.142428`).
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T08:46:07Z`.

### Verdict
- Verdict: split-needed
- Reason: H1 collapses the p99, so this is H2-specific; 4x4/16x1 also improve materially, so one H2 connection with many concurrent streams is the sharpest shape.
- Hypothesis space update: H3 broad client/load/kernel artifact is weakened. H1 multiplexing/fairness and H2 writer wakeup/batching remain live.
- Commit/revert decision: keep hill setup.
- Next experiment: add diagnostic timing for write-job enqueue to writer-fiber start/completion under trace, then run the matrix with a traced 1x16 diagnostic phase.

## E1: writer wake trace

### Hypothesis Space Split
- Parent question: Is the 1x16 p99 tail caused by delayed writer wakeup or flow writes after H2 schedules response frames?
- Hypothesis under test: H2 writer wakeup/batching.
- Rival hypotheses: single-connection multiplexing before server acceptance, client/load timing, or residual H2 scheduling outside the traced write path.
- Why this split is high value: it measures enqueue-to-writer-start and flow-write duration directly without changing the clean primary matrix.

### Prediction Before Run
- Expected primary metric movement: none; this is diagnostic instrumentation with the primary phase untraced.
- Expected secondary metric movement: if writer wakeup is the tail, `h2_trace_1x16_write_job_wait_us_p99` or `h2_trace_1x16_flow_write_us_p99` should approach client p99.
- Distinguishing observation: traced writer phases near milliseconds would justify a production scheduling change.
- Falsifier: traced writer phases remain hundreds of microseconds or less while clean client p99 stays around 1.7ms.

### Attack
- Change or probe: added env-gated trace events for write-job start and flow-write completion; added a short traced 1x16 diagnostic phase before the clean matrix.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id angular-cyan-prism`
- Checks command: `dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: clean primary matrix remains untraced and unchanged.

### Result
- Primary metric: `h2_plain_echo_1k_1x16_p99_ms=1.767037`, p99.5 `2.203751`.
- Secondary metrics: writer job wait p99 `5 us`; flow-write p99 `245 us`; response-write p99 `359 us`; accepted-to-body p99 `271 us`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T08:48:42Z`.

### Verdict
- Verdict: rejected
- Reason: enqueue-to-writer-start is negligible, and traced write durations are far below the clean client-side p99.
- Hypothesis space update: simple writer wake delay is not the hill. The remaining gap is either before server acceptance, after server write completion, or a traced/clean workload mismatch.
- Commit/revert decision: keep diagnostic instrumentation and facade because it improves future discrimination and is env-gated.
- Next experiment: compute accepted-request-to-write-complete per stream in the trace parser and compare it to client p99.

## E2: accepted-to-write-complete server/client gap

### Hypothesis Space Split
- Parent question: Is the clean client-side 1x16 p99 visible inside the server from request acceptance through write completion?
- Hypothesis under test: server-internal H2 processing still owns most of the tail.
- Rival hypotheses: client/load timing, kernel delivery after server write, or H2 client multiplexing before request acceptance.
- Why this split is high value: it directly compares server accepted-to-complete p99 to clean client p99 without another production change.

### Prediction Before Run
- Expected primary metric movement: none; parser-only diagnostic.
- Expected secondary metric movement: if server internals own the tail, accepted-to-write-complete p99 should approach clean client p99.
- Distinguishing observation: server accepted-to-complete near milliseconds would justify production scheduling work.
- Falsifier: server accepted-to-complete remains far below clean client p99.

### Attack
- Change or probe: extended trace parser to compute accepted-to-response-start and accepted-to-write-complete per stream.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id angular-cyan-prism`
- Checks command: hill `checks.sh`.
- Controls held constant: same clean primary matrix and traced diagnostic pass.

### Result
- Primary metric: `h2_plain_echo_1k_1x16_p99_ms=1.957741`, p99.5 `2.427869`.
- Secondary metrics: accepted-to-response-start p99 `406 us`; accepted-to-write-complete p99 `611 us`; writer job wait p99 `35 us`; flow-write p99 `192 us`; response-write p99 `395 us`.
- Shape metrics: H2 4x4 p99 `1.097637` (ratio `0.560665`); H2 16x1 p99 `1.162411` (ratio `0.593751`); H1 16 p99 `0.274064` (ratio `0.139990`).
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T08:49:47Z`.

### Verdict
- Verdict: split-needed
- Reason: the clean client-side p99 is much larger than the traced server accepted-to-write-complete p99. The remaining 1x16 tail is H2-shape-specific, but not explained by the measured server request/write phases.
- Hypothesis space update: weaken H2 server writer wake/batching as a production-code hill. The next split should instrument client-visible timing or compare another load generator/reference before production tweaks.
- Commit/revert decision: keep the fresh hill setup and env-gated diagnostics; do not make a speculative production optimization.
- Next experiment: outside this climb, add a load-generator/client control or server-side kernel write/backpressure probe if this remains a priority.

## Final Status

- Hill setup: complete. The facade measures H2 1x16, H2 4x4, H2 16x1, and H1 16 at 24k requests x 9 repeats with raw `oha` sample p99.5/max.
- Attribution result: H2 1x16 is consistently the worst shape; 4x4 and 16x1 partially collapse p99; H1 collapses it much further.
- Server trace result: accepted-to-write-complete p99 stays under `0.7 ms` while clean client p99 is around `1.7-2.0 ms`.
- Production decision: no safe production optimization accepted in this hill. The current evidence points to H2 shape/client/kernel timing outside the measured server request/write path.
- Verification: hill checks passed on all runs; `git diff --check` passed. Full `nix develop -c dune runtest --force` still fails at the pre-existing HPACK header type mismatch in `test/http/test_eta_http_h2_hpack.ml:42` and `test/http/test_eta_http_h2_server.ml:352`.

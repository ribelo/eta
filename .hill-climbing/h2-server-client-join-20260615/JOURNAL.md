# Research Journal: h2-server-client-join-20260615

## Hill

- Goal: split the custom-client `t1 -> rx_headers` H2C 1x16 gap by joining client checkpoints to server trace events.
- Primary metric: `h2c_join_write_complete_to_rx_headers_p99_us`
- Direction: lower, but this hill is primarily diagnostic.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h2-server-client-join-20260615`
- Session directory: `.hill-climbing/h2-server-client-join-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2c_join_write_complete_to_rx_headers_p99_us` | Primary | lower | Large value means bytes leave server but are not client-readable promptly | Derived from server `Flow.write` completion approximation to client `rx_headers` |
| `h2c_join_t1_to_accepted_p99_us` | Secondary | lower | Large value means client-written request waits before server accepts it | Signed join from client `t1` to server `h2_request_accepted` |
| `h2c_join_accepted_to_flow_complete_p99_us` | Secondary | lower | Large value means server app/body/write path dominates | Server accepted to derived `Flow.write` completion |
| `h2c_join_rx_headers_to_t2_p99_us` | Secondary | lower | Large value means client parser/demux callback dominates | Client socket read response HEADERS to H2 response callback |
| `h2c_join_tail1pct_*` | Secondary | n/a | Classifies the same slow rows instead of comparing independent p99s | Top 1% by `t1 -> rx_headers` |

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
| H1 | post-server-write delivery dominates | Server writes response, but loopback/kernel/client wakeup delays client-readable HEADERS | `write_complete -> rx_headers` dominates p99 and top 1% rows | Top 1% dominated by earlier segments | rejected for traced p99 |
| H2 | server accepted-to-write dominates | Server body/read/response/write scheduling consumes the p99 tail | `accepted -> flow_complete` dominates top 1% rows | Tail rows dominated elsewhere | corroborated |
| H3 | request ingress/pre-accept dominates | Client write completes but server accepts much later | `t1 -> accepted` dominates top rows | Tail rows dominated elsewhere | partially corroborated |
| H4 | client H2 demux dominates | Socket has HEADERS, parser/callback is delayed | `rx_headers -> t2` dominates | Segment stays small in top rows | rejected |
| H5 | request body read dominates server accepted-to-flow | Handler starts promptly but waits for body availability | `handler_started -> body_available` dominates accepted-to-flow p99/tail | Handler start/write subsegments dominate instead | corroborated |
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

## E1: Join Client Checkpoints To Server Trace

### Hypothesis Space Split
- Parent question: where inside `client t1 -> client rx_headers` does the H2C 1x16 tail live?
- Hypothesis under test: H1-H4 above.
- Rival hypotheses: post-write delivery, server accepted-to-write, pre-accept ingress, client demux.
- Why this split is high value: it joins client and server timestamps per stream, avoiding inference from separate runs.

### Prediction Before Run
- Expected primary metric movement: if post-write delivery is the hill, `write_complete -> rx_headers` should be the largest p99 and dominate slow rows.
- Expected secondary metric movement: if server work is the hill, `accepted -> flow_complete` and its top-1% fraction should dominate.
- Distinguishing observation: top 1% rows by `t1 -> rx_headers` identify the dominant segment for the same slow requests.
- Falsifier: independent p99s point one way but top rows show another segment.

### Attack
- Change or probe: one repeat per fresh H2C probe with `ETA_H2_ECHO_TRACE_PATH`, joined to `h2_gap_client` checkpoints by `stream_id`.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-server-client-join-20260615`
- Checks command: `.hill-climbing/h2-server-client-join-20260615/checks.sh`
- Controls held constant: H2C, 1 connection, 16 streams, `/echo`, 1024-byte body. Default traced workload is 8k requests x 5 repeats to avoid trace-file I/O becoming the workload.

### Result
- Primary metric: `h2c_join_write_complete_to_rx_headers_p99_us=266`
- Secondary metrics:
  - `t1 -> rx_headers p99=1021 us`, p99.5 `1110 us`, max `6529 us`
  - `t1 -> accepted p99=454 us`
  - `accepted -> body_available p99=362 us`
  - `accepted -> response_start p99=525 us`
  - `accepted -> flow_complete p99=831 us`
  - `rx_headers -> t2 p99=346 us`
  - `t2 -> t3 p99=8 us`
  - top 1% dominant segment fractions: accepted-to-flow `0.6125`, pre-accept `0.375`, flow-to-rx `0.0`, rx-to-t2 `0.0`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T09:31:51Z`.

### Verdict
- Verdict: corroborated H2, partially corroborated H3, rejected H1/H4 for the traced p99 tail.
- Reason: independent p99s show `accepted -> flow_complete` is larger than post-write delivery, and top 1% slow rows are dominated by accepted-to-flow in the median repeat. A single repeat produced a large pre-accept batch outlier, so request ingress/client-to-server scheduling remains a secondary live branch.
- Hypothesis space update: next split should break `accepted -> flow_complete` into H2 request-body delivery/read scheduling, handler response start, write-ready batching, writer job wait, and `Flow.write`.
- Commit/revert decision: keep measurement scripts and client changes; no server optimization was attempted.
- Next experiment: focus on the server-side accepted-to-flow segment, using already traced body/response/write-ready/job-wait/flow-write fields and top-row classification.

## E2: Split Accepted-To-Flow Server Segment

### Hypothesis Space Split
- Parent question: why does `accepted -> flow_complete` dominate the joined p99 tail?
- Hypothesis under test: H5, request body read/availability dominates.
- Rival hypotheses: handler dispatch delay, response construction/start, write-ready batching, writer job wait, or `Flow.write` itself.
- Why this split is high value: it uses existing trace fields (`handler_started_us`, `body_available_us`, response start, write-ready, job wait, flow write) and classifies the same slow accepted-to-flow rows.

### Prediction Before Run
- Expected primary metric movement: no code optimization; diagnostic metrics only.
- Expected secondary metric movement: if body read dominates, `handler_started -> body_available` p99 should be the largest accepted-to-flow subsegment.
- Distinguishing observation: top 1% accepted-to-flow rows should most often be dominated by body read.
- Falsifier: write-ready/job-wait/flow-write dominates the same rows.

### Attack
- Change or probe: extended `.hill-climbing/h2-server-client-join-20260615/measure.sh` to emit accepted-to-flow subsegments and dominant tail fractions.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-server-client-join-20260615`
- Checks command: `.hill-climbing/h2-server-client-join-20260615/checks.sh`
- Controls held constant: H2C, 1 connection, 16 streams, `/echo`, 1024-byte body, traced 8k requests x 5 repeats.

### Result
- Primary metric: `h2c_join_write_complete_to_rx_headers_p99_us=363`
- Key joined metrics:
  - `t1 -> rx_headers p99=1126 us`, p99.5 `1201 us`, max `1913 us`
  - `t1 -> accepted p99=464 us`
  - `accepted -> handler_started p99=6 us`
  - `handler_started -> body_available p99=435 us`
  - `accepted -> body_available p99=442 us`
  - `body_available -> response_start p99=95 us`
  - `response_start -> write_ready p99=218 us`
  - `write_ready -> job_start p99=152 us`
  - `job_start -> flow_complete p99=86 us`
  - `accepted -> flow_complete p99=976 us`
  - `rx_headers -> t2 p99=460 us`
- Tail classification:
  - top 1% `t1 -> rx_headers`: accepted-to-flow dominates `0.6875`, pre-accept `0.3125`
  - top 1% accepted-to-flow: body read dominates `0.45`; response start `0.1625`; flow write `0.15`; write-ready `0.1125`; job wait `0.1125`; handler start `0.0125`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T09:35:45Z`.

### Verdict
- Verdict: corroborated H5.
- Reason: handler dispatch after H2 acceptance is negligible (`6 us` p99), but body availability after handler start is the largest accepted-to-flow subsegment (`435 us` p99) and the most common dominant segment in the accepted-to-flow tail.
- Hypothesis space update: the next hill should split H2 request-body availability/read scheduling, not response write/copy or client demux. The live secondary branch is pre-accept ingress (`t1 -> accepted p99=464 us`).
- Commit/revert decision: keep measurement-only script changes.
- Next experiment: add/consume request-body DATA timing to split handler body read into DATA arrival/copy, body-reader scheduling, and `Body.read_all` accumulation.

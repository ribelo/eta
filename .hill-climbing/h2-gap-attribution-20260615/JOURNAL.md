# Research Journal: h2-gap-attribution-20260615

## Hill

- Goal: attribute the missing H2 plain `echo_1k` 1x16 p99 gap without optimizing server code.
- Primary metric: `custom_h2c_echo_1x16_t0_t3_p99_ms`
- Direction: lower, but this hill is primarily diagnostic.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h2-gap-attribution-20260615`
- Session directory: `.hill-climbing/h2-gap-attribution-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `custom_h2c_echo_1x16_t0_t3_p99_ms` | Primary | lower | Compare to oha p99 and server accepted-to-write span | Custom client observed end-to-end latency |
| `custom_h2c_echo_1x16_t0_t1_p99_ms` | Secondary | lower | Large value means client write scheduling dominates | `t1` is after DATA `END_STREAM` socket write |
| `custom_h2c_echo_1x16_t1_rx_headers_p99_ms` | Secondary | lower | Large value means delay occurs before client reads response HEADERS bytes | Contains server processing plus kernel/scheduling/wire time |
| `custom_h2c_echo_1x16_rx_headers_t2_p99_ms` | Secondary | lower | Large value means H2 parser/demux callback dominates | Socket read returned HEADERS before this segment |
| `custom_h2c_echo_1x16_t2_t3_p99_ms` | Secondary | lower | Large value means response body/client read after headers dominates | Body completion after response headers callback |

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
| H1 | oha/client accounting artifact | oha overstates completion latency for H2 1x16 | Custom client p99 collapses near server span (~0.6 ms) | Custom client p99 remains ~1.5-2.0 ms | rejected |
| H2 | client write-side scheduling | Request queue/body write dominates p99 | `t0->t1` is close to total p99 | `t0->t1` stays tiny | rejected |
| H3 | client H2 demux/body receive | Bytes are available but client parser/body callbacks dominate | `rx_headers->t2` or `t2->t3` dominates | Both are tiny | rejected |
| H4 | pre-client-read response delay | Delay occurs after client request body write and before client socket read returns response HEADERS | `t1->rx_headers` dominates | Another segment dominates | corroborated |
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

## E1: Custom H2C Checkpoint Client

### Hypothesis Space Split
- Parent question: is the H2 1x16 `echo_1k` p99 gap in server work, benchmark accounting, client receive/demux, or scheduler/kernel time outside app spans?
- Hypothesis under test: H1/H2/H3/H4 above.
- Rival hypotheses: oha-only artifact, client write scheduling, client H2 demux/body read, or pre-client-read response delay.
- Why this split is high value: it instruments the same 1x16 workload from a second client and adds checkpoints around socket write/read and H2 callbacks.

### Prediction Before Run
- Expected primary metric movement: if oha is the artifact, custom p99 should collapse near the server accepted-to-write p99 (~0.6 ms).
- Expected secondary metric movement: if client demux/body read is the issue, `rx_headers->t2` or `t2->t3` should dominate.
- Distinguishing observation: the largest p99 segment identifies where the missing time sits.
- Falsifier: custom p99 stays high and a non-oha segment dominates.

### Attack
- Change or probe: added `http-testsuite/test/server_load/h2_gap_client.ml` and hill scripts.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-gap-attribution-20260615`
- Checks command: `.hill-climbing/h2-gap-attribution-20260615/checks.sh`
- Controls held constant: H2C, one connection, 16 concurrent streams, `/echo`, 1024-byte body, 24k requests, 9 repeats.

### Result
- Primary metric: `custom_h2c_echo_1x16_t0_t3_p99_ms=1.566`
- Secondary metrics:
  - `t0->t1 p99=0.044 ms`
  - `t1->rx_headers p99=1.532 ms`
  - `rx_headers->t2 p99=0.010 ms`
  - `t1->t2 p99=1.549 ms`
  - `t2->t3 p99=0.005 ms`
  - `p99.5=1.759 ms`, repeat max `7.007 ms`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T09:09:16Z`.

### Verdict
- Verdict: corroborated H4; rejected H1, H2, and H3 for this hill.
- Reason: the custom client reproduces the high p99, so this is not oha-only. The dominant segment is after the client has written request DATA `END_STREAM` and before the client socket read returns response HEADERS bytes. H2 parser/demux and body completion after headers are ~10 us / ~6 us at p99.
- Hypothesis space update: the missing time lives before client response HEADERS are readable. The next split is server-side pre-accepted/body availability vs server-write-to-client-read/kernel scheduling/loopback timing.
- Commit/revert decision: keep the measurement tool and hill scripts; no production server optimization was made.
- Next experiment: co-run server trace with the custom client, or add packet/off-CPU timestamps to split client-write -> server-accepted and server-write-complete -> client-readable HEADERS.

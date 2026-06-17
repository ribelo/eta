# Research Journal: h2-plain-echo-1x16-p99-vs-node-20260615

## Hill

- Goal: reduce Eta H2 plain `echo_1k` p99 versus Node under one connection and
  sixteen concurrent streams, without regressing throughput, correctness, or
  nearby H2 plain endpoints.
- Primary metric: `h2_plain_echo_1x16_eta_node_p99_ratio`
- Direction: lower
- Benchmark facade:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-echo-1x16-p99-vs-node-20260615`
- Session directory: `.hill-climbing/h2-plain-echo-1x16-p99-vs-node-20260615/`

## Why This Hill

The post-H1 broad rerank
`http-testsuite/results/autonomous-server-load-20260615-post-h1-readall-direct/server_load.json`
showed H2 plain `echo_1k` 1x16 as the clearest reference-relative p99 gap that
was not already marked as the H2 16x1 scheduling-sensitive shape:

- Eta/Node RPS ratio: about `1.027x`.
- Eta/Node p99 ratio: about `1.406x`.
- Eta p99: `878.368us`; Node p99: `624.8us`.

The 4x4 H2 plain echo row has higher absolute Eta p99, but Eta beats Node there
on p99 and RPS. This hill therefore targets the one-connection multiplexed
reference-relative gap.

## Anti-Gaming Contract

Improve the real H2 plain echo path only. Do not remove workload, reduce request
bytes, weaken status/body validation, special-case `/echo`, special-case 1 KiB
bodies, detect Node/oha, cache invalidly, skip request-body reads, skip
response-body writes, alter benchmark shape to hide the issue, or trade away
correctness. Production changes require attribution proving the p99 gap lives in
Eta-owned HTTP behavior rather than client/socket/runtime scheduling.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_echo_1x16_eta_node_p99_ratio` | Primary | lower | Keep only if repeated runs improve this beyond noise and guardrails hold. | Median Eta echo p99 divided by median Node echo p99, H2C, 1 connection x 16 streams. |
| `h2_plain_echo_1x16_eta_p99_us` | Diagnostic | lower | Should move with primary. | Absolute Eta p99. |
| `h2_plain_echo_1x16_node_p99_us` | Reference | stable | Large Node swings make the run suspect. | Same Node H2C fixture. |
| `h2_plain_echo_1x16_eta_node_rps_ratio` | Guardrail | stable/higher | Reject p99 wins bought by meaningful throughput loss. | Eta RPS divided by Node RPS. |
| `h2_plain_echo_1x16_success` | Correctness | equals 1 | Required. | All selected rows must return 200, zero errors, success rate 1, and exact response bytes. |
| `h2_plain_non_echo_1x16_eta_node_p99_ratio_geomean` | Guardrail | stable/lower | Non-echo endpoints should not collapse. | Root, user, post, static. |
| `h2_plain_echo_1x16_eta_p999_us` | Diagnostic | lower | Detects p99 wins that push outliers higher. | Eta p99.9. |

## Hypothesis Space

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Echo body/read path owns p99 | Request body read, final EOF handling, or echo response construction delays p99 under multiplexing. | Echo is worse than static/post, and server body/read spans explain the gap. | Static has similar p99, or server body spans are micro-scale. | open |
| H2 | H2 one-connection stream scheduling owns p99 | A single owner/writer loop with 16 active streams batches or schedules DATA/response work less efficiently than Node. | Server phase traces show response-start/write scheduling spans inside Eta. | Queue/write spans stay small while client p99 remains high. | open |
| H3 | Client/socket/runtime timing owns p99 | oha/client demux, socket readiness, Eio backend, or kernel scheduling dominates the missing time. | Custom client or pinning/backend changes move p99 more than production HTTP changes. | Independent traces place p99 inside Eta-owned spans. | open |
| H4 | Broad comparison was noisy | The 1x16 Eta/Node p99 gap does not reproduce under 24k x9. | Focused baseline is unstable or near parity. | Focused baseline repeats the gap. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it. | A better split replaces it. | open |

## Experiment Selection Rule

- Prefer experiments where live hypotheses predict different observations.
- Prefer cheap falsifiers before production edits.
- Prefer instrumentation when current hypotheses are indistinguishable.
- Reject or narrow hypotheses when their falsifiers fire.
- Keep changes only when they improve the hill and preserve checks.

## Running Log

Append completed entries below. Keep entries concise, falsifiable, and useful to
a fresh agent.

### E1 - Focused Eta/Node baseline reproduces the hill

Command:

`python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-echo-1x16-p99-vs-node-20260615`

Result: pass at `2026-06-15T16:55:06Z`.

Key metrics:

- Primary `h2_plain_echo_1x16_eta_node_p99_ratio`: `1.58725961`
- Eta echo p99: `1541.364us`; Node echo p99: `971.085us`
- Eta/Node echo RPS ratio: `0.954833389`
- Eta echo RPS: `78280.5423`; Node echo RPS: `81983.4572`
- Eta echo p99.9: `2897.486us`
- Non-echo p99 geomean ratio: `0.711617074`
- Non-echo RPS geomean ratio: `2.1295286`
- Success: `1`

Interpretation: H4 is rejected for now. The focused 24k x9 run reproduces a
strong 1x16 echo-specific p99 gap against Node while non-echo H2 plain endpoints
remain faster than Node on both p99 and RPS. Next step is attribution, not a
production edit.

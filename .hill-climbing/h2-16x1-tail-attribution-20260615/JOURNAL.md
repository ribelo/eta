# Research Journal: h2-16x1-tail-attribution-20260615

## Hill

- Goal: attribute and then reduce the H2 `connections=16`,
  `streams_per_connection=1` tail-latency gap without regressing the now-improved
  H2 4x4 path.
- Primary metric: `h2_16x1_eta_ref_p99_ratio_geomean`
- Direction: lower
- Benchmark facade:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-tail-attribution-20260615`
- Session directory: `.hill-climbing/h2-16x1-tail-attribution-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_16x1_eta_ref_p99_ratio_geomean` | Primary | lower | Keep only changes that improve this while guardrails hold and attribution still matches the real hill. | Fixed geomean over H2 TLS 16x1 root/user/post/static/echo vs Go plus H2 plain 16x1 echo vs Node. |
| `h2_16x1_tls_eta_go_p99_ratio_geomean` | Diagnostic | lower | Use to separate the remaining TLS hill from the plain echo row. | Fixed geomean over H2 TLS 16x1 root/user/post/static/echo vs Go. |
| `h2_16x1_eta_ref_rps_ratio_geomean` | Guardrail | stable/higher | Reject p99 wins bought by clear throughput loss. | Same fixed case set as primary. |
| `h2_16x1_tls_eta_go_rps_ratio_geomean` | Guardrail | stable/higher | Reject TLS p99 wins bought by clear TLS throughput loss. | Same fixed TLS case set as the TLS diagnostic. |
| Per-case `h2_16x1_*_eta_ref_p99_ratio` | Diagnostic | lower | Shows which endpoint/protocol drives the geomean. | Do not tune only one endpoint unless attribution proves it is distinct. |
| `h2_16x1_success` | Correctness | equals 1 | Required. | Selected Eta/reference 16x1 rows must have all repeats and all must pass. Unrelated broad-suite reference failures are recorded in the result file but do not invalidate this hill. |

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
| H1 | Load/client shape artifact | 16 separate H2 connections make oha/client scheduling, connection fanout, or reference process timing dominate p99. | Changing load CPU shape or using a custom client collapses Eta/reference ratios without production code changes. | The gap persists across clients and pinning shapes. | open |
| H2 | Server per-connection scheduling overhead | Eta pays more per active H2 connection than references when 16 independent owner/read/write loops run. | Server phase traces show ingress/owner/write waits spread across connections, while 4x4 remains healthy. | Phase traces show p99 outside server spans or concentrated in client receive/accounting. | open |
| H3 | TLS/flow syscall or kernel off-CPU behavior | H2 TLS 16x1 loses mostly in write/read syscalls or scheduler deschedule gaps. | strace/perf/off-CPU or phase traces show p99 near Eio.Flow/TLS IO, not H2 handlers. | App-level owner spans explain the missing p99 without kernel stalls. | open |
| H4 | Benchmark noise from excluded shape | The suite's excluded 16x1 row is too noisy to optimize. | Higher repeat counts show unstable median/rank, or p99 changes sign between runs. | Repeated focused runs reproduce stable ratios and case ordering. | open |
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

## E1: Corrected Facade Baseline

### Hypothesis Space Split
- Parent question: is the current 16x1 top row a real Eta code hill or a shape/reference artifact?
- Hypothesis under test: the selected 16x1 Eta/reference rows reproduce the gap once unrelated broad-suite reference failures are excluded.
- Rival hypotheses: unrelated nginx/caddy failures were invalidating the hill; H2 plain echo remained the true 16x1 hill.
- Why this split is high value: the old facade counted unrelated H2-only rows as failures, which made attribution runs ambiguous.

### Prediction Before Run
- Expected primary metric movement: valid run with selected failures at zero.
- Expected secondary metric movement: TLS-only diagnostic should show whether plain echo is still a hill.
- Distinguishing observation: H2 plain echo should either remain above Node or fall out of the hill.
- Falsifier: selected rows missing/failing, or plain echo still dominates.

### Attack
- Change or probe: updated `measure.sh` to require only the selected Eta/Go/Node 16x1 rows and to emit TLS-only geomeans.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-tail-attribution-20260615`
- Checks command: hill runner checks plus `bash -n` for the facade.
- Controls held constant: quick H2-only server-load suite, 16x1 selected rows, default pinning.

### Result
- Primary metric: `h2_16x1_eta_ref_p99_ratio_geomean=1.57860551`.
- Secondary metrics:
  - `h2_16x1_tls_eta_go_p99_ratio_geomean=2.24852348`
  - `h2_16x1_tls_eta_go_rps_ratio_geomean=0.912860439`
  - `h2_16x1_plain_echo_1k_eta_ref_p99_ratio=0.269249286`
  - selected failures `0`, success `1`
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T16:33:13Z`; result path `.hill-climbing/h2-16x1-tail-attribution-20260615/results/20260615-183239/server_load.json`.

### Verdict
- Verdict: split-needed.
- Reason: H2 plain echo is not the hill in this run; it beats Node on p99. The remaining measured gap is H2 TLS 16x1 vs Go across endpoints.
- Hypothesis space update: narrow the active question to TLS 16x1/reference comparison, but do not assume handler/body/TLS response emission yet.
- Commit/revert decision: keep facade contract change; no production code change.
- Next experiment: move client CPU placement to test benchmark sensitivity.

## E2: Wider Load-Core Reference Comparison

### Hypothesis Space Split
- Parent question: does the H2 TLS 16x1 Eta/Go p99 gap collapse when the load side has more CPU?
- Hypothesis under test: the gap is mostly client/load-core pressure.
- Rival hypotheses: Go benefits more than Eta from this shape, or server-side write/readiness scheduling still dominates.
- Why this split is high value: previous custom-client work showed post-write receive delay can move with client placement.

### Prediction Before Run
- Expected primary metric movement: lower if load-core pressure owns the observed gap.
- Expected secondary metric movement: TLS p99 geomean should drop without selected failures.
- Distinguishing observation: Eta p99 ratios improve materially under `ETA_SERVER_LOAD_LOAD_CORE=3-6`.
- Falsifier: ratios stay flat or worsen while selected rows still pass.

### Attack
- Change or probe: no code change; reran the corrected facade with wider load pinning.
- Benchmark command: `ETA_SERVER_LOAD_LOAD_CORE=3-6 python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-16x1-tail-attribution-20260615`
- Checks command: hill runner checks.
- Controls held constant: same selected rows, references, request floor, and server implementation.

### Result
- Primary metric: `h2_16x1_eta_ref_p99_ratio_geomean=2.13078569`.
- Secondary metrics:
  - `h2_16x1_tls_eta_go_p99_ratio_geomean=2.68527538`
  - `h2_16x1_tls_eta_go_rps_ratio_geomean=0.807874204`
  - `h2_16x1_eta_p99_us_max=1982.868`
  - selected failures `0`, success `1`
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T16:34:19Z`; result path `.hill-climbing/h2-16x1-tail-attribution-20260615/results/20260615-183348/server_load.json`.

### Verdict
- Verdict: rejected for a simple load-core fix.
- Reason: widening the load side did not collapse the selected reference comparison; ratios worsened because Go/reference rows improved more than Eta in several cases.
- Hypothesis space update: client placement matters, but the reference comparison is not reducible to one load-core bottleneck.
- Commit/revert decision: no production change.
- Next experiment: use the existing custom H2 client and server phase trace to locate the missing time under current code.

## E3: Custom Client Phase Split

### Hypothesis Space Split
- Parent question: where does the missing 16x1 latency live under current code?
- Hypothesis under test: handler/body/header generation is not the owner; the missing time is around socket readiness/scheduler delivery before server ingress and after server flow completion.
- Rival hypotheses: TLS tiny-response write overhead, H2 header/frame emission, or handler scheduling owns p99.
- Why this split is high value: the custom client records request-write and response-receive checkpoints, while server phase trace joins by local port and stream id.

### Prediction Before Run
- Expected primary metric movement: diagnostic only.
- Expected secondary metric movement: TLS and plain should show similar segment ownership if this is not TLS-specific.
- Distinguishing observation: `accepted -> response_start` stays microsecond-scale while `t1 -> ingress_returned` and `flow_complete -> rx_headers` own p99.
- Falsifier: server accepted-to-response-start or response-start-to-flow-complete explains most of client p99.

### Attack
- Change or probe: reused `.hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`.
- Benchmark commands:
  - `bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `ETA_H2_16X1_TRACE_MODE=plain bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `ETA_SERVER_LOAD_LOAD_CORE=3-6 bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
  - `EIO_BACKEND=posix bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_custom_client_16x1.sh`
- Checks command: custom clients reported `success=1`.
- Controls held constant: root endpoint, 24k requests, 16 connections, 1 stream per connection.

### Result
- TLS default, path `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-183449`:
  - total p99 `2746us`
  - `accepted_to_response_start_p99=3us`
  - `response_start_to_flow_complete_p99=151us`
  - `t1_to_ingress_returned_p99=882us`
  - `flow_complete_to_rx_headers_p99=1680us`
  - slow writes over `500us`: `19/24000`
- Plain default, path `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-183500`:
  - total p99 `2746us`
  - `accepted_to_response_start_p99=3us`
  - `response_start_to_flow_complete_p99=340us`
  - `t1_to_ingress_returned_p99=1031us`
  - `flow_complete_to_rx_headers_p99=1643us`
  - slow writes over `500us`: `105/24000`
- TLS with `ETA_SERVER_LOAD_LOAD_CORE=3-6`, path `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-183509`:
  - total p99 `2130us`
  - `flow_complete_to_rx_headers_p99=29us`
  - `response_start_to_flow_complete_p99=1491us`
  - slow writes over `500us`: `449/24000`
- TLS with `EIO_BACKEND=posix`, path `.hill-climbing/h2-16x1-p99-attribution-20260615/custom-client-results/20260615-183517`:
  - total p99 `2702us`
  - `response_start_to_flow_complete_p99=113us`
  - `flow_complete_to_rx_headers_p99=1487us`
  - slow writes over `500us`: `15/24000`

### Verdict
- Verdict: corroborated for scheduler/readiness ownership; rejected for handler/body/header/TLS tiny-response ownership.
- Reason: the server handler path is microsecond-scale at p99 in both TLS and plain H2. The largest normal owners are before server ingress sees the request and after server flow completion before the client observes headers. Moving client placement collapses post-write receive delay but shifts tail into flow completion, which is scheduler/socket-readiness behavior rather than endpoint code.
- Hypothesis space update: H2 16x1 is a noisy shape-sensitive diagnostic, not the next production code hill. Keep it as a benchmark caveat unless a later off-CPU investigation reveals a specific fix with broad guardrail wins.
- Commit/revert decision: no production optimization from this hill.
- Next experiment: rerank toward a code-owned hill; current candidate is H1 plain `echo_1k` throughput vs Go.

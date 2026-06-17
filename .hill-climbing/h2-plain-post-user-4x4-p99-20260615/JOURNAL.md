# Research Journal: h2-plain-post-user-4x4-p99-20260615

## Hill

- Goal: reduce Eta H2 plain `post_user` p99 versus Node h2c under
  `connections=4`, `streams=4` without breaking H2 throughput, body endpoints,
  or correctness.
- Primary metric: `h2_plain_post_user_4x4_eta_node_p99_ratio`
- Direction: lower
- Benchmark facade:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-post-user-4x4-p99-20260615`
- Session directory: `.hill-climbing/h2-plain-post-user-4x4-p99-20260615/`

## Anti-Gaming Contract

The goal is to improve the real H2 plain post path, not merely this script. Do
not remove workload, reduce requests, weaken status/body validation, special-case
`/user`, special-case empty POSTs, detect Node or oha, cache invalidly, skip
request-body handling, skip response writes, or trade away correctness.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_post_user_4x4_eta_node_p99_ratio` | Primary | lower | Keep only if movement is outside repeat noise and guardrails hold. | Eta median p99 divided by Node median p99 for H2C `POST /user`, `conn=4`, `streams=4`. |
| `h2_plain_post_user_4x4_eta_p99_us` | Diagnostic | lower | Should move with the primary. | Absolute Eta p99. |
| `h2_plain_post_user_4x4_eta_node_rps_ratio` | Guardrail | higher/stable | Reject p99 wins bought by clear RPS loss. | Eta median RPS divided by Node median RPS. |
| `h2_plain_nonpost_4x4_eta_node_p99_ratio_geomean` | Guardrail | stable/lower | Root/user/static/echo should not collapse. | Detects broad H2 regressions. |
| `h2_plain_post_user_4x4_success` | Correctness | equals 1 | Required. | All rows must return 200, zero errors, and exact expected response bytes. |

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
| H1 | Empty POST H2 request path overhead | Eta pays unnecessary body/trailer/reuse work even when `Content-Length: 0`. | `post_user` is much worse than root/user while handler and write spans are tiny. | Phase trace shows delay outside empty-body path or root has same shape. | open |
| H2 | H2 response scheduling/write wakeup | Empty post responses contend with H2 writer scheduling under 4x4. | Server phase trace shows high response-start -> write-complete or writer wait p99. | Writer spans are small compared with client p99. | open |
| H3 | Client/reference artifact | oha or Node comparison creates the apparent gap. | Custom client or higher-repeat focused bench collapses the ratio. | Focused repeats and/or custom client reproduce the gap. | open |
| H4 | Broad quick run noise | The 3-repeat broad run overstated the gap. | 24k x 9 focused baseline collapses near Node p99. | Focused baseline reproduces stable high ratio. | open |
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

## E1: Focused Baseline Reproduces Broad H2 4x4 Gap

### Hypothesis Space Split
- Parent question: Is the broad `H2 plain post_user 4x4` p99 hill real enough to
  optimize?
- Hypothesis under test: H4, broad quick run noise.
- Rival hypotheses: H1 empty POST overhead, H2 H2 scheduling/write wakeup, H3
  client/reference artifact.
- Why this split is high value: a 24k x 9 focused run either rejects the hill or
  gives a stable target.

### Prediction Before Run
- Expected primary metric movement: if broad noise, Eta/Node p99 ratio should
  collapse near 1.
- Expected secondary metric movement: non-post endpoints should not all show the
  same p99 pattern.
- Distinguishing observation: focused medians reproduce `post_user` p99 worse
  than Node.
- Falsifier: focused primary near parity with stable repeats.

### Attack
- Change or probe: created `.hill-climbing/h2-plain-post-user-4x4-p99-20260615`
  with Eta vs Node H2C 4x4 root/user/post/static/echo.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-post-user-4x4-p99-20260615`
- Checks command: included in hill runner via `checks.sh`.
- Controls held constant: 24k requests, 9 repeats, 4 connections, 4 streams,
  status/body validation.

### Result
- Primary metric: `2.61997357`.
- Secondary metrics: Eta post p99 `578.836us`, Node post p99 `220.932us`, Eta
  post RPS `136,957`, Node post RPS `147,785`.
- Checks: passed.
- `log.jsonl` reference: `2026-06-15T15:47:43Z`.

### Verdict
- Verdict: rejected H4.
- Reason: focused run reproduced a stable reference gap.
- Hypothesis space update: the broad result was not just a one-off. The gap is
  broader than `post_user`: root/user/static/echo p99 ratios were also elevated.
- Commit/revert decision: keep hill setup and instrumentation.
- Next experiment: phase split server handler/body/write versus ingress/owner
  timing.

## E2: Phase And Client Attribution Reject Handler/Body Path

### Hypothesis Space Split
- Parent question: Where does the p99 live inside the H2 request/response path?
- Hypothesis under test: H1 empty POST/body path overhead.
- Rival hypotheses: H2 response scheduling/write wakeup, H3 client/reference
  artifact, H_other owner/read cadence.
- Why this split is high value: handler/body optimization is only justified if
  the slow segment lands there.

### Prediction Before Run
- Expected primary metric movement: none; instrumentation only.
- Expected secondary metric movement: if H1 is true, `post_user` should have a
  distinct body/handler signature from root/static.
- Distinguishing observation: handler/body spans dominate p99 or are unique to
  `post_user`.
- Falsifier: traces show handler/body near zero and same shape across endpoints.

### Attack
- Change or probe: added `trace_h2_4x4_phase.sh`; ran post/root/static phase
  traces and a custom H2 client against `POST /user`.
- Benchmark command:
  `bash .hill-climbing/h2-plain-post-user-4x4-p99-20260615/trace_h2_4x4_phase.sh`
  plus custom-client attribution through the existing H2 gap client.
- Checks command: syntax/build checks in `checks.sh`.
- Controls held constant: 4 connections, 4 streams, H2C, pinned server/load.

### Result
- Primary metric: not a benchmark run.
- Secondary metrics: post phase trace had client p99 `512.549us`,
  accepted-to-complete p99 `341us`, ingress-read p99 `314us`,
  write-job-wait p99 `26us`; root/static had the same ingress/flow-write shape.
  Custom client reproduced the tail with total p99 `1339us`, `t1->t2` p99
  `1332us`, `t1->accepted` p99 `644us`, and `t2->t3` p99 `1us`.
- Checks: trace script syntax checked; benchmark correctness success was `1`.
- `log.jsonl` reference: side probes under `results/phase-*` and
  `.hill-climbing/h2-echo-4x4-actionable-20260615/custom-client-results/`.

### Verdict
- Verdict: rejected H1 and narrowed H3.
- Reason: handler/body/copy path was not the p99 segment; oha was not the whole
  story because the custom client reproduced the tail.
- Hypothesis space update: live hypothesis shifted to owner/read/write cadence
  and batching, not endpoint code.
- Commit/revert decision: keep trace harnesses; no production optimization from
  this step.
- Next experiment: attack H2 owner command batching.

## E3: Owner Batch Sweep

### Hypothesis Space Split
- Parent question: Does owner command batching explain the H2 4x4 p99 tail?
- Hypothesis under test: H2/H_other, owner loop drains too few ready commands per
  wait/flush cycle.
- Rival hypotheses: kernel/client noise, h2 library scheduling, unrelated
  measurement variance.
- Why this split is high value: one scoped constant controls owner batching
  without special-casing endpoints.

### Prediction Before Run
- Expected primary metric movement: increasing the batch budget should reduce
  tiny dynamic response p99/RPS overhead; too high a value may starve body/echo
  or other stream shapes.
- Expected secondary metric movement: 4x4 root/user/post should improve together
  if this is a generic owner-cadence issue.
- Distinguishing observation: small-batch regresses, larger batch improves
  focused 4x4 metrics.
- Falsifier: no movement or wins only by harming guardrails.

### Attack
- Change or probe: tested `h2_owner_command_batch_budget` values `1`, `16`,
  `32`, and `64`.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-plain-post-user-4x4-p99-20260615`
- Checks command: included in hill runner via `checks.sh`.
- Controls held constant: benchmark facade unchanged.

### Result
- Primary metric: budget `1` regressed to `3.9506483`; budget `16` improved to
  `1.34373444` then `0.860132441`; budget `32` measured `1.11756944`; budget
  `64` measured `0.689687343`, then noisier `1.72856453` / `1.14444347`.
- Secondary metrics: focused absolute Eta post p99 improved from baseline
  `578.836us` to `231-300us` for large batches, and RPS improved from
  `136,957` to roughly `175k-182k`.
- Checks: passed for each run.
- `log.jsonl` reference: `2026-06-15T15:56:19Z` through
  `2026-06-15T16:18:31Z`.

### Verdict
- Verdict: split-needed.
- Reason: larger owner batches clearly help focused tiny dynamic 4x4 work, but
  broad guardrails decide the safe constant.
- Hypothesis space update: owner batching is a real lever, but excessive batching
  can harm other H2 shapes.
- Commit/revert decision: reject budget `1`; provisional-test budgets `16/32/64`.
- Next experiment: broad guardrail comparison.

## E4: Broad Guardrail Chooses Batch 8

### Hypothesis Space Split
- Parent question: Which owner batch budget improves the real hill without
  moving the next hill elsewhere?
- Hypothesis under test: modestly larger owner batching is the right production
  fix.
- Rival hypotheses: focused win overfits 4x4 `post_user`, or large batches harm
  echo/body/1x16 shapes.
- Why this split is high value: broad H2 rows include the guardrails the focused
  hill cannot see.

### Prediction Before Run
- Expected primary metric movement: H2 plain 4x4 `post_user` p99 lower than
  baseline.
- Expected secondary metric movement: H2 plain 4x4 echo/static and H2 TLS 4x4
  should not regress; 1x16 should not become the new top noisy case.
- Distinguishing observation: a batch value improves 4x4 post while keeping
  echo/body and 1x16 within baseline noise or better.
- Falsifier: broad suite shows a new large p99/RPS regression.

### Attack
- Change or probe: broad quick guardrails for batch `64`, batch `16`, then batch
  `8`.
- Benchmark command:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --references --out ...`
  and
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --references --h2-only --out ...`
- Checks command: current batch `8` already passed hill runner `checks.sh`.
- Controls held constant: broad suite request counts/repeats and references.

### Result
- Primary metric: batch `8` H2 plain 4x4 `post_user` p99 improved
  `636.657us -> 496.889us`; RPS improved `119,118 -> 128,779`.
- Secondary metrics: batch `8` H2 plain 4x4 root `588.133us -> 401.036us`,
  user `554.650us -> 421.615us`, static `641.085us -> 559.578us`, echo
  `980.013us -> 809.105us`. H2 TLS 4x4 also improved on all endpoints in the
  H2-only broad run. Batch `64` was rejected because H2 plain 4x4 echo p99
  jumped to `5100.966us` and RPS dropped. Batch `16` was rejected because H2
  plain 1x16 `user_id` became the top actionable noisy case.
- Checks: focused hill checks passed for batch `8`; H2-only broad had `0/348`
  failures.
- `log.jsonl` reference: batch `8` focused run `2026-06-15T16:23:18Z`; broad
  result
  `http-testsuite/results/autonomous-server-load-20260615-h2-owner-batch8-h2quick/server_load.json`.

### Verdict
- Verdict: corroborated.
- Reason: batch `8` improves the original 4x4 hill and strengthens most H2
  guardrails without creating the batch `64` echo regression or batch `16`
  1x16 spike.
- Hypothesis space update: H2 owner loop batching/cadence was a real part of the
  hill. Remaining top cases are body/echo and residual noisy 1x16/H2 TLS tails,
  not `post_user`-specific.
- Commit/revert decision: keep `h2_owner_command_batch_budget = 8`.
- Next experiment: rerank after batch `8`; next hill is likely H2 TLS/echo p99,
  not H2 plain `post_user`.

# Research Journal: jittery-cerulean-comet

## Hill

- Goal: reduce H2 plain `echo_1k` p99 under one connection with 16 concurrent
  streams, after first isolating the noisy broad-suite signal.
- Primary metric: `h2_plain_echo_1k_p99_ms`.
- Direction: lower.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id jittery-cerulean-comet`
- Session directory: `.hill-climbing/jittery-cerulean-comet/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_echo_1k_p99_ms` | Primary | lower | Keep changes that improve beyond baseline/noise and pass checks. | Median p99 over 7 repeated `n=20000,c=1,p=16` runs. |
| `h2_plain_echo_1k_p99_mad_ms` | Noise | lower | High spread makes a p99 win inconclusive unless repeated. | Captures median absolute deviation of p99 repeats. |
| `h2_plain_{root,post_user,static_1k}_p99_ms` | Secondary | lower | Used to classify whether a win is echo-specific or shared H2 overhead. | Same c/p/n/reps shape. |
| `h2_plain_*_p50_ms`, `h2_plain_*_p95_ms` | Secondary | lower | Large regression rejects a p99-only apparent win. | Keeps steady-state path honest. |
| `h2_plain_*_rps`, `h2_plain_rps_geomean` | Guard | higher | Major throughput regression rejects the change unless explained by a decisive p99 win. | Prevents serializing work to hide tail latency. |
| `success` | Guard | higher | Must be `1`. | All oha runs must be 200-only with no errors. |

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
| H1 | Broad H2 plain echo p99 was mostly benchmark noise. | The `1.096,5.229,3.671 ms` repeats came from scheduler/load noise rather than a stable Eta path. | Targeted median-of-7 p99 is much lower and/or p99 MAD is large enough to reject optimization. | Targeted baseline remains consistently multi-ms with low MAD. | open |
| H2 | Echo request-body path is the bottleneck. | Reading the 1 KiB upload and writing it back under 16 streams creates extra buffering, copies, or scheduling delays. | `echo_1k` p99 is much worse than `post_user` and `static_1k`; optimizing body read/write lowers echo more than secondaries. | `echo_1k` tracks root/post/static or is not consistently worse. | open |
| H3 | Shared H2 scheduler/framing path is the bottleneck. | Stream scheduling, frame parsing/writing, HPACK, or flow-control bookkeeping creates tail latency under 16 streams. | Root/post/static/echo p99s move together under changes to H2 multiplexer/writer code. | Only echo improves/regresses materially. | open |
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

## E0: Targeted Baseline

### Hypothesis Space Split
- Parent question: is H2 plain `echo_1k` p99 a stable hill or broad-suite noise?
- Hypothesis under test: H1, broad-suite noise.
- Rival hypotheses: H2 echo body path; H3 shared H2 scheduler/framing path.
- Why this split is high value: the broad repeats were noisy
  (`1.096, 5.229, 3.671 ms`), so optimization should not start until a stable
  targeted signal exists.

### Prediction Before Run
- Expected primary metric movement: no movement; baseline only.
- Expected secondary metric movement: if echo is the real hill, it should be
  clearly worse than root/post/static under the same `c=1,p=16,n=20000` shape.
- Distinguishing observation: low p99 MAD and echo p99 much higher than
  secondaries.
- Falsifier: echo p99 collapses near the secondary endpoints, or p99 MAD is so
  high that the metric is not actionable.

### Attack
- Change or probe: created fixed H2C probe workload with echo primary and
  root/post/static secondaries.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id jittery-cerulean-comet`
- Checks command: `.hill-climbing/jittery-cerulean-comet/checks.sh`
- Controls held constant: release build, Eio posix backend, one H2C
  connection, 16 streams, `n=20000`, median of 7 repeats, fixed endpoint order.

### Result
- Primary metric: `h2_plain_echo_1k_p99_ms=2.217562`.
- Noise: echo p99 min `2.043258`, max `2.353020`, MAD `0.072429`.
- Secondary metrics: root p99 `0.168822`, post_user p99 `0.194893`,
  static_1k p99 `0.230441`; `h2_plain_rps_geomean=138209`; `success=1`.
- Checks: pass.
- `log.jsonl` reference: run at `2026-06-15T00:36:47Z`.

### Verdict
- Verdict: H1 rejected; H2 corroborated.
- Reason: targeted echo p99 is stable enough and about 10x the secondary H2
  plain endpoints, so this is not just broad-suite noise.
- Hypothesis space update: start optimization with the echo request-body /
  response write path, while watching shared H2 metrics as guards.
- Commit/revert decision: keep hill scaffolding.
- Next experiment: inspect H2 server request body and response writer path for
  echo-specific buffering, copies, or scheduling.

## E1: Allocation Profile And Authority Validation

### Hypothesis Space Split
- Parent question: why is `echo_1k` much worse than H2 plain endpoints without
  upload bodies?
- Hypothesis under test: H2/H3 allocation pressure in common per-request
  validation contributes to the tail.
- Rival hypotheses: request-body owner scheduling or flow-control writes are the
  dominant cost.
- Why this split is high value: a short `perf` sample showed GC/allocation,
  `Server_body.read_all`, and URL/authority parsing in the hot path.

### Prediction Before Run
- Expected primary metric movement: modest p99 and RPS improvement.
- Expected secondary metric movement: shared H2 endpoints improve or hold.
- Distinguishing observation: root/post/static move with echo if this is shared
  validation overhead.
- Falsifier: no p99/RPS movement or secondary regressions.

### Attack
- Change or probe: replaced H2 common `:authority` validation with
  `valid_authority`, and changed `parse_authority` to build the authority record
  directly instead of constructing `scheme://authority` and calling `Url.parse`.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id jittery-cerulean-comet`
- Checks command: `.hill-climbing/jittery-cerulean-comet/checks.sh`
- Controls held constant: same `c=1,p=16,n=20000`, 7 repeats, pinned cores.

### Result
- Primary metric: `2.088 ms`, then `2.173 ms` on confirmation.
- Secondary metrics: RPS geomean improved to `145777` then `146271`; root and
  post_user p99 stayed sub-ms.
- Checks: pass.
- `log.jsonl` reference: runs at `2026-06-15T00:48:33Z` and
  `2026-06-15T00:48:55Z`.

### Verdict
- Verdict: corroborated but not sufficient.
- Reason: the change is a repeatable small win, mostly shared allocation
  reduction, while echo remains far above secondaries.
- Hypothesis space update: keep H3 allocation pressure as contributing; H2
  request-body ingress still dominates.
- Commit/revert decision: keep.
- Next experiment: remove upload-body ingress copies.

## E2: Single-Chunk Server Body Read

### Hypothesis Space Split
- Parent question: is `Server.Body.read_all` copying a single 1 KiB chunk a
  meaningful part of the tail?
- Hypothesis under test: H2 echo pays an avoidable second copy at `read_all`
  completion.
- Rival hypotheses: ingress filtering and H2 request-body scheduling dominate.
- Why this split is high value: profile showed `Server_body.read_all`; the
  single-chunk case is common for 1 KiB uploads and is a small semantic-preserving
  edit.

### Prediction Before Run
- Expected primary metric movement: p50/RPS improve; p99 may improve slightly.
- Expected secondary metric movement: only endpoints reading request bodies move.
- Distinguishing observation: echo p50/RPS improves without root/static changes.
- Falsifier: no echo movement or correctness failure.

### Attack
- Change or probe: return the already-owned single chunk from
  `Server.Body.read_all` instead of allocating and copying into a new buffer.
- Benchmark command: hill facade.
- Checks command: hill checks.
- Controls held constant: same hill script and pinned cores.

### Result
- Primary metric: `2.158 ms`.
- Secondary metrics: echo p50 improved to `0.147 ms`; RPS geomean improved to
  `143339`; p99 win was small.
- Checks: pass.
- `log.jsonl` reference: run at `2026-06-15T00:44:20Z`.

### Verdict
- Verdict: corroborated for allocation/RPS, weak for p99.
- Reason: it reduces real work and keeps semantics, but does not explain the
  tail alone.
- Hypothesis space update: body accumulation contributes; ingress remains live.
- Commit/revert decision: keep.
- Next experiment: test body EOF and ingress paths.

## E3: Rejected Echo-Path Experiments

### Hypothesis Space Split
- Parent question: is the tail caused by one extra EOF owner-command or by
  benchmark-fixture response copies?
- Hypothesis under test: removing those echo-specific costs should lower p99.
- Rival hypotheses: upload ingress filtering dominates.
- Why this split is high value: both changes were cheap falsifiers.

### Prediction Before Run
- Expected primary metric movement: echo p99 improves materially.
- Expected secondary metric movement: little movement for root/static.
- Distinguishing observation: echo improves without shared endpoint movement.
- Falsifier: p99 regresses or noise widens.

### Attack
- Change or probe: tried internal final-DATA EOF caching in
  `H2_server_connection`; separately tried returning fixed bytes directly from
  the testsuite echo handler.
- Benchmark command: hill facade.
- Checks command: hill checks.
- Controls held constant: same hill script and pinned cores.

### Result
- EOF fast path primary metric: `2.344 ms`, MAD `0.170 ms`.
- Echo fixture copy primary metric: `2.208 ms`, MAD `0.137 ms`.
- Checks: pass.
- `log.jsonl` reference: runs at `2026-06-15T00:45:54Z` and
  `2026-06-15T00:47:15Z`.

### Verdict
- Verdict: rejected.
- Reason: both widened noise and failed to improve p99.
- Hypothesis space update: H2 upload ingress, not echo response copying or EOF
  command count alone, is the better explanation.
- Commit/revert decision: reverted both.
- Next experiment: optimize ingress filtering without weakening validation.

## E4: H2 Ingress Pass-Through

### Hypothesis Space Split
- Parent question: does `filter_ingress` copying validated-but-unchanged H2
  frames cause the upload-body tail?
- Hypothesis under test: H2 upload bodies are dominated by redundant ingress
  copies in the security/filter layer.
- Rival hypotheses: owner scheduling or h2 flow-control writes dominate.
- Why this split is high value: manual isolation showed `/user` with a 1 KiB
  POST body has the same multi-ms p99 as `/echo`, and profile samples included
  `filter_ingress` copying.

### Prediction Before Run
- Expected primary metric movement: echo p99 improves materially.
- Expected secondary metric movement: root/static may improve slightly; no
  correctness regressions.
- Distinguishing observation: upload p99 drops and RPS rises while all checks
  pass.
- Falsifier: primary remains near baseline or protocol/security tests fail.

### Attack
- Change or probe: made the filter output buffer lazy for unchanged chunks, then
  added a direct bigstring scan for complete unchanged non-HEADERS frames. The
  direct path falls back for preface/pending data, HEADERS/CONTINUATION,
  graceful-rejection state, partial frames, or any frame requiring modification.
- Benchmark command: hill facade.
- Checks command: hill checks.
- Controls held constant: same hill script and pinned cores.

### Result
- Lazy pass-through primary metric: `1.850887 ms`, confirmed `1.858071 ms`.
- Direct bigstring pass-through primary metric: `1.773410 ms`, confirmed
  `1.805620 ms`.
- Final echo p50/p95 in confirmation: `0.143 ms` / `0.351 ms`.
- Final RPS geomean: `146566`; `success=1`.
- Checks: pass.
- `log.jsonl` reference: accepted runs at `2026-06-15T00:52:41Z`,
  `2026-06-15T00:52:51Z`, `2026-06-15T00:54:40Z`, and
  `2026-06-15T00:54:51Z`.

### Verdict
- Verdict: corroborated.
- Reason: p99 moved from the `2.217562 ms` baseline to a confirmed
  `1.805620 ms` while checks passed, with p95 and throughput also better.
- Hypothesis space update: H2 ingress copying is a confirmed contributor; the
  remaining tail is likely owner scheduling, flow-control/write ordering, or
  residual h2 body reader overhead.
- Commit/revert decision: keep.
- Next experiment: profile the post-ingress state before attacking scheduling.

# Research Journal: h1-plain-echo-1k-throughput-20260615

## Hill

- Goal: improve Eta H1 plain `echo_1k` throughput versus Go under `c=16`
  without weakening correctness or trading away tail latency.
- Primary metric: `h1_plain_echo_1k_eta_go_rps_ratio`
- Direction: higher
- Benchmark facade:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-1k-throughput-20260615`
- Session directory: `.hill-climbing/h1-plain-echo-1k-throughput-20260615/`

## Anti-Gaming Contract

The goal is to improve the real H1 plain echo throughput path, not merely to
improve this script. Do not remove workload, reduce request bytes, weaken status
or body validation, special-case `/echo`, special-case a 1 KiB body, detect Go
or oha, cache invalidly, skip request-body reads, skip response-body writes, or
trade away correctness. Improvements must preserve ordinary H1 request-body
handling and focused HTTP tests.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h1_plain_echo_1k_eta_go_rps_ratio` | Primary | higher | Keep only if the movement is outside repeat noise and guardrails hold. | Median Eta echo RPS divided by median Go echo RPS, H1 plain, `POST /echo`, 1 KiB body, `c=16`. |
| `h1_plain_echo_1k_eta_rps` | Diagnostic | higher | Should move with the primary. | Absolute Eta throughput. |
| `h1_plain_echo_1k_go_rps` | Reference | stable | Large reference swings make the run suspect. | Same Go server shape. |
| `h1_plain_echo_1k_eta_p99_us` | Guardrail | non-regression | Reject clear p99 regressions unless the throughput win is large and explained. | p99 was roughly tied in the broad run. |
| `h1_plain_echo_1k_eta_go_p99_ratio` | Guardrail | non-regression | Do not buy RPS by losing tail latency. | Eta p99 divided by Go p99. |
| `h1_plain_non_echo_eta_go_rps_ratio_geomean` | Guardrail | non-regression | Non-echo endpoints should not collapse. | Root, user, post, static diagnostics. |
| `h1_plain_echo_1k_success` | Correctness | equals 1 | Required. | All rows must return 200, zero errors, and exact expected response bytes. |

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
| H1 | Handler/body copy dominates | The test echo handler reads all bytes, converts `Bytes` to `string`, then response emission copies again. | Copy/allocation probes are high for echo but not static, and reducing real copies improves RPS without p99 loss. | Copy reduction does not move RPS or static shows the same gap. | open |
| H2 | H1 request body parser/backpressure dominates | Reading a fixed 1 KiB POST body through the H1 server path costs more than Go's body read. | `post_user` or read-only echo probes show similar throughput gap; handler copy is small. | Request-body read spans are small and `post_user` is not behind. | open |
| H3 | H1 response write path dominates | Echo creates a 1 KiB response that is slower to frame/write than Go's response writer. | `static_1k` shows a similar Eta/Go gap, and response-write spans dominate. | Static is competitive and write spans are small. | open |
| H4 | Broad quick run was noisy | The 0.70x RPS came from low request count or reference noise. | A 24k x 9 focused baseline collapses toward parity. | Focused baseline reproduces a stable gap. | open |
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

## E1: Focused Baseline and Phase Split

### Hypothesis Space Split
- Parent question: is the H1 plain `echo_1k` Go gap real, and where does it
  live?
- Hypothesis under test: the broad quick-run `0.70x` echo RPS ratio is a real
  Eta-owned request-body/echo path hill.
- Rival hypotheses: low-count noise, generic response-write weakness, or
  handler-level copy overhead.
- Why this split is high value: `static_1k` separates response-body write from
  request-body echo, and the H1 phase trace separates head read, handler, and
  write spans.

### Prediction Before Run
- Expected primary metric movement: no code change.
- Expected secondary metric movement: focused baseline should reproduce a
  stable Eta/Go echo RPS gap while preserving p99.
- Distinguishing observation: static faster than Go falsifies a generic 1 KiB
  response-write hill; tiny handler spans falsify handler work as the dominant
  direct latency segment.
- Falsifier: focused 24k x 9 baseline collapses near parity.

### Attack
- Change or probe: created fresh hill facade and phase attribution script.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-1k-throughput-20260615`
- Trace commands:
  - `bash .hill-climbing/h1-plain-echo-1k-throughput-20260615/trace_h1_echo_phase.sh`
  - `ETA_H1_ECHO_PHASE_ENDPOINT=static_1k bash .hill-climbing/h1-plain-echo-1k-throughput-20260615/trace_h1_echo_phase.sh`
  - `ETA_H1_ECHO_PHASE_ENDPOINT=post_user ETA_H1_ECHO_PHASE_REQUESTS=4000 bash .hill-climbing/h1-plain-echo-1k-throughput-20260615/trace_h1_echo_phase.sh`
- Checks command: runner `checks.sh`.
- Controls held constant: H1 plain, `c=16`, pinned server/load cores, oha
  validation, exact response byte counts, Go reference shape.

### Result
- Baseline primary:
  - `h1_plain_echo_1k_eta_go_rps_ratio = 0.616682`
  - Eta echo RPS `95404`; Go echo RPS `154706`.
- Guardrails:
  - Eta echo p99 `349.6us`; Go echo p99 `457.1us`; p99 ratio `0.765`.
  - `h1_plain_echo_1k_success = 1`.
  - Static RPS ratio `1.393`; static is not the hill.
- Phase trace, echo:
  - client p50/p99 `163/449us`, RPS `81289`.
  - head p50/p99 `71/299us`.
  - handler p50/p99 `2/5us`.
  - write p50/p99 `92/298us`.
  - accepted-to-complete p50/p99 `96/305us`.
  - full initial body ratio `1.0`.
- Phase controls:
  - static accepted-to-complete p50/p99 `68/211us`; handler p99 `5us`.
  - post accepted-to-complete p50/p99 `63/160us`; handler p99 `3us`.
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T15:28:52Z`.

### Verdict
- Verdict: corroborated and split-needed.
- Reason: the gap is stable and endpoint-shaped. Static being faster than Go
  rejects generic 1 KiB response-write weakness. Handler p99 around `5us`
  rejects high-level echo handler work as the dominant latency segment, but
  copy/allocation overhead can still dominate throughput.
- Hypothesis space update:
  - H4 rejected.
  - H3 rejected as the primary explanation.
  - H1 narrows to allocation/copy overhead in the H1 fixed request-body path,
    not application handler duration.
  - H2 remains live because full echo bodies arrive in the request-head buffer.
- Commit/revert decision: keep hill setup and trace scripts.
- Next experiment: remove unnecessary fixed-body copies/allocations that affect
  ordinary small fixed POST bodies.

## E2: Avoid Second Copy of Fully Buffered Fixed Body

### Hypothesis Space Split
- Parent question: does the fixed request-body path do unnecessary work after
  the full body is already buffered?
- Hypothesis under test: `source_take_pending` copies the already-owned initial
  fixed body into a second chunk, hurting echo throughput.
- Rival hypotheses: the remaining cost is scratch allocation or socket/write
  scheduling, so removing one copy will not move the primary metric.
- Why this split is high value: it is a general H1 fixed-body improvement, not
  `/echo`-specific, and the trace shows `full_initial_body_ratio = 1.0`.

### Prediction Before Run
- Expected primary metric movement: small positive movement.
- Expected secondary metric movement: echo p99 should not regress; static
  should be mostly unchanged.
- Distinguishing observation: Eta echo RPS improves with no correctness change.
- Falsifier: primary remains within baseline noise or p99 regresses.

### Attack
- Change or probe: return `source.initial` directly when the pending body chunk
  consumes the whole initial buffer.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-1k-throughput-20260615`
- Checks command: runner `checks.sh`.
- Controls held constant: same hill harness.

### Result
- Primary moved `0.616682 -> 0.632132`.
- Eta echo RPS moved `95404 -> 96519`.
- Eta echo p99 moved `349.6us -> 346.8us`.
- Success stayed `1`.
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T15:36:22Z`.

### Verdict
- Verdict: corroborated but small.
- Reason: removing the extra pending-body copy helped, but only about `2.5%`
  on the primary ratio.
- Hypothesis space update: copy count matters, but it is not the largest piece.
  Scratch allocation remains the next sharper suspect.
- Commit/revert decision: keep.
- Next experiment: make per-request body scratch allocation lazy.

## E3: Lazy Fixed-Body Scratch Allocation

### Hypothesis Space Split
- Parent question: is H1 fixed-body throughput paying for unused per-request
  body read scratch?
- Hypothesis under test: fixed request bodies allocate a Cstruct scratch buffer
  even when the entire body is already in the request-head buffer; avoiding that
  allocation should materially improve echo throughput.
- Rival hypotheses: remaining gap is mostly request parsing or socket write
  scheduling, so allocation removal will not move RPS much.
- Why this split is high value: the change is general for fixed and chunked
  bodies, preserves behavior, and only allocates when a later flow read is
  actually needed.

### Prediction Before Run
- Expected primary metric movement: meaningful positive movement beyond E2.
- Expected secondary metric movement: p99 should improve or stay stable;
  non-echo diagnostics should not collapse.
- Distinguishing observation: echo RPS jumps while correctness and p99 hold.
- Falsifier: primary remains around `0.63` or guardrails regress.

### Attack
- Change or probe: changed `body_source.scratch` to `Cstruct.t option` and
  allocated it through `source_scratch` only when reading from the flow after
  pending initial bytes are exhausted.
- Harness fix: after one failed verification run from random port collision,
  changed hill scripts to ask the kernel for a free loopback port.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-1k-throughput-20260615`
- Checks command: runner `checks.sh`.
- Controls held constant: same hill harness and validation.

### Result
- First passing run:
  - primary `0.632132 -> 0.818228`.
  - Eta echo RPS `96519 -> 124321`.
  - Eta echo p99 `346.8us -> 172.3us`.
  - success `1`.
- Verification run:
  - primary `0.805623`.
  - Eta echo RPS `124377`; Go echo RPS `154386`.
  - Eta echo p99 `175.4us`; Go echo p99 `445.6us`.
  - success `1`.
- Non-echo diagnostics on verification:
  - non-echo RPS ratio geomean `0.9198`.
  - static RPS ratio `1.391`.
  - post RPS ratio `0.708`.
- Post-change phase trace:
  - accepted-to-complete p50/p99 `76/188us`.
  - head p50/p99 `57/255us`.
  - write p50/p99 `72/180us`.
  - handler p50/p99 `2/5us`.
- Checks: passed; `git diff --check` passed.
- `log.jsonl` references:
  - first passing timestamp `2026-06-15T15:38:05Z`.
  - verification timestamp `2026-06-15T15:39:27Z`.

### Verdict
- Verdict: corroborated.
- Reason: the improvement is large, repeated, and matches the trace mechanism.
  The hill moved from `0.617x` to `~0.81x` Eta/Go RPS, while p99 improved
  substantially and exact-byte correctness held.
- Hypothesis space update:
  - H1/H2 narrow to fixed-body allocation/copy overhead in the initial-buffer
    path. The remaining gap is likely broader H1 request/response overhead
    because post/root are still below Go while static remains ahead.
- Commit/revert decision: keep.
- Next experiment: stop here for this hill unless a future broad run still ranks
  H1 plain echo as top. The next autonomous hill should be selected from the
  updated broad-suite ranking after this fix.

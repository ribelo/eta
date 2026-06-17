# Research Journal: h2-echo-once-collapse-20260615

## Hill

- Goal: validate whether avoiding the second EOF body read reduces H2C `/echo` tail latency.
- Primary metric: `h2_echo_once_body_p99_ratio`
- Direction: lower.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h2-echo-once-collapse-20260615`
- Session directory: `.hill-climbing/h2-echo-once-collapse-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_echo_once_body_p99_ratio` | Primary | lower | Ratio below 1 supports EOF-roundtrip diagnosis | `/echo_once` body p99 divided by normal `/echo` body p99 |
| `h2_echo_once_client_p99_ratio` | Secondary | lower | Ratio below 1 means mechanism reaches client-observed latency | Uses custom H2C client total p99 |
| `h2_echo_eof_returns_per_stream` | Control | n/a | Must be 1 for normal `/echo` | Confirms normal `read_all` path performs EOF read |
| `h2_echo_once_eof_returns_per_stream` | Control | n/a | Must be 0 for `/echo_once` | Confirms probe removed handler EOF read |

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
| H1 | EOF roundtrip is material | Normal `/echo` pays a second body read to observe EOF; `/echo_once` avoids it | `/echo_once` body/client p99 ratios below 1 and EOF returns per stream = 0 | Ratio near 1 despite removing EOF read | corroborated |
| H2 | EOF roundtrip is the whole hill | Removing the second EOF read collapses nearly all body/client p99 | `/echo_once` p99 approaches non-body endpoints | Body/client p99 remain substantial | rejected |
| H3 | First chunk read command/wakeup remains live | Even without EOF read, first read command and handler wake still cost tail latency | `/echo_once` improves but does not collapse p99 | `/echo_once` p99 fully collapses | corroborated |
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

## E1: `/echo_once` Collapse Probe

### Hypothesis Space Split
- Parent question: is the second EOF body read a real cause of H2C `/echo` tail latency?
- Hypothesis under test: H1/H2/H3 above.
- Rival hypotheses: EOF roundtrip is material, EOF roundtrip is the entire hill, or first chunk read command/wakeup remains live.
- Why this split is high value: it changes only testsuite measurement behavior and directly removes the suspected second handler body read from a controlled endpoint.

### Prediction Before Run
- Expected primary metric movement: `/echo_once` body p99 ratio should drop below 1 if EOF roundtrip matters.
- Expected secondary metric movement: client p99 ratio should also drop if this reaches observed latency.
- Distinguishing observation: normal `/echo` has one EOF return per stream; `/echo_once` has zero.
- Falsifier: removing EOF read does not reduce body/client p99.

### Attack
- Change or probe: added measurement-only `/echo_once` testsuite route and optional PATH argument to `h2_gap_client`.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-echo-once-collapse-20260615`
- Checks command: `.hill-climbing/h2-echo-once-collapse-20260615/checks.sh`
- Controls held constant: H2C, 1 connection, 16 streams, 1024-byte response, traced 4k requests x 5 repeats per endpoint.

### Result
- Primary metric: `h2_echo_once_body_p99_ratio=0.753296`
- Secondary metrics:
  - normal `/echo` body p99 `507 us`
  - `/echo_once` body p99 `385 us`
  - normal `/echo` client p99 `1126 us`
  - `/echo_once` client p99 `987 us`
  - client p99 ratio `0.828597`
  - normal EOF returns per stream `1.0`
  - `/echo_once` EOF returns per stream `0.0`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T09:52:12Z`.

### Verdict
- Verdict: corroborated H1 and H3; rejected H2.
- Reason: removing the handler EOF read reduces body p99 by about 25% and client p99 by about 17%, while trace controls prove the EOF read was removed. The tail does not fully collapse, so first chunk read command/wakeup remains a live mechanism.
- Hypothesis space update: production optimization should target a combined final-chunk+EOF fast path and reduce owner/handler roundtrips for already-buffered request bodies.
- Commit/revert decision: keep as measurement-only probe; `/echo_once` is not a production behavior proposal.
- Next experiment: prototype an internal request-body fast path that can return final chunk + EOF to `read_all` without a second owner command, then verify against normal `/echo`.

# Research Journal: h2-body-read-attribution-20260615

## Hill

- Goal: split H2C 1x16 `/echo` request-body availability latency inside `handler_started -> body_available`.
- Primary metric: `h2_body_handler_to_available_p99_us`
- Direction: lower, but this hill is primarily diagnostic.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h2-body-read-attribution-20260615`
- Session directory: `.hill-climbing/h2-body-read-attribution-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_body_handler_to_available_p99_us` | Primary | lower | Tracks the segment identified by the joined hill | Handler start to `Body.read_all` completion |
| `h2_body_first_arm_to_data_p99_us` | Secondary | lower | Positive means handler is waiting for DATA arrival | Negative means DATA arrived before read arm |
| `h2_body_reader_delivery_after_ready_p99_us` | Secondary | lower | Large value means H2 body reader delivery dominates | Computed after both DATA and read arm are ready |
| `h2_body_first_read_call_to_arm_p99_us` | Secondary | lower | Large value means handler-to-owner command wait dominates first chunk read | First `Request_body_read` command |
| `h2_body_second_read_call_to_arm_p99_us` | Secondary | lower | Large value means second EOF read command wait dominates | Second `Request_body_read` command |
| `h2_body_eof_callback_to_return_p99_us` | Secondary | lower | Large value means EOF resolver/handler wake dominates | EOF callback to handler read return |
| `h2_body_tail1pct_*` | Secondary | n/a | Classifies same slow rows instead of independent p99s | Top 1% by handler-to-available |

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
| H1 | Waiting for request DATA | Handler read arms before DATA arrives | `first_arm -> data` positive and dominates tail | DATA arrives before read arm | rejected |
| H2 | H2 body reader delivery/copy | DATA and read are ready, but delivery/copy is slow | `reader_delivery_after_ready` or chunk copy dominates | Both stay tiny | rejected |
| H3 | Owner command queue/wakeup | Handler body read waits for owner loop to arm H2 reader | first/second read call-to-arm dominates | Command wait remains tiny | corroborated |
| H4 | Extra EOF read roundtrip | `read_all` needs a second body read to observe EOF after the final chunk | second read command/EOF return dominates slow rows | EOF roundtrip tiny | corroborated |
| H5 | Handler work after EOF | Body is complete but handler continuation is slow | `eof_return -> body_available` dominates | Segment stays tiny | rejected |
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

## E1: Request Body Read Trace

### Hypothesis Space Split
- Parent question: what accounts for `handler_started -> body_available`?
- Hypothesis under test: H1-H5 above.
- Rival hypotheses: DATA arrival, H2 body reader delivery/copy, owner command wait, EOF roundtrip, handler continuation.
- Why this split is high value: prior joined hill showed body availability is the largest server-side subsegment.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic instrumentation only.
- Expected secondary metric movement: if DATA arrival is the hill, first read arm should precede DATA; if command/wakeup is the hill, read call-to-arm or EOF return should dominate.
- Distinguishing observation: top 1% handler-to-available rows identify the dominant body-read subsegment.
- Falsifier: DATA wait dominates, contradicting the command/wakeup theory.

### Attack
- Change or probe: added env-gated trace lines for DATA frame observation, request body read calls/returns, body reader arm/chunk/eof.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-body-read-attribution-20260615`
- Checks command: `.hill-climbing/h2-body-read-attribution-20260615/checks.sh`
- Controls held constant: H2C, 1 connection, 16 streams, `/echo`, 1024-byte body, traced 8k requests x 5 repeats.

### Result
- Primary metric: `h2_body_handler_to_available_p99_us=678`
- Key metrics:
  - `handler -> first_read_call p99=1 us`
  - `first_read_call -> arm p99=268 us`
  - `first_arm -> data p99=-7 us`
  - `reader_delivery_after_ready p99=3 us`
  - `chunk_callback -> return p99=100 us`
  - `eof_call -> eof_return p99=377 us`
  - `eof_armed -> eof_callback p99=3 us`
  - `eof_return -> body_available p99=4 us`
  - top 1% dominant: EOF roundtrip `0.6125`, first read command `0.3125`, chunk return `0.1375`, wait for DATA `0`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T09:43:33Z`.

### Verdict
- Verdict: split-needed.
- Reason: DATA wait is rejected; body reader delivery is tiny. The large bucket is EOF roundtrip, but that needed a second split into command wait vs EOF callback/return.
- Hypothesis space update: refine H4 into second read command wait and EOF resolver/handler wake.
- Commit/revert decision: keep trace instrumentation and parser.
- Next experiment: split EOF roundtrip.

## E2: Split EOF Roundtrip

### Hypothesis Space Split
- Parent question: why does the second EOF read roundtrip dominate body availability tails?
- Hypothesis under test: H3/H4 refinement.
- Rival hypotheses: second read owner command wait, EOF callback delivery, EOF resolver/handler wake, post-EOF handler continuation.
- Why this split is high value: `read_all` performs one chunk read and then a second read to observe EOF; the prior run showed that second roundtrip is expensive in the tail.

### Prediction Before Run
- Expected primary metric movement: none; diagnostic parser refinement only.
- Expected secondary metric movement: second read command wait or EOF callback-to-return should dominate if scheduler/wakeup is the mechanism.
- Distinguishing observation: top 1% rows by body availability classify into command wait vs EOF wake.
- Falsifier: EOF callback itself or post-EOF handler continuation dominates.

### Attack
- Change or probe: extended `measure.sh` to split `eof_call -> eof_return` into second read call-to-arm, EOF callback, and EOF callback-to-return.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-body-read-attribution-20260615`
- Checks command: `.hill-climbing/h2-body-read-attribution-20260615/checks.sh`
- Controls held constant: same traced H2C 1x16 `/echo` workload.

### Result
- Primary metric: `h2_body_handler_to_available_p99_us=701`
- Key metrics:
  - `first_read_call -> arm p99=236 us`
  - `first_arm -> data p99=-8 us`
  - `reader_delivery_after_ready p99=3 us`
  - `chunk_callback -> return p99=130 us`
  - `second_read_call -> arm p99=85 us`
  - `eof_armed -> eof_callback p99=3 us`
  - `eof_callback -> return p99=130 us`
  - `eof_return -> body_available p99=4 us`
  - top 1% dominant: first read command `0.425`, EOF callback-to-return `0.2375`, second read command `0.2`, chunk return `0.175`, wait for DATA `0`
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T09:44:52Z`.

### Verdict
- Verdict: corroborated H3 and H4; rejected H1/H2/H5.
- Reason: DATA is already available before the first body read is armed; H2 body reader callback is ~3 us p99. The tail comes from owner-command and handler-wakeup roundtrips around `Body.read_all`, especially the required second read to observe EOF after the final chunk.
- Hypothesis space update: the actionable mechanism is extra cross-fiber read/EOF roundtrips for request bodies whose DATA and END_STREAM are already buffered.
- Commit/revert decision: keep measurement-only instrumentation and hill scripts.
- Next experiment: validate an optimization strategy that collapses the final-chunk/EOF roundtrip or lets `read_all` complete when content-length bytes and peer END_STREAM are already known.

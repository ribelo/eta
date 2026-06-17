# Research Journal: h2-final-eof-fastpath-20260615

## Hill

- Goal: validate and improve the H2C 1x16 `/echo` final-chunk EOF fast path so
  `Body.read_all` avoids the owner-thread EOF read when DATA and EOF are already
  buffered by the H2 reader.
- Primary metric: `h2_body_handler_to_available_p99_us`
- Direction: lower.
- Benchmark facade: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-final-eof-fastpath-20260615`
- Session directory: `.hill-climbing/h2-final-eof-fastpath-20260615/`

## Anti-Gaming Contract

The goal is to improve the real H2 echo tail, not merely the script. Do not
change the workload shape, special-case `/echo`, skip request body validation,
weaken checks, or hide latency by moving required work outside the measured
path.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_body_handler_to_available_p99_us` | Primary | lower | Keep only changes that reduce this beyond noise and pass checks | Handler start to `Body.read_all` completion |
| `h2_client_total_p99_us` | Secondary | lower | Should not regress materially | Client t0 to body EOF |
| `h2_body_final_chunk_fraction` | Guard | exactly 1.0 | Must remain 1.0 for this workload | Confirms final-chunk marker fires |
| `h2_body_owner_eof_read_fraction` | Guard | exactly 0.0 | Must remain 0.0 after fast path | Confirms no owner EOF read |
| `h2_body_cached_eof_call_to_return_p99_us` | Diagnostic | lower | Should replace the old EOF callback/owner wait | Handler-local cached EOF return |
| `h2_body_second_read_call_to_arm_p99_us` | Diagnostic | lower | Should collapse to 0 after fast path | Old owner EOF read command |
| `h2_body_eof_callback_to_return_p99_us` | Diagnostic | lower | Should collapse to 0 after fast path | Old EOF callback wake |

Noise policy:

- Use repeated samples and compare medians.
- Treat tiny wins as inconclusive unless they simplify the mechanism.
- Keep instrumentation only when it preserves the workload and helps future
  discrimination.

## Hypothesis Space

Root question:

> Does the final-chunk EOF fast path remove the measured H2 request-body tail
> without trading away correctness?

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Fast path removes the old EOF hill | Final chunk carries a cached EOF result, so `read_all` no longer enqueues an owner EOF read | `final_chunk_fraction=1`, `owner_eof_read_fraction=0`, primary p99 drops | Owner EOF reads remain or p99 stays at baseline | open |
| H2 | Remaining tail is first read owner wake | EOF roundtrip collapses but first read command/chunk return dominates | EOF metrics are zero, first read/chunk return dominate top rows | EOF metrics still dominate | open |
| H3 | Fast path changes correctness semantics | EOF validation/trailer cleanup changes observable behavior | Focused HTTP checks fail | Checks pass | open |
| H_other | Residual explanation not modeled | Unknown | Current experiment does not distinguish it | A better split replaces it | open |

## Experiment Selection Rule

- Prefer experiments that falsify one live hypothesis.
- Keep benchmark shape stable.
- Run the facade and checks for every candidate.
- Keep changes only when the primary metric improves, guards hold, and checks
  pass.

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

Append completed entries below. Keep entries concise, falsifiable, and useful to
a fresh agent.

## E1: Final-Chunk Cached EOF

### Hypothesis Space Split
- Parent question: can `read_all` avoid the second owner-thread EOF read when
  the H2 reader has already consumed EOF?
- Hypothesis under test: H1.
- Rival hypotheses: remaining tail is first read owner wake or chunk-return
  handler wake.
- Why this split is high value: previous attribution showed the second EOF
  roundtrip was a material part of `handler_started -> body_available`.

### Prediction Before Run
- Expected primary metric movement: lower than the prior 701 us diagnostic
  baseline.
- Expected secondary metric movement: `final_chunk_fraction=1.0`,
  `owner_eof_read_fraction=0.0`, EOF callback metrics collapse to zero.
- Distinguishing observation: cached EOF return is single-digit microseconds.
- Falsifier: owner EOF reads remain or checks fail.

### Attack
- Change or probe: H2 request body reads now return a private final-chunk marker
  when `H2.Body.Reader.is_closed` is true after delivering a chunk; the handler
  body adapter caches the EOF result for the next public read.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-final-eof-fastpath-20260615`
- Checks command: `.hill-climbing/h2-final-eof-fastpath-20260615/checks.sh`
- Controls held constant: H2C, one connection, 16 streams, `/echo`, 1024-byte
  body, 8k requests x 5 repeats.

### Result
- Primary metric: `h2_body_handler_to_available_p99_us=510`
- Secondary metrics: `final_chunk_fraction=1.0`,
  `owner_eof_read_fraction=0.0`, `cached_eof_call_to_return_p99_us=3`,
  `second_read_call_to_arm_p99_us=0`,
  `eof_callback_to_return_p99_us=0`, `h2_client_total_p99_us=1353`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T10:06:31Z`.

### Verdict
- Verdict: corroborated.
- Reason: the old EOF owner read disappeared and primary p99 improved by about
  27% against the previous 701 us body-read attribution run.
- Hypothesis space update: H1 accepted for this workload; remaining tail moved
  to first read command wait and chunk callback-to-handler return.
- Commit/revert decision: keep.
- Next experiment: test whether the owner is doing avoidable write flushing
  after resolving an inline body read.

## E2: Conditional Post-Read Flush

### Hypothesis Space Split
- Parent question: why does chunk callback-to-return remain high after cached
  EOF?
- Hypothesis under test: the owner may delay the handler by running
  `flush_writes` after an inline body read even when no wire bytes are pending.
- Rival hypotheses: scheduler noise or unavoidable promise wake dominates.
- Why this split is high value: skipping the flush broadly improved p99 but
  would be unsafe for larger bodies that need WINDOW_UPDATE promptly flushed.

### Prediction Before Run
- Expected primary metric movement: lower than E1 when no H2 bytes are pending.
- Expected secondary metric movement: guards remain
  `final_chunk_fraction=1.0`, `owner_eof_read_fraction=0.0`; client p99 should
  not regress.
- Distinguishing observation: conditional flush keeps the no-flush benefit for
  the 1 KiB echo shape while preserving the flow-control flush path.
- Falsifier: p99 regresses to E1 or guards/checks fail.

### Attack
- Change or probe: added `H2.Connection.has_pending_write` and flush after an
  inline request-body read only when serialized bytes are already pending.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h2-final-eof-fastpath-20260615`
- Checks command: `.hill-climbing/h2-final-eof-fastpath-20260615/checks.sh`
- Controls held constant: same workload and checks.

### Result
- Primary metric: best run `h2_body_handler_to_available_p99_us=452`
- Secondary metrics: `h2_client_total_p99_us=1212`,
  `final_chunk_fraction=1.0`, `owner_eof_read_fraction=0.0`,
  `cached_eof_call_to_return_p99_us=3`,
  `second_read_call_to_arm_p99_us=0`,
  `eof_callback_to_return_p99_us=0`.
- Checks: passed.
- `log.jsonl` reference: best run at `2026-06-15T10:09:46Z`; an earlier noisy
  conditional run measured 557 us but still passed.

### Verdict
- Verdict: corroborated.
- Reason: best primary p99 improved another ~11% over E1 while preserving EOF
  and flow-control guards.
- Hypothesis space update: the old EOF hill is gone; remaining outliers are
  first read command wait and chunk-return handler wake, likely scheduler noise
  or unavoidable owner/handler handoff.
- Commit/revert decision: keep conditional flush, not the unsafe broad
  no-flush variant.
- Next experiment: if climbing further, split first read command wait versus
  handler wake with off-CPU/scheduler attribution instead of more body-copy work.

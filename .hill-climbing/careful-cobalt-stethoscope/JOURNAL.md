# Research Journal: careful-cobalt-stethoscope

## Hill

- Goal: improve Eta H2C `POST /echo` 1 KiB p99 under one H2 connection with 16 concurrent streams, using a fresh instrumented split before changing code.
- Primary metric: `h2_plain_echo_1k_p99_ms`
- Direction: lower
- Benchmark facade: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Session directory: `.hill-climbing/careful-cobalt-stethoscope/`

## Anti-Gaming Contract

The goal is to improve the real H2 plain echo tail. Do not remove workload, reduce request count, weaken success checks, special-case `/echo` in production code, cache invalidly, or trade away root/post_user/static_1k guardrails to make the metric look better.

Instrumentation is diagnostic only. The primary p99 metric is measured after restarting the H2C probe with `ETA_H2_ECHO_TRACE_PATH` unset.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_echo_1k_p99_ms` | Primary | lower | Keep a change only if this improves beyond noise, checks pass, and guardrails do not regress. | Uninstrumented primary phase. |
| `h2_plain_echo_1k_p99_mad_ms` | Noise | lower/stable | Wide MAD requires confirmation. | Median-of-9 repeats. |
| `h2_plain_root_p99_ms`, `h2_plain_post_user_p99_ms`, `h2_plain_static_1k_p99_ms` | Guardrail | stable/lower | Reject broad H2 regressions. | Same uninstrumented server phase. |
| `h2_echo_trace_accepted_to_body_us_p99` | Diagnostic | lower | Measures headers accepted to full body available. | Joins H2 request-accepted and echo handler body-available events. |
| `h2_echo_trace_body_read_us_p99` | Diagnostic | lower | Splits request-body read from response/write path. | Short traced echo-only phase. |
| `h2_echo_trace_write_wait_us_p99` | Diagnostic | lower | Measures response start to first outgoing H2 frame for that stream. | H2-side event. |
| `h2_echo_trace_response_write_us_p99` | Diagnostic | lower | Measures response start to write completion for the write job carrying the stream. | H2-side event. |
| `h2_echo_trace_copy_bytes_per_stream` | Diagnostic | lower | Estimates buffer/copy work per traced stream. | Handler + request body + response + write-job copy events. |
| `success`, `h2_echo_trace_success`, `h2_echo_trace_oha_success` | Correctness | exactly 1 | Any zero requires fixing the hill or rejecting the experiment. | Primary and diagnostic phases. |

Noise policy:

- Treat trace metrics as explanatory, not acceptance criteria by themselves.
- Confirm any p99 win at least once when it is close to the prior MAD.
- Rejected experiments stay in the journal; code must be reverted.

## Hypothesis Space

Root question:

> What mechanism currently limits H2 plain echo_1k p99?

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Request body read dominates | Body DATA arrives late, read scheduling waits, or read callbacks are the tail. | `h2_echo_trace_accepted_to_body_us_p99` or `h2_echo_trace_body_read_us_p99` is close to primary p99 and larger than write diagnostics. | Accepted-to-body and body-read p99 are small while write/wait p99 is large. | open |
| H2 | Response write/flush dominates | Fixed response start to write completion carries most tail. | `h2_echo_trace_response_write_us_p99` is close to primary p99. | Write-complete p99 is small. | open |
| H3 | H2 stream scheduling before write dominates | Handler has response ready, but the stream waits in owner/write scheduling before first frame. | `h2_echo_trace_write_wait_us_p99` is large while body-read p99 is smaller. | Write wait p99 is small. | open |
| H4 | Buffer/copy path dominates | Copies in handler/body/H2 write path create CPU pressure and tail. | Copy bytes per stream are high and copy-removal changes improve p99/RPS without moving wait timing much. | Copy volume is low or copy-removal does not help. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it. | A better split replaces it. | open |

## Experiment Selection Rule

- First run establishes the fresh instrumented baseline.
- Pick the next change from the dominant diagnostic p99 component.
- Prefer scoped changes that preserve the public API and all guardrails.
- Do not tune the diagnostic pass independently of the primary hill.

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
- Diagnostic metrics:
- Guardrails:
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

## E0: instrumented baseline

### Hypothesis Space Split
- Parent question: Which echo-path phase explains H2 plain echo_1k p99?
- Hypothesis under test: baseline split only.
- Rival hypotheses: H1 request-body read, H2 response write/flush, H3 stream scheduling, H4 copy path, H_other.
- Why this split is high value: it gives a fresh primary baseline and diagnostic timing slices before another optimization.

### Prediction Before Run
- Expected primary metric movement: none.
- Expected secondary metric movement: at least one diagnostic phase should stand out if the tail is server-internal.
- Distinguishing observation: dominant diagnostic p99 near the primary p99.
- Falsifier: all diagnostic timing p99s are much smaller than primary p99.

### Attack
- Change or probe: added env-gated trace events for H2 request accepted, echo body available, body copy, fixed response copy, first write readiness, and write completion; primary phase remains uninstrumented.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: one H2C connection, 16 streams, 1 KiB echo body, primary 24k requests x 9 repeats.

### Result
- Primary metric: `h2_plain_echo_1k_p99_ms=1.661194`.
- Diagnostic metrics: accepted-to-body p99 `240 us`; handler body read p99 `238 us`; write wait p99 `81 us`; response write p99 `269 us`; estimated copy bytes per stream `3110`.
- Guardrails: root/post_user/static_1k p99 `0.164194/0.196515/0.281298 ms`; success `1`; trace success `1`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T08:03:08Z`.

### Verdict
- Verdict: split-needed
- Reason: no traced server-internal timing slice approaches the primary p99, but copy volume is high and includes an avoidable fixed-response single-chunk copy.
- Hypothesis space update: H1/H2/H3 do not individually explain the whole p99 in the short diagnostic pass. H4 has a cheap falsifier: remove the H2 fixed-response concat copy for single chunks and see whether primary p99/RPS move.
- Commit/revert decision: keep instrumentation and hill setup.
- Next experiment: add a single-chunk fast path in `respond_fixed` and correct the copy diagnostic so it only counts actual fixed-response concat copies.

## E1: H2 fixed-response single-chunk fast path

### Hypothesis Space Split
- Parent question: Does avoidable response-copy work contribute to echo p99/RPS?
- Hypothesis under test: H4 copy path, specifically `respond_fixed` concatenating a single response chunk.
- Rival hypotheses: H1/H2/H3 timing slices, H_other external/scheduler effects.
- Why this split is high value: it removes a known 1 KiB copy per echo response in production H2 response handling without changing benchmark semantics.

### Prediction Before Run
- Expected primary metric movement: small p99 and/or RPS improvement.
- Expected secondary metric movement: `h2_echo_trace_response_copy_bytes_count` should drop to zero for 1 KiB single-chunk echo responses.
- Distinguishing observation: copy metric drops and primary metric confirms at least a small improvement with guardrails stable.
- Falsifier: p99/RPS do not confirm or guardrails regress.

### Attack
- Change or probe: added `Response_fixed ([chunk], _)` fast path in `respond_fixed`; diagnostic fixed-response copy counter now only counts multi-chunk concat copies.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and request shape.

### Result
- Primary metric: first valid run `1.635675 ms`; confirmation `1.613873 ms` versus E0 `1.661194 ms`.
- Diagnostic metrics: response copy count `0`; copy bytes per stream `2086.021`; response write p99 `295/233 us`; accepted-to-body p99 `311/299 us`.
- Guardrails: confirmation root/post_user/static_1k p99 `0.160387/0.203760/0.234949 ms`; success `1`.
- Checks: passed. One earlier run failed due a non-exhaustive diagnostic-only copy-count match; fixed before valid runs.
- `log.jsonl` reference: failed run at `2026-06-15T08:04:02Z`; valid runs at `2026-06-15T08:04:35Z` and `2026-06-15T08:04:51Z`.

### Verdict
- Verdict: corroborated
- Reason: p99 improved on confirmation, guardrails stayed healthy, and the copy diagnostic moved exactly as predicted.
- Hypothesis space update: H4 remains live; the next redundant copy is `Server.Response.Body.string` performing `Bytes.of_string` and then immediately copying again through `fixed`.
- Commit/revert decision: keep.
- Next experiment: make `Server.Response.Body.string` construct its fresh bytes directly without routing through `fixed`.

## E2: avoid duplicate copy in `Response.Body.string`

### Hypothesis Space Split
- Parent question: Does reducing generic response body construction copies improve echo p99?
- Hypothesis under test: H4 copy path, specifically `Server.Response.Body.string` copying the fresh `Bytes.of_string` buffer again through `fixed`.
- Rival hypotheses: remaining p99 is outside app/body copy work.
- Why this split is high value: one-line production helper fix; diagnostic copy estimate should move by exactly 1 KiB per echo response.

### Prediction Before Run
- Expected primary metric movement: small p99/RPS improvement or neutral.
- Expected secondary metric movement: handler copy estimate drops from 3072 to 2048 bytes.
- Distinguishing observation: copy metric drops and primary confirms no regression.
- Falsifier: primary p99 regresses on confirmation or checks fail.

### Attack
- Change or probe: changed `Server.Response.Body.string` to construct `Fixed [Bytes.of_string value]` directly; updated echo diagnostic copy estimate.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and request shape.

### Result
- Primary metric: first run `1.815729 ms`; confirmation `1.612371 ms`.
- Diagnostic metrics: handler copy bytes p50/p99 `2048`; response copy count remains `0`; accepted-to-body p99 `363/271 us`; response-write p99 `326/253 us`.
- Guardrails: confirmation root/post_user/static_1k p99 `0.160798/0.192939/0.238887 ms`; success `1`.
- Checks: passed both runs.
- `log.jsonl` reference: runs at `2026-06-15T08:05:59Z` and `2026-06-15T08:06:16Z`.

### Verdict
- Verdict: corroborated
- Reason: confirmation returned to the improved E1 p99 range while reducing generic response construction copy cost and improving echo RPS to `88064`.
- Hypothesis space update: copy-path work still has a live bucket: H2 write-job copying from H2 bigstrings into the reusable Cstruct buffer.
- Commit/revert decision: keep.
- Next experiment: test zero-copy write jobs using `Cstruct.of_bigarray` slices directly, reverting if buffer lifetime or p99 guardrails fail.

## E3: owned response-body echo probe

### Hypothesis Space Split
- Parent question: Does removing handler-side echo response copies reduce H2 echo p99?
- Hypothesis under test: H4 copy path, specifically the probe converting the owned request bytes through `string`.
- Rival hypotheses: remaining tail comes from H2 request/write scheduling or external timing, not handler copies.
- Why this split is high value: it would remove two handler copies per echo response with a small explicit ownership API if the metric moved.

### Prediction Before Run
- Expected primary metric movement: lower p99 and/or higher RPS.
- Expected secondary metric movement: `h2_echo_trace_handler_copy_bytes_p99` drops from `2048` to `0`.
- Distinguishing observation: primary p99 confirms an improvement while guardrails and checks pass.
- Falsifier: handler copies drop but uninstrumented p99 does not improve.

### Attack
- Change or probe: temporarily added `Server.Response.Body.fixed_owned` and used it in the echo probe.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Checks command: hill `checks.sh`.
- Controls held constant: same fresh hill facade and request shape.

### Result
- Primary metric: `1.718404 ms`; confirmation `1.639622 ms`, versus accepted E2 confirmation `1.612371 ms`.
- Diagnostic metrics: handler copy bytes p50/p99 dropped to `0`; request/write-job copy metrics unchanged; response-write p99 `235/272 us`.
- Guardrails: success `1`; focused checks passed.
- `log.jsonl` reference: runs at `2026-06-15T08:14:11Z` and `2026-06-15T08:14:25Z`.

### Verdict
- Verdict: rejected
- Reason: the diagnostic moved exactly as predicted, but the primary p99 did not beat the accepted baseline and the confirmation remained noisy.
- Hypothesis space update: handler copies are not the current p99 limiter in this workload. H4 remains live only for lower-level H2 write-job copies.
- Commit/revert decision: reverted.
- Next experiment: test H2 write-job zero-copy from the iovecs returned by ocaml-h2, reverting if checks or guardrails fail.

## E4: H2 write-job zero-copy iovecs

### Hypothesis Space Split
- Parent question: Does the H2 adapter copy from ocaml-h2 write iovecs into Eta's write buffer limit echo p99?
- Hypothesis under test: H4 copy path, specifically `copy_write_job`.
- Rival hypotheses: the copy coalesces writes beneficially, or the tail is outside write-job copying.
- Why this split is high value: it removes the largest remaining diagnostic copy bucket without changing handler semantics or request counts.

### Prediction Before Run
- Expected primary metric movement: lower p99 if write-job copy CPU pressure is limiting.
- Expected secondary metric movement: `h2_echo_trace_write_job_copy_bytes_count=0` and copy bytes per stream near `1024`.
- Distinguishing observation: copy metric drops and primary p99/RPS improve or stay at least neutral.
- Falsifier: copy metric drops but p99/RPS regress.

### Attack
- Change or probe: temporarily stored `Cstruct.of_bigarray` slices from ocaml-h2 write iovecs directly in `write_job` and passed that list to `Eio.Flow.write`; trace scanning copied only in the diagnostic phase.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id careful-cobalt-stethoscope`
- Checks command: hill `checks.sh`.
- Controls held constant: same fresh hill facade and request shape.

### Result
- Primary metric: `1.861987 ms`, versus accepted E2 confirmation `1.612371 ms`.
- Diagnostic metrics: write-job copy count dropped to `0`; copy bytes per stream dropped to `1024`; response-write p99 `247 us`; write-wait p99 `94 us`.
- Guardrails: root/post_user/static_1k p99 `0.159816/0.199651/0.245128 ms`; success `1`; checks passed.
- `log.jsonl` reference: run at `2026-06-15T08:16:21Z`.

### Verdict
- Verdict: rejected
- Reason: the copy disappeared, but echo p99 and RPS regressed materially. The contiguous Eta write buffer appears beneficial for this workload, or the tail is not copy-bound.
- Hypothesis space update: H4 copy-path work is not the next useful climb after E1/E2. Remaining diagnostic timing slices are all far below primary p99, so the hill is likely dominated by lower-frequency scheduling/client/runtime outliers.
- Commit/revert decision: reverted.
- Next experiment: inspect repeat distributions and consider tightening the benchmark/reporting before touching production code again.

## Final Status

- Accepted changes: E1 H2 fixed-response single-chunk fast path; E2 direct `Response.Body.string` construction without routing through `fixed`.
- Rejected changes: E3 owned response-body API/probe path; E4 zero-copy H2 write-job iovecs.
- Best passing primary observed: `h2_plain_echo_1k_p99_ms=1.612371` at `2026-06-15T08:06:16Z`.
- Final accepted-state verification: `1.754572 ms` at `2026-06-15T08:17:23Z`; checks passed, but the p99 remains noisy (`p99_mad_ms=0.090033`).
- Diagnostic split on accepted state: request accepted-to-body p99 `212 us`, body read p99 `210 us`, write wait p99 `151 us`, response write p99 `235 us`, request/response/write copy event total `2086` bytes per stream plus handler copy estimate `2048` bytes.
- Interpretation: the fresh hill is set up and useful, and the cheap copy fixes are retained, but the remaining p99 is not explained by the measured server-internal slices. Further production changes should wait for a better split of the low-frequency p99 outlier source.
- Verification: hill `checks.sh` passed; `git diff --check` passed. Full `nix develop -c dune runtest --force` still fails at the pre-existing HPACK header type mismatch in `test/http/test_eta_http_h2_hpack.ml:42` and `test/http/test_eta_http_h2_server.ml:352`.

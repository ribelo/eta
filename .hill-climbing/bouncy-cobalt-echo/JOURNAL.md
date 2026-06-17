# Research Journal: bouncy-cobalt-echo

## Hill

- Goal: reduce Eta H2C `POST /echo` 1 KiB request-body p99 latency under one H2 connection with 16 concurrent streams.
- Primary metric: `h2_plain_echo_1k_p99_ms`
- Direction: lower
- Benchmark facade: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Session directory: `.hill-climbing/bouncy-cobalt-echo/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

This is a fresh H2 plain echo hill. Older sessions may provide prior art, but their logs and best values are not this hill's baseline.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h2_plain_echo_1k_p99_ms` | Primary | lower | Keep a change only when the median-of-repeats p99 improves beyond local noise, checks pass, and the change serves the real H2 request-body echo path. | `oha --http-version 2`, `-c 1`, `-p 16`, `POST /echo`, 1024-byte body. |
| `h2_plain_echo_1k_p99_mad_ms` | Secondary | lower | A p99 win with much wider MAD is provisional and needs confirmation. | Guards against chasing a lucky repeat. |
| `h2_plain_echo_1k_rps` | Secondary | higher | Large throughput loss rejects a p99-only win unless the implementation clearly removes tail work without reducing capacity. | Median requests/sec across repeats. |
| `h2_plain_root_p99_ms`, `h2_plain_post_user_p99_ms`, `h2_plain_static_1k_p99_ms` | Guardrail | lower/stable | Reject broad regressions in non-echo H2C paths unless intentionally explained and separately accepted. | Keeps the hill from becoming echo-only gaming. |
| `success` | Correctness | exactly 1 | Any value other than 1 rejects the run. | Requires all samples to return expected 200 counts with no errors. |

Noise policy:

- Baseline variance is established by the first run of this fresh hill.
- `measure.sh` uses repeated samples and compares medians.
- Treat changes inside the p99 MAD/noise floor as inconclusive unless they simplify code or improve a secondary constraint without hurting the primary metric.

## Hypothesis Space

Root question:

> What mechanism currently limits H2C 1 KiB echo p99 under one connection and 16 streams?

Maintain a partition of plausible explanations. Keep `H_other` for residual uncertainty until a better split replaces it.

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Ingress copy/parse overhead dominates the tail | Each socket read is filtered, copied into an ingress buffer, then parsed by the H2 state machine; removing an avoidable copy should reduce echo p99 more than root/static p99. | Directly feeding unchanged safe ingress bytes improves `echo_1k` p99 and/or p95 without hurting success or guardrails. | No echo p99 movement, or guardrails regress while echo does not. | open |
| H2 | Request-body stream scheduling dominates the tail | DATA frames wake stream/body fibers in a way that creates occasional latency spikes under 16 streams. | Changes around request-body delivery/backpressure move echo p99 while root/static stay mostly flat. | Body-path changes do not move echo p99 or cause correctness failures. | open |
| H3 | Response write/flush behavior dominates the tail | Echo must write a 1 KiB response after body read; batching or flush policy creates p99 outliers. | Write-path changes improve echo and static_1k similarly, with smaller effect on root/post_user. | Echo moves independently of static_1k, or write changes are neutral. | open |
| H4 | Benchmark/system noise dominates remaining p99 | Scheduler or load-generator variation creates spikes unrelated to server code. | Repeated baselines show wide MAD/max spread and code changes fail confirmation. | A scoped implementation change produces repeatable p99 reduction with stable MAD. | open |
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

## E0: fresh baseline

### Hypothesis Space Split
- Parent question: What mechanism currently limits H2C 1 KiB echo p99 under one connection and 16 streams?
- Hypothesis under test: baseline only.
- Rival hypotheses: H1 ingress copy/parse, H2 body scheduling, H3 response write/flush, H4 noise.
- Why this split is high value: establishes this fresh hill's own baseline instead of reusing older session logs.

### Prediction Before Run
- Expected primary metric movement: none.
- Expected secondary metric movement: echo should stand apart if the broad-suite caveat is real.
- Distinguishing observation: echo p99 materially exceeds root/post_user/static_1k p99.
- Falsifier: echo p99 falls into the same range as guardrails.

### Attack
- Change or probe: created fresh benchmark facade with 24k requests, 9 repeats, one H2C connection, 16 streams.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: H2C probe server, 1024-byte echo body, request success validation, pinned cores by default.

### Result
- Primary metric: `h2_plain_echo_1k_p99_ms=1.889118`
- Secondary metrics: echo p50 `0.143845 ms`, p95 `0.373383 ms`, p99 MAD `0.074212 ms`, rps `80727`; root/post_user/static_1k p99 `0.161779/0.187267/0.251260 ms`; geomean rps `147290`; success `1`.
- Checks: passed.
- `log.jsonl` reference: first run, timestamp `2026-06-15T01:12:33Z`.

### Verdict
- Verdict: corroborated
- Reason: isolated fresh hill still shows echo p99 far above non-body guardrails.
- Hypothesis space update: H1 and H2 remain stronger than H3; H4 noise remains live because p99 max reached `2.593363 ms`, but MAD is narrow enough to test implementation changes.
- Commit/revert decision: keep hill setup.
- Next experiment: attack H1 by removing the remaining safe ingress-buffer copy when filtered ingress can be passed directly to the H2 parser.

## E1: direct feed unchanged ingress bytes

### Hypothesis Space Split
- Parent question: Does the remaining ingress-buffer copy dominate echo p99?
- Hypothesis under test: H1, specifically the copy from filtered socket bytes into `t.ingress_buffer`.
- Rival hypotheses: H2 body scheduling, H3 write/flush behavior, H4 noise.
- Why this split is high value: it is a narrow hot-path change that should directly reduce work for DATA-heavy echo requests if the copy is material.

### Prediction Before Run
- Expected primary metric movement: echo p99 should improve beyond baseline noise.
- Expected secondary metric movement: echo p50/p95 and maybe RPS should improve or remain stable; root/static guardrails should not regress.
- Distinguishing observation: repeatable echo p99 reduction with stable or lower MAD.
- Falsifier: confirmation run returns to baseline/worse, or MAD widens without a robust median win.

### Attack
- Change or probe: added a guarded direct `H2.Connection.read` path for unchanged offset-zero ingress when `t.ingress_len = 0`, with normal buffering for unconsumed tails.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and default pinned cores.

### Result
- Primary metric: first run `1.848901 ms`; confirmation `1.944554 ms`.
- Secondary metrics: first run p99 MAD `0.107145 ms`, echo rps `79282`; confirmation p99 MAD `0.131370 ms`, echo rps `80369`; success `1` both runs.
- Checks: passed both runs.
- `log.jsonl` reference: runs at `2026-06-15T01:14:03Z` and `2026-06-15T01:14:17Z`.

### Verdict
- Verdict: rejected
- Reason: the apparent first-run win did not confirm, and MAD widened versus E0.
- Hypothesis space update: narrow H1/copy variant is unlikely to be the main limit; broader H1 parse/filter overhead remains possible, but H2 request-body scheduling is now the stronger next target.
- Commit/revert decision: reverted direct-feed code.
- Next experiment: inspect and attack request-body stream wakeup/drain behavior for 1 KiB DATA payloads under 16 streams.

## E2: skip no-op flush after pending request-body read

### Hypothesis Space Split
- Parent question: Is command-loop work around pending request-body reads contributing to echo p99?
- Hypothesis under test: H2 request-body scheduling, specifically unnecessary `flush_writes` calls after arming a body read that did not consume DATA inline.
- Rival hypotheses: H1 broader ingress parse/filter overhead, H3 response write/flush, H4 noise.
- Why this split is high value: preserves the serialized body-read owner model while removing one no-op command-loop operation from the common pending-read path.

### Prediction Before Run
- Expected primary metric movement: echo p99 should improve if many echo handlers arm reads before DATA arrives.
- Expected secondary metric movement: echo RPS should improve or stay flat; p99 MAD should not widen; guardrails should be stable.
- Distinguishing observation: repeated echo p99 reduction with lower or stable MAD.
- Falsifier: confirmation regresses to baseline, checks fail, or upload/flow-control tests fail.

### Attack
- Change or probe: made `arm_request_body_read` return whether DATA was consumed inline; `Request_body_read` flushes only for inline reads and skips the flush when the read is merely armed.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and default pinned cores.

### Result
- Primary metric: first run `1.807012 ms`; confirmation `1.721418 ms`.
- Secondary metrics: echo p50 `0.140699/0.140148 ms`, p95 `0.362072/0.362292 ms`, p99 MAD `0.070924/0.048202 ms`, echo rps `84221/85565`; success `1` both runs.
- Checks: passed both runs.
- `log.jsonl` reference: runs at `2026-06-15T01:16:23Z` and `2026-06-15T01:16:36Z`.

### Verdict
- Verdict: corroborated
- Reason: improvement confirmed, MAD narrowed, and echo throughput improved without correctness failures.
- Hypothesis space update: H2 request-body scheduling remains the leading explanation. The next suspect is per-read timeout arming for pending reads, which may fork sleeper fibers on the same hot path.
- Commit/revert decision: keep.
- Next experiment: inspect whether pending request-body reads arm per-read timeout sleepers and test a cheaper timeout path if the current code forks per read.

## E3: move pending body-read timeouts onto the connection watchdog

### Hypothesis Space Split
- Parent question: Are per-read timeout sleepers the main body-path tail source?
- Hypothesis under test: H2 request-body scheduling, specifically the `fork_daemon`/sleep timeout per pending request-body read.
- Rival hypotheses: H3 response write/flush behavior, H4 benchmark/system noise.
- Why this split is high value: eliminating the long-lived per-read timeout sleeper should be highly visible if pending reads dominate echo p99.

### Prediction Before Run
- Expected primary metric movement: echo p99 should fall substantially if per-read sleepers are the dominant tail mechanism.
- Expected secondary metric movement: guardrail endpoints should stay near E2 because they do not read request bodies.
- Distinguishing observation: echo p99 improves without root/post_user/static_1k p99 regressions.
- Falsifier: non-body guardrails regress materially, indicating lifecycle or scheduler side effects.

### Attack
- Change or probe: replaced per-read request-body timeout sleepers with connection-watchdog request-read watches, then tried a bounded active-list watch and extra cleanup at END_STREAM/discard boundaries.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and default pinned cores.

### Result
- Primary metric: target improved dramatically: `0.284363`, `0.295614`, `0.319730`, `0.262051`, and `0.271579 ms` across variants.
- Secondary metrics: guardrails regressed consistently; root p99 around `0.47-0.50 ms`, post_user around `0.90-0.94 ms`, static_1k around `0.60-0.93 ms`, versus E2/root/post/static around `0.16/0.20/0.25 ms`.
- Checks: passed.
- `log.jsonl` reference: runs from `2026-06-15T01:19:29Z` through `2026-06-15T01:23:35Z`.

### Verdict
- Verdict: rejected
- Reason: the target win was real but traded away broad H2C tail latency, violating the guardrail contract.
- Hypothesis space update: per-read timeout arming is a major echo-tail mechanism, but moving all pending read timers to a watchdog has unacceptable cross-endpoint effects in this implementation. A narrower delayed-arm variant may keep most of the correctness semantics while avoiding long-lived sleepers for reads that resolve immediately after the owner loop yields.
- Commit/revert decision: reverted to E2. Revert verification run measured echo p99 `1.642768 ms`, p99 MAD `0.033053 ms`, echo rps `87225`, root/post_user/static_1k p99 `0.163793/0.198048/0.251521 ms`, success `1`.
- Next experiment: try deferred timeout arming for pending body reads: yield once, then arm the existing sleeper only if the same resolver is still active.

## E4: deferred body-read timeout arming

### Hypothesis Space Split
- Parent question: Can the per-read timeout cost be reduced without the E3 guardrail regression?
- Hypothesis under test: many pending echo reads resolve after one scheduler yield, so a short deferred check can avoid long-lived timeout sleepers while preserving normal timeout enforcement for genuinely pending reads.
- Rival hypotheses: timeout sleeper creation itself is not the remaining E2 tail; the E3 win came from a broader scheduling side effect.
- Why this split is high value: it attacks the E3 mechanism with a much narrower change and should preserve guardrails.

### Prediction Before Run
- Expected primary metric movement: echo p99 should improve below E2 if most pending reads resolve within one yield.
- Expected secondary metric movement: guardrails should stay near E2.
- Distinguishing observation: echo p99 moves toward E3 without root/post_user/static_1k p99 regressions.
- Falsifier: echo p99 stays in the E2 range or worsens.

### Attack
- Change or probe: made the request-body timeout daemon yield once, check whether the same resolver is still pending, and only then sleep/enqueue the timeout.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and default pinned cores.

### Result
- Primary metric: `1.746337 ms`.
- Secondary metrics: echo p99 MAD `0.107254 ms`, echo rps `82903`; root/post_user/static_1k p99 `0.164394/0.190113/0.252232 ms`; success `1`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T01:25:59Z`.

### Verdict
- Verdict: rejected
- Reason: guardrails were healthy, but echo p99 and MAD were worse than the accepted E2 verification.
- Hypothesis space update: the safe delayed-arm variant did not capture the E3 win. Remaining work should investigate body-read scheduling and timeout machinery with instrumentation before another rewrite.
- Commit/revert decision: reverted to E2.
- Next experiment: profile or instrument body-read pending/inline ratios and stream cleanup counts outside the stable benchmark, then choose a targeted change.

## E5: accepted-state verification

### Hypothesis Space Split
- Parent question: Does the retained patch set still improve the fresh hill after rejected E3/E4 code is removed?
- Hypothesis under test: E2 is the accepted implementation state.
- Rival hypotheses: the measured win was an artifact of rejected timeout experiments or run noise.
- Why this split is high value: confirms the final worktree state, not just an intermediate run.

### Prediction Before Run
- Expected primary metric movement: echo p99 should remain below E0 and near or better than E2.
- Expected secondary metric movement: root/post_user/static_1k guardrails should be near E0/E2, not the rejected E3 range.
- Distinguishing observation: target improvement plus healthy guardrails.
- Falsifier: echo returns to E0 or guardrails regress like E3.

### Attack
- Change or probe: final hill run after reverting E4.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id bouncy-cobalt-echo`
- Checks command: `nix develop -c dune runtest --profile release test/http_eio test/http_common`
- Controls held constant: same fresh hill facade and default pinned cores.

### Result
- Primary metric: `1.623181 ms`.
- Secondary metrics: echo p50 `0.139236 ms`, p95 `0.331453 ms`, p99 MAD `0.131571 ms`, echo rps `88456`; root/post_user/static_1k p99 `0.165266/0.202588/0.231001 ms`; geomean rps `150134`; success `1`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T01:26:44Z`.

### Verdict
- Verdict: corroborated
- Reason: final state improves E0 `1.889118 ms -> 1.623181 ms` while keeping guardrails in the healthy range.
- Hypothesis space update: request-body scheduling remains live; accepted E2 reduces command-loop work but does not solve the larger per-read timeout tail without guardrail tradeoffs.
- Commit/revert decision: keep E2, keep fresh hill setup.
- Next experiment: add temporary instrumentation outside the benchmark to count pending versus inline body reads and timeout sleeper lifetimes before trying another timeout rewrite.

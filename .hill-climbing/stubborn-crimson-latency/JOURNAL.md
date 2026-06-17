# Research Journal: stubborn-crimson-latency

## Hill

- Goal: reduce Eta H1-over-TLS broad-suite keep-alive p99, where initial TLS
  handshakes land near p99 for `n=1000`, `c=16`.
- Primary metric: `h1_tls_static_1k_p99_ms`.
- Direction: lower.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id stubborn-crimson-latency`
- Session directory: `.hill-climbing/stubborn-crimson-latency/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script. Do not remove workload, weaken checks, special-case benchmark inputs, cache invalidly, skip work, or trade away correctness unless the hill explicitly allows it.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h1_tls_static_1k_p99_ms` | Primary | lower | Keep only changes that improve beyond baseline/noise and pass checks. | Chosen because it was the highest absolute H1/TLS p99 in the user's broad pinned run. |
| `h1_tls_{root,user_id,post_user,echo_1k}_p99_ms` | Secondary | lower | Must not show endpoint-specific regression inconsistent with the real hill. | The broad symptom is endpoint-independent, so these should move together if the mechanism is shared TLS/accept work. |
| `h1_tls_*_p50_ms` | Secondary | lower | Large p50 regression rejects an apparent p99-only win. | Keeps steady-state request path honest. |
| `h1_tls_*_rps`, `h1_tls_rps_geomean` | Guard | higher | Major throughput regression rejects the change unless the p99 win is compelling and explained. | Prevents serializing or throttling work to hide tail latency. |
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
| H1 | Server-side TLS handshakes monopolize the H1/TLS accept/connection domain long enough to appear at p99. | Each new H1/TLS connection performs CPU-heavy OpenSSL handshake work in the same scheduler lane that will serve the first keep-alive request. | Moving handshakes off the main accept lane, parallelizing them, or making OpenSSL blocking sections more scheduler-friendly lowers all H1/TLS endpoint p99s together. | p99 does not change when handshake scheduling changes, or p99 remains endpoint-specific after handshake isolation. | open |
| H2 | The latency spike is mostly client/oha connection establishment accounting rather than Eta server scheduling. | oha includes TLS connect/handshake in the request latency distribution for the first wave. | Server-side changes have weak effect; changing workload shape to reuse pre-established H1/TLS connections removes the spike. | Server-side scheduling changes lower the broad p99 without changing oha semantics. | open |
| H3 | H1 connection/request loop work after handshake is causing the p99. | First request on a new H1/TLS flow pays parser/response setup or close/drain costs. | p50 or endpoint-specific body/static work moves with p99; plain H1 may show analogous but smaller tail. | H1/TLS p99 moves while H1 plain and steady-state p50 stay flat. | open |
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

## E0: Baseline

### Hypothesis Space Split
- Parent question: what mechanism puts H1/TLS requests near 15-18 ms p99?
- Hypothesis under test: baseline reproduction, no code change.
- Rival hypotheses: H1/H2/H3 all remain live.
- Why this split is high value: confirms the local facade measures the same
  endpoint-independent symptom reported from the broad suite.

### Prediction Before Run
- Expected primary metric movement: none.
- Expected secondary metric movement: all H1/TLS endpoint p99s cluster in the
  broad-suite range; p50 remains sub-millisecond.
- Distinguishing observation: endpoint-independent p99 with low p50 supports a
  handshake/connection setup hill over handler-specific work.
- Falsifier: only `static_1k` is slow, or p50 is also high.

### Attack
- Change or probe: created fixed H1/TLS probe workload, no library change.
- Benchmark command: `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id stubborn-crimson-latency`
- Checks command: `.hill-climbing/stubborn-crimson-latency/checks.sh`
- Controls held constant: release build, Eio posix backend, `n=1000`, `c=16`,
  median of 3, optional `taskset` pinning through `ETA_SERVER_LOAD_*`.

### Result
- Primary metric: `h1_tls_static_1k_p99_ms=15.337835`.
- Secondary metrics: root `17.818993`, user_id `15.691169`, post_user
  `17.219348`, echo_1k `17.064503`; p50s `0.094-0.198 ms`;
  `h1_tls_rps_geomean=29852`; `success=1`.
- Checks: pass.
- `log.jsonl` reference: run at `2026-06-15T00:21:06Z`.

### Verdict
- Verdict: corroborated.
- Reason: the symptom is reproduced locally and endpoint-independent.
- Hypothesis space update: H3 is weakened; H1/H2 remain the primary rivals.
- Commit/revert decision: keep hill scaffolding.
- Next experiment: inspect HTTPS accept/handshake scheduling and test whether
  moving TLS handshakes off the main listener lane lowers all endpoint p99s.

## E1: Domain Scheduling Discriminant

### Hypothesis Space Split
- Parent question: is the p99 dominated by server accept/handshake domain
  pressure?
- Hypothesis under test: H1, server-side TLS handshake scheduling.
- Rival hypotheses: H2, oha connection-establishment accounting; H3,
  post-handshake H1 work.
- Why this split is high value: `ETA_SERVER_DOMAINS` is an existing control
  that changes server handshake scheduling without changing H1 handlers.

### Prediction Before Run
- Expected primary metric movement: lower if server handshake scheduling is the
  bottleneck and domains get real cores.
- Expected secondary metric movement: all endpoints should move together.
- Distinguishing observation: p99 collapse with multi-domain server.
- Falsifier: p50/RPS improve but p99 remains in the setup band.

### Attack
- Change or probe: no code change; ran the hill with `ETA_SERVER_DOMAINS=8`
  under both single-core and multi-core server pinning.
- Benchmark command: `ETA_SERVER_DOMAINS=8 ... hill_climbing.py run --id stubborn-crimson-latency`
- Checks command: `.hill-climbing/stubborn-crimson-latency/checks.sh`
- Controls held constant: `n=1000`, `c=16`, median of 3.

### Result
- Primary metric: single-core domain run `22.868087 ms`; multi-core server pin
  run `19.017543 ms`.
- Secondary metrics: multi-core p50 improved sharply (`0.027-0.070 ms`) and RPS
  rose, but p99 stayed `18-19 ms`.
- Checks: pass.
- `log.jsonl` reference: runs at `2026-06-15T00:22:10Z` and
  `2026-06-15T00:22:20Z`.

### Verdict
- Verdict: rejected for the primary hill.
- Reason: server scheduling helped steady-state p50/RPS but did not remove the
  p99 setup band.
- Hypothesis space update: H1 is weakened; H2 is strengthened.
- Commit/revert decision: no code change.
- Next experiment: test whether moving connection setup below the p99 sample
  cutoff removes the symptom.

## E2: Request Count Falsifier

### Hypothesis Space Split
- Parent question: is p99 mostly the first 16 connection/TLS setup samples?
- Hypothesis under test: H2, oha is reporting setup latency as keep-alive p99.
- Rival hypotheses: H1/H3.
- Why this split is high value: changing only sample count predicts a large
  p99 drop if setup samples are the cause.

### Prediction Before Run
- Expected primary metric movement: drop from ~15 ms to sub-millisecond with
  `n=10000`, because 16 setup samples are below the top 1%.
- Expected secondary metric movement: all H1/TLS endpoints drop similarly.
- Distinguishing observation: p99 collapses without server code change.
- Falsifier: p99 remains in the 15 ms band at `n=10000`.

### Attack
- Change or probe: no code change; ran `ETA_H1TLS_REQUESTS=10000`.
- Benchmark command: `ETA_H1TLS_REQUESTS=10000 ... hill_climbing.py run --id stubborn-crimson-latency`
- Checks command: `.hill-climbing/stubborn-crimson-latency/checks.sh`
- Controls held constant: same probe, `c=16`, median of 3.

### Result
- Primary metric: `h1_tls_static_1k_p99_ms=0.354007`.
- Secondary metrics: root `0.187588`, user_id `0.186557`, post_user
  `0.191516`, echo_1k `0.405315`; `success=1`.
- Checks: pass.
- `log.jsonl` reference: run at `2026-06-15T00:24:48Z`.

### Verdict
- Verdict: corroborated.
- Reason: p99 collapsed without a server change once setup samples no longer
  occupied p99.
- Hypothesis space update: H2 becomes the working explanation; H1/H3 are not
  the broad-suite p99 cause.
- Commit/revert decision: no code change.
- Next experiment: avoid benchmark contamination in fixed-count keep-alive runs.

## E3: TLS Ticket Count

### Hypothesis Space Split
- Parent question: can server-side TLS policy reduce the initial setup band
  enough without changing benchmark semantics?
- Hypothesis under test: reducing TLS 1.3 ticket generation from OpenSSL's
  default to one ticket lowers the first-wave setup latency while preserving
  resumption.
- Rival hypotheses: setup latency is mostly client/oha accounting or total
  connection-establishment CPU, not ticket count.
- Why this split is high value: small localized TLS change with tests covering
  resumption.

### Prediction Before Run
- Expected primary metric movement: lower than baseline.
- Expected secondary metric movement: all endpoints improve or stay flat.
- Distinguishing observation: `static_1k` p99 improves without p50/RPS loss.
- Falsifier: primary is flat/worse or secondaries are mixed.

### Attack
- Change or probe: temporarily added `SSL_CTX_set_num_tickets(ctx, 1)` to the
  server context.
- Benchmark command: `hill_climbing.py run --id stubborn-crimson-latency`
- Checks command: `.hill-climbing/stubborn-crimson-latency/checks.sh`
- Controls held constant: `n=1000`, `c=16`, median of 3.

### Result
- Primary metric: `16.921747 ms` vs baseline `15.337835 ms`.
- Secondary metrics: mixed; root/user improved, static/echo worsened.
- Checks: pass.
- `log.jsonl` reference: run at `2026-06-15T00:25:52Z`.

### Verdict
- Verdict: rejected.
- Reason: primary regressed and secondary movement was mixed.
- Hypothesis space update: ticket count is not the hill.
- Commit/revert decision: reverted.
- Next experiment: implement benchmark request floor.

## E4: Fixed-Count Keep-Alive Request Floor

### Hypothesis Space Split
- Parent question: how should broad server-load report keep-alive p99?
- Hypothesis under test: fixed-count runs need enough requests per connection
  so connection setup is below the p99 sample cutoff.
- Rival hypotheses: keep `n=1000,c=16` and accept that p99 measures setup.
- Why this split is high value: it directly fixes the broad-suite symptom while
  preserving concurrency and endpoint work.

### Prediction Before Run
- Expected primary metric movement: sub-millisecond p99 in the corrected hill.
- Expected secondary metric movement: all H1/TLS endpoint p99s sub-millisecond.
- Distinguishing observation: actual `server_load` rows record adjusted request
  counts and H1/TLS c=16 medians no longer sit in the 15 ms band.
- Falsifier: broad `eta_h1_tls c=16` still reports setup-band p99.

### Attack
- Change or probe: added a `200 * connections` request floor for fixed-count
  server-load cases with base request count >= 1000, and recorded the effective
  request count per result row.
- Benchmark command: `hill_climbing.py run --id stubborn-crimson-latency`
- Checks command: `.hill-climbing/stubborn-crimson-latency/checks.sh`
- Controls held constant: concurrency, endpoints, oha flags, repeats.

### Result
- Primary metric: `h1_tls_static_1k_p99_ms=0.405797`.
- Secondary metrics: root `0.435404`, user_id `0.354950`, post_user
  `0.313481`, echo_1k `0.455123`; `success=1`.
- Checks: pass.
- Broad validation:
  `nix develop -c dune exec --profile release http-testsuite/test/server_load/run.exe -- --quick --eta-only --h1-only --out http-testsuite/results/manual-server-load-20260615-h1tls-steady-p99`.
  H1/TLS c=16 medians: root `0.275 ms`, user_id `0.441 ms`, post_user
  `0.303 ms`, static_1k `0.388 ms`, echo_1k `0.468 ms`; result rows record
  `requests=3200`.
- `log.jsonl` reference: run at `2026-06-15T00:27:06Z`.

### Verdict
- Verdict: corroborated.
- Reason: the broad symptom disappears when keep-alive p99 is measured with
  enough samples to keep setup below p99.
- Hypothesis space update: H2 accepted as the cause of the reported symptom.
- Commit/revert decision: keep.
- Next experiment: full test suite, then hand off with the caveat that this is
  a measurement fix, not a faster fresh-handshake implementation.

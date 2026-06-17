# Research Journal: h1-tls-echo-1k-tail-20260615

## Hill

- Goal: determine whether H1 TLS `/echo` with a 1 KiB body is a stable,
  Eta-owned p99 hill after excluding H2 shapes already attributed to
  socket/readiness/client timing.
- Primary metric: `h1_tls_echo_1k_p99_us`.
- Direction: lower is better.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h1-tls-echo-1k-tail-20260615`
- Session directory: `.hill-climbing/h1-tls-echo-1k-tail-20260615/`

## Anti-Gaming Contract

The goal is to improve the real hill, not merely to improve the measured script.
Do not remove workload, weaken checks, special-case benchmark inputs, cache
invalidly, skip work, bypass TLS, disable keep-alive, or trade away correctness.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h1_tls_echo_1k_p99_us` | Primary | lower | Keep changes only when repeated runs move this down beyond noise and checks pass. | H1 TLS `/echo`, 1 KiB request/response body, c=16, 16 keep-alive connections. |
| `h1_echo_1k_success` | Correctness gate | higher | Must remain `1.0`. Reject any change that lowers it. | Verifies HTTP 200, error count, success rate, and response bytes. |
| `h1_plain_echo_1k_p99_us` | Guard / classifier | lower / no regression | Reject TLS wins that break plain H1 echo unless attribution proves independence. | Separates TLS overhead from generic H1 echo/body path. |
| `h1_tls_static_1k_p99_us` | Guard / classifier | lower / no regression | Reject echo wins that regress static 1 KiB. | Separates request-body echo from response-body writes. |
| `h1_tls_root_p99_us` | Guard / classifier | lower / no regression | Reject body wins that regress tiny TLS responses. | Catches generic TLS/H1 scheduling regressions. |
| `h1_tls_post_user_p99_us` | Guard / classifier | lower / no regression | Reject echo wins that regress request-body handling without response body. | Helps isolate request read vs response write. |
| `h1_tls_user_id_p99_us` | Guard / classifier | lower / no regression | Reject wins that regress dynamic tiny body responses. | Helps catch handler/header path regressions. |
| `h1_tls_rps_geomean` | Throughput guard | higher / no material regression | Reject p99 wins that trade away meaningful throughput without evidence. | Geomean across TLS endpoints and repeats. |

Noise policy:

- Establish baseline variance before trusting small wins.
- Use 24k requests x 9 repeats by default and compare median repeat p99.
- Treat changes inside the noise floor as inconclusive unless they simplify code
  or improve a secondary constraint without hurting the primary metric.

## Hypothesis Space

Root question:

> What mechanism currently limits H1 TLS echo_1k p99?

Maintain a partition of plausible explanations. Keep `H_other` for residual
uncertainty until a better split replaces it.

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Broad-suite artifact | H1 TLS echo p99 is not stable under higher repeats/request count. | Baseline repeats vary widely and primary is not clearly worse than guards. | 24k x 9 baseline is stable and echo remains the top H1 TLS case. | open |
| H2 | TLS write/flush overhead dominates | TLS record emission or flush behavior hurts 1 KiB echo more than plain H1. | TLS echo is much worse than plain echo and TLS static/root shape points at writes. | Plain echo has similar p99, or TLS tiny/static guards show no related tail. | open |
| H3 | Request-body echo path dominates | H1 request-body read/copy or echo response construction creates tail. | Echo is worse than static 1 KiB and post_user, and body instrumentation correlates with p99. | Static/post/tiny endpoints share the same tail or body spans are micro-scale. | open |
| H4 | Keep-alive/socket scheduling dominates | c=16 keep-alive connection scheduling or kernel readiness creates outliers. | Endpoint-independent tails appear across H1 plain/TLS cases and move with pinning/client shape. | Endpoint-specific instrumentation puts the missing p99 inside Eta H1/TLS code. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it | A better split replaces it | open |

## Experiment Selection Rule

Choose experiments by expected elimination power:

- Prefer experiments where live hypotheses predict different observations.
- Prefer cheap falsifiers before expensive rewrites.
- Prefer instrumentation when current hypotheses are indistinguishable.
- Reject or narrow hypotheses when their falsifiers fire.
- Split broad hypotheses when results are inconclusive.
- Keep changes only when they improve the hill and preserve checks.

## Running Log

Append completed entries below. Keep entries concise, falsifiable, and useful to
a fresh agent.

## E1: Setup Baseline

### Hypothesis Space Split
- Parent question: after excluding attributed H2 socket-sensitive shapes, is H1
  TLS echo_1k a stable Eta-owned hill?
- Hypothesis under test: H1 TLS echo_1k broad-suite p99 is only a noisy
  artifact.
- Rival hypotheses: TLS write/flush overhead, H1 request-body echo path, or
  keep-alive/socket scheduling creates a stable p99 gap.
- Why this split is high value: the broad rerank showed H1 TLS echo_1k at the
  top of the remaining non-H2 cluster, but the three broad repeats had one high
  outlier.

### Prediction Before Run
- Expected primary metric movement: none; this is baseline setup.
- Expected secondary metric movement: none.
- Distinguishing observation: if this is worth climbing, 24k x 9 should keep H1
  TLS echo above TLS static/tiny endpoints with reasonable repeat stability.
- Falsifier: primary collapses into the guard cluster or repeats remain too
  noisy to distinguish.

### Attack
- Change or probe: created `.hill-climbing/h1-tls-echo-1k-tail-20260615/`
  with a pinned H1 plain/TLS endpoint matrix. Primary is H1 TLS `/echo`, 1 KiB
  request/response body, c=16, 16 keep-alive connections, 24k requests x 9
  repeats.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-tls-echo-1k-tail-20260615`
- Checks command:
  `bash .hill-climbing/h1-tls-echo-1k-tail-20260615/checks.sh`
- Controls held constant: same Eta H1 probes used by server-load, pinned server
  and load cores, fixed request count/repeats, identical endpoint set across
  plain and TLS.

### Result
- Primary metric: `h1_tls_echo_1k_p99_us=389.124us`.
- Primary repeats:
  `[409.282, 405.946, 380.828, 389.124, 348.035, 383.633, 374.336, 452.806, 491.309]`.
- Secondary metrics:
  - `h1_plain_echo_1k_p99_us=315.563us`.
  - `h1_tls_static_1k_p99_us=213.949us`.
  - `h1_tls_post_user_p99_us=175.516us`.
  - `h1_tls_root_p99_us=172.710us`.
  - `h1_tls_user_id_p99_us=158.733us`.
  - `h1_tls_echo_1k_to_plain_p99_ratio=1.233`.
  - `h1_tls_rps_geomean=114021.598`.
  - `h1_echo_1k_success=1.0`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T12:54:38Z`, primary `389.124`.
  Summary TSV:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/results/20260615-145411/h1-tls-echo-summary.tsv`.

### Verdict
- Verdict: broad-artifact hypothesis rejected; hill corroborated.
- Reason: the broad-suite `579us` was high, but the isolated hill still shows a
  stable H1 TLS echo p99 around `389us`. Echo remains clearly above TLS static
  and tiny dynamic endpoints. The gap is not purely TLS-specific because H1
  plain echo is also elevated at `316us`.
- Hypothesis space update: keep H2 socket-sensitive work out of this hill. The
  next split should separate request-body echo work from generic 1 KiB response
  writes and TLS flush behavior.
- Commit/revert decision: keep hill setup.
- Next experiment: add H1 echo attribution for request body read, response body
  write/flush, and TLS/plain delta before attempting production changes.

## E2: H1 Echo Phase Attribution

### Hypothesis Space Split
- Parent question: does H1 TLS echo_1k p99 live in request-body echo handling,
  TLS/response write, or client/socket scheduling?
- Hypothesis under test: the H1 request-body echo path dominates the primary
  p99.
- Rival hypotheses: TLS response write/flush dominates, or the custom client
  observes extra post-write scheduling that should not be optimized in Eta
  server code.
- Why this split is high value: echo is worse than H1 TLS static/tiny endpoints
  in the official hill, but H1 plain echo is also elevated, so optimizing copies
  without attribution would be speculative.

### Prediction Before Run
- Expected primary metric movement: none; instrumentation only.
- Expected secondary metric movement: none.
- Distinguishing observation: if request-body echo dominates, handler
  request-body-read or handler total p99 should be close to the primary p99 and
  much worse than static 1 KiB.
- Falsifier: handler/body spans remain micro-scale while response/TLS write spans
  explain the server-side tail.

### Attack
- Change or probe: added env-gated H1 phase tracing under
  `ETA_H1_PHASE_TRACE_PATH`, generic testsuite echo tracing under
  `ETA_HTTP_ECHO_TRACE_PATH`, and a hill-local custom H1 keep-alive client:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_echo_custom_client.sh`.
- TLS echo command:
  `ETA_H1_ECHO_TRACE_REQUESTS=4096 ETA_SERVER_LOAD_LOAD_CORE=3-6 bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_echo_custom_client.sh`
- Plain echo command:
  `ETA_H1_ECHO_TRACE_REQUESTS=4096 ETA_H1_ECHO_TRACE_MODE=plain ETA_SERVER_LOAD_LOAD_CORE=3-6 bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_echo_custom_client.sh`
- TLS static command:
  `ETA_H1_ECHO_TRACE_REQUESTS=4096 ETA_H1_ECHO_TRACE_MODE=tls ETA_H1_ECHO_TRACE_METHOD=GET ETA_H1_ECHO_TRACE_BODY_BYTES=0 ETA_H1_ECHO_TRACE_PATH=/static/1k.bin ETA_H1_ECHO_TRACE_EXPECTED_BYTES=1024 ETA_SERVER_LOAD_LOAD_CORE=3-6 bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_echo_custom_client.sh`
- Checks command:
  `bash .hill-climbing/h1-tls-echo-1k-tail-20260615/checks.sh`
- Official hill command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-tls-echo-1k-tail-20260615`
- Controls held constant: same 16 keep-alive connection shape, 1 KiB echo/static
  bodies, no production optimization, trace env disabled for official hill run.

### Result
- TLS echo trace:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/custom-client-results/20260615-150103`
  - `success=1`, `phase_joined=4096`, `phase_missing=0`.
  - `handler_request_body_read_us_p99=3us`.
  - `handler_us_p99=11us`.
  - `response_write_us_p99=394us`.
  - `tls_raw_write_p99_us=390us`.
  - `t1_to_write_complete_us_p99=665us`.
  - Custom-client `total_us_p99=2067us`; the excess is mostly
    `flow_complete_to_rx_headers_us_p99=1641us`, so custom-client total p99 is
    not the optimization target.
- Plain echo trace:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/custom-client-results/20260615-150125`
  - `success=1`, `phase_joined=4096`, `phase_missing=0`.
  - `handler_request_body_read_us_p99=3us`.
  - `handler_us_p99=10us`.
  - `response_write_us_p99=247us`.
  - `t1_to_write_complete_us_p99=463us`.
- TLS static 1 KiB trace:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/custom-client-results/20260615-150143`
  - `success=1`, `phase_joined=4096`, `phase_missing=0`.
  - `handler_us_p99=6us`.
  - `response_write_us_p99=507us`.
  - `tls_raw_write_p99_us=500us`.
  - `t1_to_write_complete_us_p99=685us`.
- Official hill run after instrumentation, tracing disabled:
  - `h1_tls_echo_1k_p99_us=362.521us`.
  - `h1_plain_echo_1k_p99_us=321.603us`.
  - `h1_tls_static_1k_p99_us=233.145us`.
  - `h1_tls_root_p99_us=193.970us`.
  - `h1_echo_1k_success=1.0`.
  - Checks passed.

### Verdict
- Verdict: request-body echo hypothesis rejected; TLS/response-write hypothesis
  corroborated.
- Reason: handler body read and handler total are micro-scale compared with the
  primary p99. Server-side p99 in the custom traces is dominated by
  response-write/TLS raw write, and static 1 KiB shows the same or higher write
  p99 without request-body echo work. The custom client has large post-write
  receive gaps, so its total p99 should not drive production changes; use the
  server phase split and official hill facade instead.
- Hypothesis space update: stop chasing echo body/copy. Split the next
  experiment between TLS/Eio backend write scheduling and generic H1 1 KiB
  response-write behavior.
- Commit/revert decision: keep env-gated attribution instrumentation and helper.
  No production optimization was made.
- Next experiment: run the official hill under `EIO_BACKEND=posix` as a
  backend-sensitivity classifier. If posix collapses TLS write p99, the hill is
  runtime/backend scheduling. If not, inspect TLS write/drain behavior for a
  minimal production fix.

## E3: Posix Backend Classifier

### Hypothesis Space Split
- Parent question: is the H1 TLS echo p99 primarily an io_uring/default-backend
  scheduling artifact?
- Hypothesis under test: running the official hill with `EIO_BACKEND=posix`
  collapses the primary p99 or materially improves the TLS write-heavy guards.
- Rival hypotheses: the p99 is generic H1 request/response timing, TLS write
  behavior independent of backend choice, or benchmark-client upload/accounting
  around echo requests.
- Why this split is high value: E2 showed response/TLS write spans dominate the
  server-side trace, but the previous H2 hills had strong backend/pinning
  sensitivity. This cheap classifier prevents a premature TLS rewrite.

### Prediction Before Run
- Expected primary metric movement: lower if the default backend is the culprit.
- Expected secondary metric movement: TLS static/root/post should improve or at
  least not regress if backend scheduling is the shared root cause.
- Distinguishing observation: a clear primary p99 drop with acceptable guards.
- Falsifier: primary or throughput regresses under posix.

### Attack
- Change or probe: no code change; ran the official hill facade with
  `EIO_BACKEND=posix`.
- Benchmark command:
  `EIO_BACKEND=posix python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-tls-echo-1k-tail-20260615`
- Checks command: runner check gate.
- Controls held constant: official 24k x 9 H1 plain/TLS endpoint matrix, same
  correctness checks, trace env disabled.

### Result
- Primary metric: `h1_tls_echo_1k_p99_us=426.513us`, worse than the current
  default-backend run `362.521us` and baseline `389.124us`.
- Secondary metrics:
  - `h1_plain_echo_1k_p99_us=401.045us`, worse than default `321.603us`.
  - `h1_tls_static_1k_p99_us=247.963us`, worse than default `233.145us`.
  - `h1_tls_root_p99_us=198.328us`, similar/worse than default `193.970us`.
  - `h1_tls_rps_geomean=88823.206`, lower than default `94970.386`.
  - `h1_echo_1k_success=1.0`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T13:06:15Z`, primary `426.513`.

### Verdict
- Verdict: posix-backend hypothesis rejected.
- Reason: posix did not collapse the p99; it worsened primary, plain echo,
  static TLS, and throughput. The default backend remains the better measured
  configuration for this hill.
- Hypothesis space update: backend choice is not the next production lever.
  E2's server-side traces still show response/TLS write as the largest
  Eta-owned segment, but static 1 KiB is similarly write-heavy while official
  echo remains higher than static. That leaves a live measurement/client-upload
  rival for the echo-specific gap.
- Commit/revert decision: no production change.
- Next experiment: split official echo-vs-static with a second client or
  oha-shape probe that preserves upload accounting but records server phases.
  Only optimize TLS/H1 write code if that probe puts the echo-specific gap
  inside server write behavior rather than client upload/accounting.

## E4: Oha-Shaped Echo/Static/Upload Phase Split

### Hypothesis Space Split
- Parent question: in the official oha shape, is H1 TLS echo worse than static
  because of Eta-owned echo work, generic 1 KiB response writes, or POST/upload
  readiness effects?
- Hypothesis under test: the echo-specific gap is inside Eta server echo work or
  response write code and is worth production optimization.
- Rival hypotheses: oha/client upload accounting and socket readiness around
  POST bodies explain the echo-specific gap; generic TLS/static write p99 is a
  separate lower-priority hill.
- Why this split is high value: E2's custom client had post-write receive gaps,
  so an oha-shaped phase trace is needed before treating the official primary as
  server-owned latency.

### Prediction Before Run
- Expected primary metric movement: none; attribution only.
- Expected secondary metric movement: none.
- Distinguishing observation: if echo-specific latency is Eta-owned, oha-shaped
  server phases should show echo handler/body or response-write p99 far above
  static.
- Falsifier: echo/static oha p99s are close, handler/body read is micro-scale,
  or upload-only POST creates larger stalls than echo.

### Attack
- Change or probe: added
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`.
  It runs oha against traced H1 probes, one endpoint per server process, and
  reports oha p99 beside H1 phase, echo-handler, and TLS raw I/O distributions.
- TLS echo/static command:
  `bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`
- Plain echo/static command:
  `ETA_H1_OHA_TRACE_MODE=plain bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`
- TLS upload-only command:
  `ETA_H1_OHA_TRACE_MODE=tls ETA_H1_OHA_TRACE_ENDPOINTS=post_user_1k bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`
- Plain upload-only command:
  `ETA_H1_OHA_TRACE_MODE=plain ETA_H1_OHA_TRACE_ENDPOINTS=post_user_1k bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`
- Checks command:
  `bash .hill-climbing/h1-tls-echo-1k-tail-20260615/checks.sh`
- Controls held constant: oha, c=16, 24k requests, keep-alive, same H1 probes,
  trace env enabled only for attribution.

### Result
- TLS echo/static oha-shaped trace:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/oha-phase-results/20260615-151055`
  - TLS echo: `oha_p99=541.584us`, `server_request_p99=338us`,
    `response_write_p99=320us`, `tls_raw_write_p99=320us`,
    `handler_request_body_read_p99=2us`.
  - TLS static: `oha_p99=530.252us`, `server_request_p99=259us`,
    `response_write_p99=239us`, `tls_raw_write_p99=256us`.
  - Both joined all `24000` phase rows and passed success checks.
- Plain echo/static oha-shaped trace:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/oha-phase-results/20260615-151108`
  - Plain echo: `oha_p99=414.441us`, `server_request_p99=285us`,
    `response_write_p99=269us`, `handler_request_body_read_p99=2us`.
  - Plain static: `oha_p99=317.256us`, `server_request_p99=160us`,
    `response_write_p99=150us`.
  - Both joined all `24000` phase rows and passed success checks.
- Upload-only POST `/user` with a 1 KiB body and empty response:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/oha-phase-results/20260615-151140`
  - TLS: `oha_p99=8438.379us`, `server_request_p99=6553us`,
    `response_write_p99=6531us`, `tls_raw_write_p99=6520us`,
    `handler_us_p99=3us`, `request_head_read_p99=4174us`.
  - Plain: `oha_p99=8230.502us`, `server_request_p99=1696us`,
    `response_write_p99=874us`, `handler_us_p99=4us`,
    `request_head_read_p99=6462us`.
  - Both joined all `24000` phase rows and passed success checks.
- Checks: passed.

### Verdict
- Verdict: echo-specific production optimization rejected for now.
- Reason: in the oha-shaped trace, H1 TLS echo and static 1 KiB have nearly the
  same oha p99, and echo's server-side premium over static is only around
  `79us` in TLS (`338us` vs `259us` server request p99). Body read stays at
  `2us`. The upload-only 1 KiB POST creates far larger request-head and
  write/readiness tails with micro-scale handler work, proving that POST upload
  shape can dominate the apparent gap without implicating echo copying.
- Hypothesis space update: do not optimize echo handler/body/copy. Treat H1
  echo p99 as upload/readiness-sensitive measurement plus a smaller generic H1
  1 KiB response-write component. The next hill should move away from echo and
  target the next stable non-upload case, likely H1 TLS static/root or a fresh
  broad rerank after excluding H2 socket-sensitive and H1 upload-sensitive
  cases.
- Commit/revert decision: keep the oha-shaped attribution helper; no production
  optimization was made.
- Next experiment: rerank actionable cases with H2 socket-sensitive and H1
  upload-sensitive cases excluded, then set up the next hill from the remaining
  stable p99 cluster.

## E5: Clean Rerank After Upload Exclusion

### Hypothesis Space Split
- Parent question: after rejecting H1 echo-specific optimization, what is the
  next clean hill?
- Hypothesis under test: H1 TLS echo remains the correct hill after excluding
  known measurement/upload effects.
- Rival hypotheses: a non-upload H1 TLS endpoint cluster is now the next stable
  Eta-owned hill.
- Why this split is high value: continuing to optimize echo would overfit an
  upload-sensitive measurement shape; the next hill should come from a clean
  ranking.

### Prediction Before Run
- Expected primary metric movement: none; rerank only.
- Expected secondary metric movement: none.
- Distinguishing observation: a stable non-upload endpoint should lead the clean
  ranking.
- Falsifier: all remaining cases are noisy or already attributed outside Eta
  server behavior.

### Attack
- Change or probe: ran a fresh Eta-only quick server-load rerank.
- Benchmark command:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --out http-testsuite/results/manual-server-load-20260615-clean-rerank`
- Post-processing exclusions:
  - H2 c=16 shapes with `(connections, streams)` in `(16,1)`, `(4,4)`,
    `(1,16)`, already attributed to socket/readiness/client timing.
  - H1 `echo_1k`, attributed here to upload-sensitive timing rather than echo
    copy work.
- Controls held constant: server-load quick profile, median-of-3 repeats.

### Result
- Clean top cases:
  - H1 TLS `static_1k`, c=16: `369.715us`, repeats
    `[369.715, 461.451, 368.704]`.
  - H1 TLS `post_user`, c=16: `360.148us`, repeats
    `[374.936, 340.420, 360.148]`.
  - H1 TLS `user_id`, c=16: `327.205us`, repeats
    `[327.205, 342.334, 308.570]`.
  - H1 TLS `root`, c=16: `306.425us`, repeats
    `[303.660, 306.425, 2848.749]`.
  - H1 plain `static_1k`, c=16: `280.555us`, repeats
    `[280.555, 1820.265, 275.857]`.
- Result file:
  `http-testsuite/results/manual-server-load-20260615-clean-rerank/server_load.json`.

### Verdict
- Verdict: H1 echo hill retired; new hill needed.
- Reason: after excluding upload-sensitive echo and known H2 socket-sensitive
  cases, the leading stable cluster is H1 TLS non-upload at c=16. `static_1k`
  is the top clean p99 and is close to `post_user`/`user_id`, suggesting a
  generic H1 TLS small-response/write/scheduling hill rather than an endpoint
  handler hill.
- Hypothesis space update: stop this hill's production climb. Preserve its
  attribution helpers for future diagnosis, but do not optimize against
  `h1_tls_echo_1k_p99_us` without new evidence.
- Commit/revert decision: no production change.
- Next experiment: create a new H1 TLS non-upload hill with primary
  `h1_tls_static_1k_p99_us` and guards for H1 TLS `post_user`, `user_id`,
  `root`, H1 plain `static_1k`, throughput, and success.

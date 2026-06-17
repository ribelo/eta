# Research Journal: h1-tls-nonupload-tail-20260615

## Hill

- Goal: improve the next clean Eta HTTP p99 hill after excluding H2
  socket-sensitive shapes and H1 upload-sensitive echo.
- Primary metric: `h1_tls_static_1k_p99_us`.
- Direction: lower is better.
- Benchmark facade: `python <SKILL_DIR>/scripts/hill_climbing.py run --id h1-tls-nonupload-tail-20260615`
- Session directory: `.hill-climbing/h1-tls-nonupload-tail-20260615/`

## Anti-Gaming Contract

Do not remove workload, weaken checks, bypass TLS, disable keep-alive, reduce
request count, special-case static files, cache invalidly, or improve the
primary by regressing the non-upload H1 TLS cluster.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h1_tls_static_1k_p99_us` | Primary | lower | Keep changes only when repeated runs move this down beyond noise and checks pass. | H1 TLS static 1 KiB, c=16, 16 keep-alive connections. |
| `h1_tls_nonupload_success` | Correctness gate | higher | Must remain `1.0`. | Verifies HTTP 200, no errors, and response bytes. |
| `h1_tls_post_user_p99_us` | Guard | lower / no regression | Reject changes that hurt this without attribution. | Empty POST response, no upload body. |
| `h1_tls_user_id_p99_us` | Guard | lower / no regression | Reject changes that hurt this without attribution. | Tiny dynamic response. |
| `h1_tls_root_p99_us` | Guard | lower / no regression | Reject changes that hurt this without attribution. | Empty tiny response. |
| `h1_plain_static_1k_p99_us` | Guard / classifier | lower / no regression | Separates TLS-specific from generic H1 static behavior. | Plain H1 static 1 KiB. |
| `h1_tls_nonupload_p99_geomean_us` | Cluster guard | lower / no regression | Reject static-only wins that hurt the cluster. | Geomean over TLS root/user/post/static p99. |
| `h1_tls_rps_geomean` | Throughput guard | higher / no material regression | Reject p99 wins that trade away meaningful throughput without evidence. | Geomean across TLS non-upload cases and repeats. |

## Hypothesis Space

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | TLS write/flush overhead dominates | TLS raw write/drain path adds p99 to small/fixed responses. | TLS static p99 is worse than plain static, and phase traces show write spans dominating. | Plain static is similarly bad or server write spans stay micro-scale. | open |
| H2 | Generic H1 response-write scheduling dominates | H1 write path or Eio scheduling adds p99 independent of TLS. | Plain and TLS static move together, and response-write phases dominate both. | TLS-only overhead explains the gap. | open |
| H3 | Measurement/client artifact dominates | oha/client receive or connection scheduling accounts for most p99. | Server phases are much lower than oha p99 and move with pinning/client shape. | Server phase p99 matches observed p99. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it | A better split replaces it | open |

## Running Log

Append completed entries below. Keep entries concise, falsifiable, and useful to
a fresh agent.

## E1: Setup Baseline

### Hypothesis Space Split
- Parent question: after retiring H2 socket-sensitive shapes and H1 upload/echo
  artifacts, is H1 TLS non-upload latency still a stable, server-owned hill?
- Hypothesis under test: the quick-rerank H1 TLS static/post/user/root cluster
  is a real hill worth attributing under higher request count and repeats.
- Rival hypotheses: quick-rerank noise, generic H1 scheduling shared by plain
  and TLS, TLS-specific write/flush overhead, or oha/client accounting.
- Why this split is high value: the candidate p99 values are now sub-ms, so a
  production change is not justified until the benchmark proves a stable and
  Eta-owned gap.

### Prediction Before Run
- Expected primary metric movement: none; this is baseline setup.
- Expected secondary metric movement: none.
- Distinguishing observation: if this is worth climbing, TLS static should
  remain above plain static and the TLS non-upload cluster should be stable
  across 24k requests x 9 repeats.
- Falsifier: primary collapses into noise, success fails, or plain/static tails
  explain nearly all of the observed p99.

### Attack
- Change or probe: created `.hill-climbing/h1-tls-nonupload-tail-20260615/`
  with a pinned H1 plain/TLS matrix over root, user_id, post_user, and
  static_1k. Primary is H1 TLS static_1k p99 at c=16, 24k requests x 9 repeats.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-tls-nonupload-tail-20260615`
- Checks command:
  `bash .hill-climbing/h1-tls-nonupload-tail-20260615/checks.sh`
- Controls held constant: same H1 probes used by server-load, pinned server and
  load cores, same request count/repeats across plain and TLS, no endpoint body
  upload for this hill.

### Result
- Primary metric: `h1_tls_static_1k_p99_us=247.823us`.
- Primary repeats:
  `[254.105, 247.823, 259.415, 238.315, 249.166, 353.254, 239.708, 228.938, 245.189]`.
- Secondary metrics:
  - `h1_plain_static_1k_p99_us=203.138us`.
  - `h1_tls_static_to_plain_p99_ratio=1.220`.
  - `h1_tls_root_p99_us=184.322us`.
  - `h1_tls_user_id_p99_us=189.863us`.
  - `h1_tls_post_user_p99_us=253.073us`.
  - `h1_tls_nonupload_p99_geomean_us=216.447us`.
  - `h1_tls_rps_geomean=99660.949`.
  - `h1_tls_nonupload_success=1.0`.
- Checks: passed.
- `log.jsonl` reference: run at `2026-06-15T13:18:22Z`, primary `247.823`.
  Summary TSV:
  `.hill-climbing/h1-tls-nonupload-tail-20260615/results/20260615-151756/h1-tls-nonupload-summary.tsv`.

### Verdict
- Verdict: keep as an attribution hill; do not optimize production code yet.
- Reason: the p99 cluster is stable enough to measure, and TLS static is about
  `45us` above plain static at p99. The isolated result is much lower than the
  earlier quick-rerank estimate, so expected upside is modest unless phase
  traces put the p99.9/max spikes inside Eta-owned write/TLS spans.
- Hypothesis space update: H1/H2 body-copy explanations are not relevant here.
  The next split should compare oha-observed p99 with H1 phase and TLS write
  spans for static/root/user/post.
- Commit/revert decision: keep hill setup.
- Next experiment: run oha-shaped H1 phase tracing for TLS non-upload endpoints
  and compare server write/TLS spans against client-observed p99.

## E2: H1 Phase Attribution

### Hypothesis Space Split
- Parent question: is the H1 TLS non-upload p99 gap inside Eta's server write/TLS
  path, generic H1 write scheduling, or outside the server?
- Hypothesis under test: TLS write/flush overhead dominates the primary p99.
- Rival hypotheses: generic H1 response-write scheduling dominates, or oha/client
  accounting creates the apparent tail after the server finishes the request.
- Why this split is high value: E1 showed only a `~45us` TLS-over-plain p99 delta
  in the official hill, so the next step should distinguish a small real TLS
  cost from measurement noise before any production change.

### Prediction Before Run
- Expected primary metric movement: none; instrumentation only.
- Expected secondary metric movement: none.
- Distinguishing observation: if TLS write dominates, TLS server request and
  raw write p99 should be materially higher than plain H1 for the same endpoints.
- Falsifier: plain and TLS server spans are equivalent, or server p99 is far
  below the official client-observed p99.

### Attack
- Change or probe: reused the oha-shaped H1 phase helper from the retired H1 echo
  hill with endpoints `static_1k root user_id post_user`.
- TLS command:
  `ETA_H1_OHA_TRACE_ENDPOINTS='static_1k root user_id post_user' ETA_H1_OHA_TRACE_MODE=tls bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`
- Plain command:
  `ETA_H1_OHA_TRACE_ENDPOINTS='static_1k root user_id post_user' ETA_H1_OHA_TRACE_MODE=plain bash .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh`
- Controls held constant: 24k requests, c=16, same oha shape, same H1 probes,
  tracing enabled only for attribution runs and not for the official hill metric.

### Result
- TLS trace directory:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/oha-phase-results/20260615-151921`
- Plain trace directory:
  `.hill-climbing/h1-tls-echo-1k-tail-20260615/oha-phase-results/20260615-151939`
- Key TLS rows:
  - `static_1k`: oha p99 `525.133us`, server request p99 `237us`,
    response write p99 `225us`, TLS raw write p99 `231us`.
  - `root`: oha p99 `415.233us`, server request p99 `198us`,
    response write p99 `190us`, TLS raw write p99 `197us`.
  - `user_id`: oha p99 `389.534us`, server request p99 `166us`,
    response write p99 `160us`, TLS raw write p99 `171us`.
  - `post_user`: oha p99 `442.115us`, server request p99 `199us`,
    response write p99 `190us`, TLS raw write p99 `200us`.
- Key plain rows:
  - `static_1k`: oha p99 `389.063us`, server request p99 `163us`,
    response write p99 `152us`.
  - `root`: oha p99 `232.524us`, server request p99 `95us`,
    response write p99 `90us`.
  - `user_id`: oha p99 `243.114us`, server request p99 `110us`,
    response write p99 `100us`.
  - `post_user`: oha p99 `278.612us`, server request p99 `140us`,
    response write p99 `131us`.
- Success: all traced cases reported `success=1`.

### Verdict
- Verdict: TLS write/flush cost is real but small; measurement/client tail is
  also present in traced oha runs.
- Reason: TLS server request p99 is consistently higher than plain by roughly
  `60-100us`, and TLS raw write p99 tracks response write p99 closely. However,
  traced oha p99 is much higher than server request p99, and the official E1
  primary (`247.823us`) is close to the TLS static server p99 (`237us`) rather
  than the traced oha p99 (`525us`). That means the official hill is likely
  server/TLS-write owned at p99, while the trace run itself adds or exposes
  extra client-side tail.
- Hypothesis space update: keep H1 as a possible small optimization target, but
  downgrade its expected payoff. H3 remains live for the trace-run oha tail but
  no longer explains the official E1 primary. H2 is partly live because plain H1
  write p99 is nonzero, but TLS adds a consistent increment.
- Commit/revert decision: keep instrumentation and hill setup; no production
  optimization yet.
- Next experiment: inspect H1/TLS write behavior for avoidable per-response
  flushes or extra small writes. Only change production code if there is a
  simple invariant-preserving reduction that moves the official hill beyond
  noise and keeps the non-upload cluster/rps guards intact.

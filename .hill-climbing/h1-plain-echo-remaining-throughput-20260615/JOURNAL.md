# Research Journal: h1-plain-echo-remaining-throughput-20260615

## Hill

- Goal: improve the remaining Eta H1 plain `echo_1k` throughput versus Go under
  `c=16`, after the fixed-body initial-buffer allocation/copy improvements
  already found by the earlier H1 hill.
- Primary metric: `h1_plain_echo_1k_eta_go_rps_ratio`
- Direction: higher
- Benchmark facade:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-remaining-throughput-20260615`
- Session directory: `.hill-climbing/h1-plain-echo-remaining-throughput-20260615/`

## Prior Art

The earlier session `.hill-climbing/h1-plain-echo-1k-throughput-20260615/`
established that the broad `0.70x` RPS symptom was real under a focused
24k-request x9-repeat H1 plain echo benchmark:

- Baseline Eta/Go echo RPS ratio: `0.616682`.
- After avoiding a second full pending-body copy: `0.632132`.
- After lazy fixed-body scratch allocation: repeated at `0.818228` and
  `0.805623`.
- Eta echo p99 improved from about `350us` to about `175us`, while Go p99 stayed
  around `445us`.
- Static 1 KiB was faster than Go, so generic 1 KiB response write was rejected.
- Handler phase p99 stayed around `5us`, so high-level echo handler work was
  rejected.

This new hill should not re-litigate those accepted wins. It starts from the
current tree and asks whether the remaining gap has a clear, code-owned owner.

## Anti-Gaming Contract

Improve the real H1 plain echo path only. Do not remove workload, reduce request
bytes, weaken status or body validation, special-case `/echo`, special-case a
1 KiB body, detect Go or oha, cache invalidly, skip request-body reads, skip
response-body writes, or trade away correctness. The server must still read the
full request body and echo the exact response bytes.

## Metric Contract

| Metric | Role | Direction | Acceptance / Rejection Rule | Notes |
|--------|------|-----------|------------------------------|-------|
| `h1_plain_echo_1k_eta_go_rps_ratio` | Primary | higher | Keep only if the movement is outside repeat noise and guardrails hold. | Median Eta echo RPS divided by median Go echo RPS, H1 plain, `POST /echo`, 1 KiB body, `c=16`. |
| `h1_plain_echo_1k_eta_rps` | Diagnostic | higher | Should move with the primary. | Absolute Eta throughput. |
| `h1_plain_echo_1k_go_rps` | Reference | stable | Large reference swings make the run suspect. | Same Go server shape. |
| `h1_plain_echo_1k_eta_p99_us` | Guardrail | non-regression | Reject clear p99 regressions unless a throughput win is large and explained. | Eta p99 is currently better than Go. |
| `h1_plain_echo_1k_eta_go_p99_ratio` | Guardrail | non-regression | Do not buy RPS by losing tail latency. | Eta p99 divided by Go p99. |
| `h1_plain_non_echo_eta_go_rps_ratio_geomean` | Guardrail | non-regression | Non-echo endpoints should not collapse. | Root, user, post, static diagnostics. |
| `h1_plain_echo_1k_success` | Correctness | equals 1 | Required. | All rows must return 200, zero errors, and exact expected response bytes. |

## Hypothesis Space

| ID | Hypothesis | Mechanism | Distinguishing Prediction | Falsifier | Status |
|----|------------|-----------|---------------------------|-----------|--------|
| H1 | Remaining body copy/allocation | The fixed-body read-all or echo response path still performs avoidable allocation/copy work. | Allocation/copy change improves echo RPS without hurting static or p99. | Copy reduction does not move RPS. | open |
| H2 | H1 parser/head read overhead | Eta spends more per request before handler even for full-initial bodies. | Phase trace shows head read dominates and root/post gaps move with echo. | Head read is small or unrelated to RPS gap. | open |
| H3 | Response write/syscall scheduling | Eta's response write path is lower-throughput under echo even though static is strong. | Write spans dominate echo and optimizations improve echo plus static/post. | Static remains stronger and write spans do not explain gap. | partially rejected by prior art |
| H4 | Go reference or benchmark noise | The remaining 0.8x ratio is not stable in current tree. | Fresh baseline varies around parity or Go swings materially. | Fresh focused baseline repeats around 0.8x. | open |
| H_other | Residual explanation not yet modeled | Unknown | Current experiments do not distinguish it. | A better split replaces it. | open |

## Experiment Selection Rule

- Prefer experiments where live hypotheses predict different observations.
- Prefer cheap falsifiers before expensive rewrites.
- Prefer instrumentation when current hypotheses are indistinguishable.
- Reject or narrow hypotheses when their falsifiers fire.
- Keep changes only when they improve the hill and preserve checks.

## Running Log

Append completed entries below. Keep entries concise, falsifiable, and useful to
a fresh agent.

## E1: Fresh Remaining-Gap Baseline

### Hypothesis Space Split
- Parent question: after the earlier fixed-body copy/allocation wins, does H1
  plain `echo_1k` still reproduce as a real throughput hill?
- Hypothesis under test: the remaining Eta/Go gap is stable enough to climb.
- Rival hypotheses: the prior fix already consumed the hill, or current broad
  observations are noise.
- Why this split is high value: avoid optimizing an already-resolved or noisy
  endpoint.

### Prediction Before Run
- Expected primary metric movement: no code change.
- Expected secondary metric movement: p99 remains better than Go while RPS
  remains below Go.
- Distinguishing observation: focused 24k x9 repeats reproduce around `0.8x`.
- Falsifier: focused run collapses near parity.

### Attack
- Change or probe: created a fresh post-fix hill from the previous H1 facade.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-remaining-throughput-20260615`
- Trace commands:
  - `bash .hill-climbing/h1-plain-echo-remaining-throughput-20260615/trace_h1_echo_phase.sh`
  - `ETA_H1_ECHO_PHASE_ENDPOINT=static_1k bash .hill-climbing/h1-plain-echo-remaining-throughput-20260615/trace_h1_echo_phase.sh`
  - `ETA_H1_ECHO_PHASE_ENDPOINT=post_user ETA_H1_ECHO_PHASE_REQUESTS=8000 bash .hill-climbing/h1-plain-echo-remaining-throughput-20260615/trace_h1_echo_phase.sh`
- Controls held constant: H1 plain, `c=16`, 24k x9 focused benchmark, pinned
  server/load cores.

### Result
- Primary metric: `h1_plain_echo_1k_eta_go_rps_ratio=0.803909402`.
- Secondary metrics:
  - Eta echo RPS `122959.881`; Go echo RPS `152952.411`.
  - Eta echo p99 `181.587us`; Go echo p99 `457.173us`.
  - `h1_plain_echo_1k_success=1`.
  - non-echo RPS geomean `0.927133981`; static RPS ratio `1.39523622`.
- Phase trace:
  - echo accepted-to-complete p50/p99 `75/181us`.
  - echo head p50/p99 `55/158us`.
  - echo handler p50/p99 `2/5us`.
  - echo write p50/p99 `71/176us`.
  - static phase shape was similar while static was faster than Go.
  - post accepted-to-complete p50/p99 `61/140us`.
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T16:38:52Z`.

### Verdict
- Verdict: corroborated and split-needed.
- Reason: the remaining gap is real, but p99 is already better than Go and the
  handler is not the owner. Static still rejects a generic fixed response write
  hill.
- Hypothesis space update: H4 rejected; H1 remains live for remaining
  request-body `read_all` overhead; H3 remains partially rejected.
- Commit/revert decision: keep hill setup only.
- Next experiment: try a general fixed-response writev path; reject if static
  or echo RPS drops.

## E2: Fixed Response Iovecs

### Hypothesis Space Split
- Parent question: is the remaining echo gap in the fixed response write copy?
- Hypothesis under test: writing H1 fixed response head/body as iovecs avoids a
  copy into the per-connection write buffer and improves throughput.
- Rival hypotheses: the current contiguous write buffer is faster than writev,
  or the gap is elsewhere.
- Why this split is high value: it is a general H1 fixed-response experiment,
  not endpoint-specific.

### Prediction Before Run
- Expected primary metric movement: higher if the write-buffer copy owns part
  of the gap.
- Expected secondary metric movement: static should also improve or stay flat.
- Distinguishing observation: echo and static RPS rise without p99 loss.
- Falsifier: echo/static RPS regress.

### Attack
- Change or probe: refactored H1 response writes to send fixed head/body as
  `Cstruct` iovecs through `Eio.Flow.write`.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-remaining-throughput-20260615`
- Controls held constant: same focused hill harness.

### Result
- Primary metric: `0.803909402 -> 0.784109938`.
- Eta echo RPS: `122959.881 -> 120600.318`.
- Eta echo p99: `181.587us -> 189.792us`.
- Static RPS ratio: `1.39523622 -> 1.3735031`.
- Success: `1`.
- Checks: passed.
- `log.jsonl` reference: timestamp `2026-06-15T16:41:21Z`.

### Verdict
- Verdict: rejected.
- Reason: primary RPS, static RPS, and p99 all moved the wrong way.
- Hypothesis space update: H3 is further rejected for this hill; the contiguous
  per-connection write buffer is better than this iovec attempt.
- Commit/revert decision: reverted.
- Next experiment: optimize the fixed request-body `read_all` path.

## E3: Adapter-Owned Fixed Body Read-All

### Hypothesis Space Split
- Parent question: does `Server.Body.read_all` still impose avoidable overhead
  for adapter-owned fixed bodies that are already fully buffered?
- Hypothesis under test: H1 fixed bodies can provide a direct `read_all` path
  that returns the owned initial body bytes and avoids the second read/eof pass.
- Rival hypotheses: remaining cost is H1 parser/socket scheduling or response
  construction outside the body API.
- Why this split is high value: the change is general to server request bodies,
  preserves the single-operation/release contract, and directly targets the
  echo path without special-casing `/echo`.

### Prediction Before Run
- Expected primary metric movement: higher than E1 and repeatable.
- Expected secondary metric movement: p99 should stay better than Go; non-echo
  guardrails should not collapse.
- Distinguishing observation: echo RPS improves, phase accepted/write timings
  improve modestly, and exact-byte correctness holds.
- Falsifier: primary remains near `0.80x` or correctness/p99 regresses.

### Attack
- Change or probe:
  - Added optional `read_all` to `Eta_http.Server.Body.of_reader`.
  - Added a direct H1 fixed-body implementation that returns the full initial
    body without copying when the body is already fully buffered.
  - Kept the existing read/discard/release behavior for ordinary reads and
    drained bodies.
- Benchmark command:
  `python /home/ribelo/.dotfiles/skills/engineering/workflow/hill-climbing/scripts/hill_climbing.py run --id h1-plain-echo-remaining-throughput-20260615`
- Guardrail command:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --eta-only --h1-only --out http-testsuite/results/autonomous-server-load-20260615-h1-echo-readall-direct`
- Controls held constant: same H1 focused harness, same server/load pinning,
  exact status/body validation.

### Result
- First run:
  - primary `0.803909402 -> 0.855538296`.
  - Eta echo RPS `122959.881 -> 130526.022`.
  - Eta echo p99 `181.587us -> 188.981us`.
  - success `1`.
- Verification run:
  - primary `0.852137892`.
  - Eta echo RPS `131068.164`; Go echo RPS `153810.979`.
  - Eta echo p99 `181.657us`; Go echo p99 `468.175us`.
  - non-echo RPS geomean `0.934013393`.
  - static RPS ratio `1.41314546`.
  - success `1`.
- Post-change phase trace:
  - echo accepted-to-complete p50/p99 `70/163us`.
  - echo head p50/p99 `53/161us`.
  - echo handler p50/p99 `2/4us`.
  - echo write p50/p99 `67/157us`.
- H1-only broad guardrail:
  - failed rows `0`.
  - H1 plain c=16 echo p99 `276.298us`.
  - H1 TLS c=16 rows all passed; echo p99 `382.481us`.
- Checks:
  - `nix develop -c dune build http-testsuite/test/server_load/h1_probe.exe`
    passed.
  - `nix develop -c dune runtest --profile release test/http_eio test/http_common`
    passed on rerun after one transient Dune RPC error.
  - `git diff --check` passed.
- `log.jsonl` references:
  - first passing timestamp `2026-06-15T16:44:30Z`.
  - verification timestamp `2026-06-15T16:45:00Z`.

### Verdict
- Verdict: corroborated and kept.
- Reason: the primary improvement repeated around `+6%` relative to the fresh
  baseline, Eta echo RPS rose about `8k`, correctness held, p99 remained far
  better than Go, and broad H1 rows passed.
- Hypothesis space update: H1 corroborated for the remaining gap. The remaining
  delta to Go is smaller and likely needs a fresh rerank before more H1 work.
- Commit/revert decision: keep.
- Next experiment: rerun broad comparisons and choose the next hill from the
  updated ranking rather than continuing to micro-optimize H1 echo blindly.

## E4: Broad Rerank After Direct Read-All

### Hypothesis Space Split
- Parent question: is H1 plain `echo_1k` still the next hill after the accepted
  direct `read_all` change?
- Hypothesis under test: broad reference comparisons will demote H1 echo enough
  that the next hill should be selected elsewhere.
- Rival hypotheses: H1 echo remains a top absolute or relative problem and
  deserves another H1-specific climb.
- Why this split is high value: prevents over-optimizing a hill after a
  validated win.

### Prediction Before Run
- Expected primary metric movement: broad H1 echo RPS ratio should improve
  relative to the pre-change broad `0.70x` symptom.
- Expected secondary metric movement: no failed rows; H2 16x1 remains flagged
  as scheduling-sensitive.
- Distinguishing observation: H1 echo no longer appears as the obvious next
  actionable hill.
- Falsifier: H1 echo remains near `0.70x` or becomes a p99 regression.

### Attack
- Change or probe: no further code change; ran broad quick references.
- Benchmark command:
  `nix develop -c dune exec http-testsuite/test/server_load/run.exe -- --quick --references --out http-testsuite/results/autonomous-server-load-20260615-post-h1-readall-direct`
- Controls held constant: quick broad suite, references enabled, default pinning.

### Result
- Failed rows: `0`.
- Broad H1 plain c=16 Eta/Go:
  - root RPS `1.298x`, p99 `0.644x`.
  - user_id RPS `0.779x`, p99 `0.863x`.
  - post_user RPS `0.862x`, p99 `0.813x`.
  - static_1k RPS `1.112x`, p99 `0.437x`.
  - echo_1k RPS `0.935x`, p99 `0.807x`.
- Suite analysis still excludes H2 16x1 as scheduling-sensitive.
- Top actionable Eta p99 after excluding 16x1:
  - H2 plain echo_1k 4x4 p99 `926.280us`.
  - H2 plain echo_1k 1x16 p99 `878.368us`.
  - H2 TLS echo_1k 4x4 p99 `877.476us`.
  - H2 TLS echo_1k 1x16 p99 `747.338us`.
- Reference checks:
  - H2 plain echo_1k 4x4 vs Node: RPS `1.224x`, p99 `0.454x`.
  - H2 plain echo_1k 1x16 vs Node: RPS `1.027x`, p99 `1.406x`.
  - H2 TLS echo_1k 4x4 vs Go: RPS `1.062x`, p99 `1.021x`.
  - H2 TLS echo_1k 1x16 vs Go: RPS `1.222x`, p99 `0.944x`.

### Verdict
- Verdict: corroborated.
- Reason: H1 echo is substantially improved in the broad suite and no longer
  looks like the best next hill. The remaining focused 0.85x ratio exists, but
  broad H1 echo p99 is still better than Go and broad RPS is close enough that
  more H1 echo work risks overfitting.
- Hypothesis space update: pause H1 echo. The next candidate should come from
  H2 echo/static p99, with attention to reference-relative gaps rather than
  absolute Eta p99 alone.
- Commit/revert decision: keep direct `read_all`.
- Next experiment: set up a new H2 echo p99 hill around the stable, actionable
  non-16x1 shapes, likely H2 plain `echo_1k` 1x16 vs Node or H2 TLS `echo_1k`
  4x4 vs Go depending on repeat stability.

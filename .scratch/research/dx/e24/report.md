# DX-E24 Report — Iteration mirrors `List`

## Summary

Implemented the amended E24 contract:

| Before | After |
|---|---|
| `for_each_par inputs f` | `map_par f inputs` |
| `for_each_par_bounded ~max inputs f` | `map_par ~max_concurrent f inputs` |
| positional `retry` | labeled, data-last `retry ~schedule ~while_ effect` |
| positional `retry_or_else` | labeled, data-last `retry_or_else ~schedule ~while_ ~or_else effect` |
| positional `repeat` | labeled, data-last `repeat ~schedule effect` |

`map_par` documents and proves its default cap of eight. The two old parallel
names are deleted. `Schedule.t`, its hook parameter, tap combinators, and driver
protocol are unchanged.

## Why `retry_or_else` absorption was reversed

The original one-pager treated fallback as an optional branch of `retry`. The
amendment retained `retry_or_else` after review showed that its two-error type
(`'err1` source to `'err2` fallback) is genuine expressiveness, and that the two
implementations already have different cause boundaries: `retry` handles only a
bare `Cause.Fail`, while `retry_or_else` handles catchable composites and selects
their first typed failure. E24 changes argument shape only and documents this as
a current limitation/difference rather than silently unifying behavior.

## Gates

Run from the E24 worktree through the required Nix shells:

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo` | PASS (existing integer-overflow warnings only) |
| `nix develop .#mainline -c dune build test/signal_jsoo` | Expected FAIL; same seven diagnostics as master |

The signal comparison used an archive of master commit `42e7f17a` in a temporary
directory and the same mainline Nix shell. Both commands exited 1 with the same
six locally abstract polymorphism syntax errors and the same
`Signal.Time.monotonic_time` versus `int` error. Parallel diagnostic order
differed; file/line/message content did not.

Focused development gate:

```text
nix develop -c dune runtest test/core_eio --force
499 tests run — PASS
```

## Parity-suite evidence

Promoted executable evidence lives in the common runtime suites:

| Obligation | Evidence |
|---|---|
| Optional omission produces `Effect.t` | `iteration optional omission yields effects` |
| Mapper is lazy at blueprint construction | `map_par mapper defect is runtime die` and capped counterpart |
| Input order under out-of-order completion | `map_par preserves delayed input order` |
| Fail-fast sibling cancellation | `map_par fail-fast` |
| Cancellation/finalizer parity | `map_par finalizer cancellation baseline`; `map_par catch waits for child finalizer` |
| Explicit bound | `map_par caps concurrency`; max-one sequential test |
| Default cap eight with nine inputs | `map_par default cap is eight` |
| Nonpositive construction rejection | `map_par rejects nonpositive max` |
| Fallback `None` before a step | `retry_or_else first rejection has no output` |
| Latest `Some out` after steps | `retry_or_else predicate rejection fallback` |
| Terminal `Some out` at exhaustion | `retry_or_else exhausted fallback` |
| Composite first typed failure | `retry_or_else composite typed failure` |
| Hook order/failure/defect/interruption | existing migrated schedule tap tests under new call shapes |

The implementation keeps one worker-pool path and one schedule-driving path;
the tests exercise the new public entry points rather than aliases.

## Census and footgun actuals

Independent post-migration census from `effect.mli` / `schedule.mli`:

| Metric | Before | Actual after | Delta |
|---|---:|---:|---:|
| Iterate-cluster public vals | 5 | 4 | −1 |
| Iterate-cluster concepts | 5 | 4 | −1 |
| `Schedule.t` parameters | 3 | 3 | 0 |
| Schedule tap vals | 2 | 2 | 0 |

After vals: `map_par`, `retry`, `retry_or_else`, `repeat`. A repository scan found
no old parallel API use outside the historical commit-subject example in
`AGENTS.md`, uncommitted assignment files, and old-side research fixtures.

**Footgun delta: −1 / +0.** The misleading `for_each` collection name and
duplicate bounded family are gone. No new trap is counted because the public mli
states the default eight and the DX guide explicitly says omission is not
unbounded. The red-team notes that the call alone still needs that documentation.

## Prediction scoring

### Original sealed predictions

| Prediction | Actual | Score |
|---|---|---|
| Input-order results | Preserved and tested | hit |
| Fail-fast sibling cancellation/finalization | Preserved and tested | hit |
| `while_` rejects before a schedule step | Preserved | hit |
| Omitted bound means old worker behavior | Default is the old cap of eight | partial (cap not stated explicitly) |
| 5 vals → 3 | 5 → 4 after retaining `retry_or_else` | miss |
| 5 concepts → 2 | 5 → 4 | miss |
| `Schedule.t` 3 → 2; taps deleted | Held at 3; taps retained | miss, with predicted hold trigger activated |
| Footguns −2/+0 | −1/+0 | miss |
| Observer semantics replace taps | Observers removed from amended scope | superseded |
| Hold slimming if a driver cannot express taps | `Resource.auto` triggered the hold | hit |

### Amendment predictions

| Prediction | Actual | Score |
|---|---|---|
| Census 5 vals → 4; concepts 5 → 4 | Exact | hit |
| Schedule type/taps unchanged | Exact | hit |
| Footguns −1/+0 | Exact | hit |
| Default cap eight and explicit-cap enforcement | Peak probes passed | hit |
| Function-first `map_par`, input order, fail-fast | Implemented and tested | hit |
| Retry cause difference remains | Implementation unchanged; mli documents it | hit |
| Fallback `None` / latest `Some` / terminal `Some` | All tests passed | hit |
| Native and known JS gates | Green; signal failure matches master | hit |

## Red-team

Artifacts: `.scratch/research/dx/e24/redteam/`.

1. Zero and `-3` are rejected at construction with `Invalid_argument`; neither
   falls through to default/unbounded behavior.
2. `Effect.map_par fetch ids` looks plausibly unbounded but reaches a measured
   peak of eight for nine blocked inputs. The mli and `docs/api-dx.md` explicitly
   correct the reading.

Both verdicts: **PASS**.

## Review

Packet: `.scratch/research/dx/e24/review/` (two blinded A/B pairs, manifest, and
semantics questions).

Independent two-axis review found no implementation/contract defect. Findings
and dispositions:

- Tests in the common suites were flagged against the generic `test_eta.ml`
  guideline, but the E24 assignment explicitly requires these parity tests in
  `effect_retry_repeat_common_suites.ml` or its neighbors; requirement wins.
- The untracked amendment filename was flagged as durable provenance. The
  protocol explicitly requires both assignment files to stay uncommitted; the
  journal and this report restate the amended contract and evidence so the
  tracked bundle is self-contained.
- Long mechanically migrated call sites were rewrapped to match nearby style.
- Unanswered `QUESTIONS.md` prompts are intentional inputs to the orchestrator's
  blinded review, not missing executor answers. Omission semantics are exercised
  in red-team and parity evidence rather than the bounded A/B example.
- The stale blocker report finding was fixed by this final report.

## Deviations and follow-ups

- Execution correctly stopped on the unwritable original optional-last contract,
  then resumed only after the amendment authorized erasable argument order.
- The original Schedule slimming and observer red-team probes were not performed;
  slimming is explicitly held for E24b and no observers exist in the final E24
  contract.
- `retry`'s narrower cause handling remains a documented current limitation for a
  future experiment; E24 deliberately does not normalize it.

## Recommendation

**Promote the amended E24 contract.** Native and applicable JS gates pass,
parity obligations are executable, migration is complete, review findings are
resolved or explicitly overridden by the assignment, and the census/footgun
results match the amendment predictions.

**Separate Schedule verdict: HOLD slimming for E24b.**

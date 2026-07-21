# DX-E12 Report — `Effect.audit` / `Effect.describe`

## Recommendation

**PROMOTE the static preflight API; KILL `audit`'s examples-manifest role.**

`Effect.audit`, `Effect.describe`, and the `Eta_test` assertions are small,
deterministic, and honest when used for the documented class: the already-built
static spine plus declared Eta leaf footprints. They must not be presented as a
runtime inventory. The 54-example evidence shows that ordinary bind-heavy
programs hide enough central behavior to make an audit manifest misleading.

## Delivered surface

- Public `Effect.audit` record with names and six capability flags.
- Public `Effect.describe` deterministic static tree with `<bind …>` markers.
- Private footprint on `Custom`; OR-union through visible nodes and `preserve`.
- Required explicit custom-leaf declarations through `Effect.Expert.make`, with
  child inheritance and background-implies-concurrency normalization.
- Seven `Eta_test` assertions: `assert_no_clock`, `assert_no_logs`,
  `assert_no_metrics`, `assert_no_concurrency`, `assert_no_resources`,
  `assert_no_background`, and `assert_pure_eff`.

## Gates

| Command | Attempts | Result |
| --- | ---: | --- |
| `nix develop -c dune build @install` | 2 | PASS |
| `nix develop -c dune runtest --force` | 2 | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | 2 | PASS |
| `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo` | 2 | PASS |

Focused development gate:

```text
nix develop -c dune runtest test/core_eio test/test test/effect_introspection --force
PASS
```

## Property evidence

The documented generated class has eight base leaves covering pure/fail/sync,
clock, logs, metrics, resources, and background. Two recursive levels add map,
named, preserve-backed uninterruptible, and parallel compositions, producing
**168 blueprints**.

- `uses_clock = false` -> execution against a poisoned Eta clock never reached
  the poison.
- `emits_logs = false` -> execution against an in-memory logger left it empty.
- Focused expected-record tests cover all six flags, names, retry, map-par/par,
  acquire/release, structured background, daemon, `Expert.make` empty/all/
  inherited declarations, and background/concurrency consistency.
- Arbitrary bind lambdas are deliberately excluded and tested adversarially
  instead of being smuggled into the claimed class.

## Describe corpus

`test/effect_introspection/expected_descriptions.txt` contains **11** generated
snapshots: pure/map chain, named leaf, nested bind, par, all, race, map-par,
fold, bind_error, resource, and background. The regeneration script is
`test/effect_introspection/regenerate.sh`.

## Golden manifest quality

`.scratch/research/dx/e12/manifest/examples.golden` covers all **54** example
files and **71** reached runtime boundaries; four examples have no Eta runtime
boundary. The script compiles instrumented temporary copies and audits the exact
effect values before delegating to the real runtime. It fails on timeout or any
nonzero example exit and never edits example source.

Aggregate true rows across the 71 boundaries:

| Flag | True |
| --- | ---: |
| Clock | 30 |
| Logs | 3 |
| Metrics | 3 |
| Concurrency | 19 |
| Resources | 15 |
| Background | 1 |

Positive rows align well for `timeout_policy`, `retry_schedule`,
`repeat_heartbeat`, `race_mirror`, `daemon_drain`, `metric_batching`, and
resource/concurrency examples whose relevant leaves are already constructed.

The kill-gate failures are central and numerous:

- `resource_retry` reports `clock=false` because retry is built after a bind;
- `cli_business` reports every flag false despite retry-oriented behavior;
- `channel_probe` and `queue_probe` report no concurrency because operations are
  constructed by continuations;
- `observability` reports logs but not its metric;
- `observability_sinks` reports logs but not its metric;
- `signal_stabilization` reports every flag false at its captured boundary.

The rows are mechanically correct under the MLI but do not match what readers
reasonably infer from several example names. **Kill the manifest role.** Keep
this golden only as evidence of why static audit must not become inventory.

## Census and footguns

| Measure | Sealed prediction | Actual | Score |
| --- | ---: | ---: | --- |
| Introspection values | +2 | +2 | match |
| Public introspection types | +1 | +1 | match |
| Eta_test assertions | >=6 | +7 | match |
| Describe diagnostic shapes | requested set | 11 / complete set | match |
| Example files | 54 | 54 | match |
| Independent `describe` teaching rating | >=4 | 5/5 | match |
| Manifest mostly intuitive | yes | no; kill gate fired | miss |

Observable prediction score: **6/7**.

Footguns: **+0, with one existing representation trap explicitly
disarmed-by-docs.** The opaque-lambda limitation is unavoidable in the existing
GADT, is stated beside the type/value/assertion contracts, is printed as
`<bind …>`, and has an executable attack. Reading only an assertion name without
its contract remains the strongest usability risk.

## Red-team outcome

`redteam/output.txt` records:

```text
hidden-bind uses_clock=false runtime_sleeps=1
preserve-wrapped uses_clock=true
```

The first probe defeats the runtime-inventory claim exactly as predicted by the
MLI. The second proves `preserve` inheritance. Result: **static claim survives;
runtime-inventory claim is rejected.**

## Teaching A/B

The review packet is under `.scratch/research/dx/e12/review/`. Executor rubric:
prose 3/5, real describe output 4/5. Independent technical review: prose 4/5,
real describe output 5/5. The expected answer to “what does
`uses_clock=false` guarantee?” is the visible-static-spine guarantee, including
the continuation caveat, not “this handler never sleeps at runtime.”

## Final verdict

Ship the API as static blueprint introspection and executable preflight
vocabulary. Do not use it as an examples/runtime manifest. Preserve the golden
and red-team artifacts as evidence for DX-E17's treatment of dynamic
continuations.

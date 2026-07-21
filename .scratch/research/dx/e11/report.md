# DX-E11 report — `Eta_test.Run`: one golden-record test runtime

## Recommendation

**PROMOTE the golden record, ordered printer, and test-only fiber accounting.**

**KILL `finalizer_events` and `expect_finalizers` separately.** Individual
finalizers are private closures invoked directly inside one production
`Runtime_core.run_finalizers` batch. The public runtime contract can observe the
surrounding generic `protect`, but not individual success/failure/order. Adding
a hook would violate the zero-production-cost and scope fences. Aggregate
finalizer failures remain fully visible in `outcome.exit` as
`Cause.Finalizer`/`Cause.Suppressed`; successful cleanup can emit ordinary
recorded events when a scenario needs evidence.

The whole-printer kill gate did not fire. The broken retry is actionable and the
six-scenario corpus remains below the sealed 120-line readability ceiling.

## Delivered surface and census

`Eta_test.Run` adds:

- **4 public types:** `fiber_kind`, `fiber_info`, cross-category `event`, and the
  seven-field `outcome` record;
- **5 public values:** `run`, `expect_no_pending_fibers`, `expect_sleeps`, `pp`,
  and `testable`;
- **0 production runtime fields, branches, service lookups, or callbacks**;
- **0 changes** to `Schedule.t`, E19/E20 machinery, root `eta` dependencies, or
  application state ownership.

`eta_test` now names `eta_blocking` directly in Dune because its decorated
runtime constructors must install the same default blocking service that
`Eta_eio.Runtime.create` installs. This was already in `eta_test`'s transitive
closure through `eta_eio`; the explicit edge preserves runtime semantics.

`run` uses fresh in-memory logger/tracer/meter sinks, a seeded random token, the
E19 clock/logger/tracer/random scoped overrides, and an Eio backend contract
decorated only inside `eta_test`. `account_fibers=false` exists for exact
neutrality comparisons; normal `Run.run` enables accounting.

## Exact gates

Final commands were rerun from the assigned worktree after all review fixes:

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo` | PASS |

The mainline build emitted the repository's existing integer-truncation
warnings and completed successfully. `signal_jsoo` was not touched.

Additional rerunnable gates:

- `.scratch/research/dx/e11/accounting-neutrality.sh` — PASS;
- `.scratch/research/dx/e11/redteam/run.sh` — PASS (the script requires the
  deliberately broken check to fail).

## Six canonical golden scenarios

Executable evidence is the `Run / six canonical golden scenarios` and
`Run / six complete outcomes replay` cases in `test/test/test_eta_test.ml`.

| Scenario | Evidence in the outcome | Result |
| --- | --- | --- |
| Sibling cancelled on failure | primary `Fail "sibling failed"`; sibling-finalizer log | PASS |
| Finalizer ran on interruption | race winner plus `interrupted finalizer ran` log | PASS |
| Retry slept exactly 10/20/40 | `sleeps` and ordered `Sleep` events | PASS |
| Span closed on defect | `Cause.Die`; completed span has `Error` status | PASS |
| Suppressed finalizer preserved | exact `Cause.Suppressed` tree | PASS |
| Race-loser resource released | winner succeeds; release log is present | PASS |

Every scenario is constructed and run twice; complete `Run.testable` outcomes
compare equal. The defect case specifically proves diagnostic equality rather
than physical exception equality. A separate mixed log/metric/sleep/span case
proves cross-category order, and a reused-clock case proves sleep history is
per execution.

## Accounting-neutrality proof

`Fiber_accounting.wrap` decorates only `fork` and `fork_daemon`, binds a
test-local deterministic ID around each callback, and removes it in
`Fun.protect`. All other backend operations delegate unchanged. Pending entries
are snapshotted when the root exit becomes available.

The proof has two rungs:

1. Every legacy Eta_test `with_*` helper now constructs its runtime through the
   decorated test contract. `accounting-neutrality.sh` runs the existing helper
   regression suite (35 cases) unchanged and it passes, including a real
   Eta_blocking callback through both a legacy helper and `Run`.
2. `fiber accounting preserves exit corpus` runs success, typed failure,
   successful/suppressed finalizer, structured concurrency, and race blueprints
   with accounting disabled and enabled under otherwise identical `Run`
   construction. Complete outcomes compare diagnostically; all pass.

Production neutrality is structural: the implementation diff touches
`lib/test/`, `test/test/`, and E11 research artifacts only. No production
interpreter path contains an accounting check.

The daemon red-team output reports:

```text
execution outcome
exit: Ok(())
ordered events:none
snapshots:
 sleeps:none
 logs:none
 spans:none
 metrics:none
 finalizers: unavailable (failures remain in exit)
pending fibers:
  [0] #1 parent=root kind=daemon(runtime-owned)
```

This distinguishes owned daemon work from abnormal structured pending work.
Normal structured scopes join/cancel children before root exit; the suite proves
completed structured fibers are absent and nested daemon parent IDs replay.

## Golden printer and red-team result

Printer order is: exit; one cross-category ordered event stream; complete sink
snapshots; explicit finalizer-accounting boundary; pending fibers. Span and
metric renderers include every field used by equality. Empty sections are one
line. Corpus self-rating: **3/3** — scannable, complete, and actionable; the six
renderings remain below 120 lines in the executable readability test.

The required broken-test output follows verbatim from
`.scratch/research/dx/e11/review/broken-output.txt`:

```text
Testing `dx-e11-redteam'.

> [FAIL]        broken golden          0   retry slept 10/20/30.

┌──────────────────────────────────────────────────────────────────────────────┐
│ [FAIL]        broken golden          0   retry slept 10/20/30.               │
└──────────────────────────────────────────────────────────────────────────────┘
ASSERT retry backoff at Run.outcome.sleeps; expected exponential 10/20/40; inspect the schedule constructor
FAIL retry backoff at Run.outcome.sleeps; expected exponential 10/20/40; inspect the schedule constructor

   Expected: `execution outcome
              exit: Ok(())
              ordered events:
                [0] sleep 10ms
                [1] sleep 20ms
                [2] sleep 40ms
              snapshots:
               sleeps:
                [0] 10ms
                [1] 20ms
                [2] 40ms
               logs:none
               spans:none
               metrics:none
               finalizers: unavailable (failures remain in exit)
              pending fibers:none'

   Received: `execution outcome
              exit: Ok(())
              ordered events:
                [0] sleep 10ms
                [1] sleep 20ms
                [2] sleep 30ms
              snapshots:
               sleeps:
                [0] 10ms
                [1] 20ms
                [2] 30ms
               logs:none
               spans:none
               metrics:none
               finalizers: unavailable (failures remain in exit)
              pending fibers:none'

Raised at Alcotest_engine__Test.check in file "src/alcotest-engine/test.ml", lines 216-226, characters 4-261
Called from Alcotest_engine__Core.Make.protect_test.(fun) in file "src/alcotest-engine/core.ml", line 186, characters 17-23
Called from Alcotest_engine__Monad.Identity.catch in file "src/alcotest-engine/monad.ml", line 24, characters 31-35

Logs saved to `~/projects/ribelo/ocaml/Eta-dx-e11/_build/_tests/dx-e11-redteam/broken golden.000.output'.
 ──────────────────────────────────────────────────────────────────────────────

Full test results in `~/projects/ribelo/ocaml/Eta-dx-e11/_build/_tests/dx-e11-redteam'.
1 failure! in 0.000s. 1 test run.
```

Rubric rating:

- **What:** expected 40ms, received 30ms at event/sleep index 2;
- **Where:** `Run.outcome.sleeps` in the retry-backoff assertion;
- **What next:** inspect the schedule constructor.

## W6 review packet

`.scratch/research/dx/e11/review/w6-run.ml` replaces the E19 packet's
`w6-new.ml` clock creation, runtime/switch parameters, fork, sleeper polling,
three manual adjustments, and await with one `Run.run` call. Nonblank,
non-comment code is 25 E19 lines versus 22 E11 lines (12% reduction). More
importantly, exact sleeps are returned data rather than inferred from final clock
time, and the test owns no scheduler-driving protocol.

## Predictions, footguns, and final ledger

Prediction score: **7.5 / 8** (full table in `journal.md`). Seven predictions
passed. The public-census prediction scores half because the cross-category
`event` type was required to make the ordered-printer claim true, while the
predicted finalizer types/helper were correctly killed.

Footguns checked against predictions:

1. Pending daemons are explicitly `daemon(runtime-owned)`, never labeled leaks.
2. A caller-provided reused clock contributes only sleeps from the current run.
   Cancelled waiters remove themselves, and a 1ms race winner with 50 explicit
   yields does not spuriously advance to its cancelled 100ms competitor, with
   accounting enabled or disabled.
3. Span events enter the ordered stream when the span closes; this is documented
   observation order, not span-start order.
4. A root effect that never exits and creates no virtual sleeper still waits
   forever; `Run` does not invent a timeout or silently cancel the program.
5. Successful individual finalizers remain unavailable by the zero-cost gate;
   the printer says so instead of showing an empty claimed journal.

Undisclosed footguns found after red-team/review: **0**. The independent review
initially found physical defect equality, incomplete rendering, stale reused
clock history, partial replay, weak neutrality isolation, cancelled-sleeper
retention, and loss of Eta_eio's default blocking service. Each now has a focused
passing regression and is reflected in this report.

Final ledger:

- golden record + ordered printer: **ACCEPT / PROMOTE**;
- test-only pending fiber accounting: **ACCEPT / PROMOTE**;
- per-finalizer event accounting: **REJECT / KILL SEPARATELY**;
- existing assembly-only baseline: **DOMINATED for golden tests**;
- bespoke interpreter: **REJECTED by composition and scope constraints**.

Strongest remaining limitation: successful finalizer identity/order cannot be
observed without a production interpreter seam. That limitation is explicit and
does not weaken exit/log/span/metric/sleep/fiber evidence.

# DX-E19 report — scoped capability override

## Recommendation

**PROMOTE.** Ship `Effect.with_clock`, `with_random`, `with_logger`, and
`with_tracer` as the scoped runtime-service substitution surface. The feature
does not introduce an environment parameter or application dependency
container.

## Delivered surface

- `Effect`: **+4 vals**.
- `Capabilities`: **one effective type change**. The checkout already had a
  sleep-only `clock` despite the assignment saying it did not exist; it now has
  the required monotonic `now_ms`/`sleep` pair.
- `Eta_test.Test_clock`: `as_capability`.
- Eio/jsoo/OTEL and test clock implementations updated for the clock pair.
- No `intercept_*`, global-counter, `Schedule.t`, or application-service change.

## Required gates

All final commands passed from the assigned worktree:

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo` | PASS |

Additional parity gate:

- `nix develop .#mainline -c dune runtest test/js_jsoo --force` — PASS,
  including `scoped clock and logger parity`.

The first full-suite attempt was diagnostic, not final: it exposed an invalid
owner-domain lookup and a manual tracer identity precondition. Both were fixed,
and the exact full gate above was rerun successfully.

## Edge-matrix results

The `Scoped capabilities` group in `test/test/test_eta_test.ml` contains 13
focused executable cases:

| Edge | Result |
| --- | --- |
| Success, typed failure, defect, synthetic interruption restoration | PASS |
| Actual runtime-cancellation restoration | PASS |
| Fork inheritance for clock/random/logger/tracer | PASS |
| `par` sibling isolation in both directions | PASS |
| Innermost wins and restores outer | PASS |
| Fake-clock sleep and timeout, no wall time | PASS |
| Seeded retry jitter replay | PASS |
| Logger sink replacement | PASS |
| `annotate_logs` attributes before sink | PASS |
| `with_minimum_log_level` filter before sink | PASS |
| Cross-tracer and same-tracer open-span ownership | PASS |
| Daemon fork-time retention and inherited failure diagnostics | PASS |
| In-flight real sleep unaffected by later override | PASS |
| Jsoo clock/logger parity | PASS |

`with_logger` order is therefore: scoped minimum filter, scoped/per-call
attributes, future `intercept_log` transformation, selected sink. E20 is not
implemented here.

## Red-team outcomes

Artifacts: `.scratch/research/dx/e19/redteam/`.

1. **Sibling-leak trap:** expected `(11, 11)` when only the left branch used
   clock 11; executable result was `(11, 0)`. Contract and test agree.
2. **In-flight sleep trap:** a real 30 ms Eio sleep retained its call-time
   clock while a later sibling scope observed clock 999. The sleep was not
   accelerated.
3. **Daemon trap:** a gated daemon ran after the lexical override returned and
   still observed clock 88 plus the override logger/tracer. Failure diagnostics
   also use inherited overrides on a noop-base runtime.

All are disarmed by docs and executable evidence. Footguns: **+0 undisclosed**.

## Documentation-budget audit (kill gate)

The four `effect.mli` contracts include every required caveat: fiber-local
dynamic scope; fork inheritance; no join-merge; restoration on success, typed
failure, defect, and interruption; innermost wins; sibling isolation;
call-time consultation; in-flight sleep/open-span stability; daemon retention.

| Contract | Caveat prose lines | Nonblank lines including example |
| --- | ---: | ---: |
| `with_clock` | 6 | 7 |
| `with_random` | 8 | 8 |
| `with_logger` | 8 | 8 |
| `with_tracer` | 7 | 7 |
| **Total** | **29** | **30** |

The sealed budget was at most 30 prose lines. **Kill condition did not fire.**
`docs/zio-boundaries.md` adds the two-branch example and explains where the
override stops applying.

## W6 review packet

Artifacts: `.scratch/research/dx/e19/review/`.

- `w6-old.ml`: explicit `~sleep`/`~now_ms` test-runtime assembly.
- `w6-new.ml`: one `Effect.with_clock (Test_clock.as_capability clock)` around
  the retry assertion.
- Both drive exact 10/20/40 ms sleeps and assert virtual time 70 without wall
  time.
- Code-line census: **31 old vs 24 new (22.6% reduction)**. This misses the
  sealed 40% whole-fixture prediction, but removes all fake-clock wiring from
  runtime construction and makes the scope visible at the assertion.
- `QUESTIONS.md` contains the required teach-back prompts and reviewer key.

## Prediction score and census

Detailed scoring is in `journal.md`: **4.5 / 6**.

- Public census: observability cluster `+4 val`; clock type `+1 method` on the
  pre-existing class type.
- Three predicted traps: all recorded and disarmed.
- No new public footgun, fallback branch, compatibility shim, or environment.
- Implementation remained over the existing two backend local-binding
  mechanisms; jsoo needed parity tests, not a new local implementation.

## Evidence verdicts

- **A — four scoped combinators:** ACCEPTED.
- **B — runtime assembly baseline:** DOMINATED for lexical subtree testing;
  still valid for interpreter-wide configuration.
- **C — universal environment:** OUT OF SCOPE by Eta's boundary.
- **D — documentation-only recipe:** DOMINATED by executable lifecycle and
  isolation requirements.

Strongest remaining limitation: scoped random controls Effect-owned
retry/repeat jitter and runtime trace-ID generation. APIs that accept explicit
random tokens remain explicit, as the mli states. Low-level direct
`Runtime_contract` consumers retain their owner-domain contract rather than
being silently rewritten.

Final verdict: **READY FOR REVIEW / PROMOTE**.

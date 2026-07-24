# DX-E27 report — `Effect.logf` deferred-format logging

## Recommendation

**PROMOTE.** The semantic heart is proven: a disabled or minimum-filtered
`logf` never invokes its formatter and has exactly the same measured allocation
as an equivalent filtered prebuilt `log` chain. Enabled formatting happens once
and the resulting record follows the existing attrs/intercepts/sink pipeline.
All required Nix gates pass.

The sealed enabled allocation range was wrong: the measured enabled-minus-
disabled delta is 262.14254 minor words/record, not 10–100. This is reported
rather than hidden. It is enabled-only `Format` work; the experiment's off-path
criterion and feature recommendation still hold.

## Surface and encoding

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  ('a, Format.formatter, unit, (unit, 'err) t) format4 ->
  'a
```

The predicted type compiled unchanged on OxCaml 5.2.0+ox and upstream OCaml
5.4.1. `Format.kdprintf` eagerly receives ordinary OCaml arguments but captures
a delayed `Format.formatter -> unit` printer. Only inside the existing runtime
logger/minimum-level admission branch does `Format.asprintf "%t"` invoke that
printer and produce the body. A shared private helper then performs the existing
record construction and emission pipeline; `log` remains the pre-built-string
surface.

The public contract is ten lines including its documentation. It states the
eager-argument rule, Drop-after-format order, and raising-printer defect rule.

## Named behavioral evidence

The shared Observability suite registers these laws on every native runtime
adapter:

| Named test | Proven behavior |
| --- | --- |
| `logf disabled level does not invoke formatter` | No logger and minimum-filtered paths make zero printer, interceptor, and sink calls. |
| `logf enabled formats exactly once` | One `%a` printer call and body `db.find 42`. |
| `logf composes attrs and intercepts` | Scoped attrs precede per-call attrs; transformed body reaches the sink. |
| `logf Drop occurs after formatting` | Printer runs once; sink receives nothing. |
| `logf raising printer becomes defect` | The same exception appears in `Cause.Die`; sink receives nothing. |
| `logf arguments are eager at construction` | Argument count is already one before runtime execution. |

E22 registry rows R112–R115 map every new normative `effect.mli` claim to these
exact named registrations. Focused OxCaml/Eio result: PASS, 596 tests.

## Allocation measurement

Command:

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.log
```

| Row | Minor words/100k | Per emission |
| --- | ---: | ---: |
| prebuilt `log`, minimum-filtered | 2,097,146 | 20.97146 |
| `logf`, minimum-filtered | 2,097,146 | 20.97146 |
| `logf`, enabled | 28,311,400 | 283.11400 |
| enabled − disabled | 26,214,254 | 262.14254 |

Ten samples had zero minor-word variance. The disabled row adds **0 measured
minor words** over the equivalent filtered `log` blueprint: no formatted body
string and no log record are formed. Enabled execution invokes the printer once
and forms one body and one record; the minor-word delta also includes the
temporary machinery used by `Format`. Raw wall/minor/major samples are tracked
under `measurement/`.

## Red-team

All attacks passed (details in `redteam/VERDICT.md`): a `%a` printer that would
fail if touched remains untouched when disabled; enabled formatting cannot be
doubled; a filtered record cannot reach an interceptor; `Drop` is observed only
after formatting; a raising printer stays on ordinary defect capture; eager
argument work remains visible before `run`.

## Census and footguns

| Measure | Sealed prediction | Actual |
| --- | ---: | ---: |
| Public values | +1 | **+1** (`logf`) |
| Public types/modules/dependencies | +0 | **+0** |
| Logging concepts | +0 | **+0** (formatted spelling of `log`) |
| Disclosed traps | +2 | **+2** (eager args; Drop after format) |
| Undisclosed footguns | +0 | **+0** |

The raising-printer rule is also explicit and follows the existing `error_pp`
defect model rather than introducing a new trap or failure channel.

## Prediction scorecard

| Prediction | Result |
| --- | --- |
| Exact `format4` encoding | PASS |
| Gate inside logger + minimum admission | PASS |
| Disabled formatter/interceptor/sink calls are zero | PASS |
| Filtered `logf` within 1 word/emission of filtered `log` | PASS (exactly equal) |
| Enabled delta 10–100 minor words/emission | **FAIL** (262.14254) |
| Composition, Drop, defect, eager-args behavior | PASS |
| Census and footguns | PASS |
| All required gates | PASS |

## Gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force` | PASS |

Review packet: `review/log-old.ml`, `review/log-new.ml`, and
`review/QUESTIONS.md`.

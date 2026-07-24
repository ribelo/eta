# DX-E27 Journal — `Effect.logf` deferred-format logging

Branch: `research/dx-e27-logf`

## Predictions (sealed)

Sealed before API, implementation, test, benchmark, or review-packet edits.
Wrong predictions remain evidence; this section will not be rewritten.

### Encoding and placement

I predict the compiler-settled public type will be:

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  ('a, Format.formatter, unit, (unit, 'err) t) format4 ->
  'a
```

`Format.kdprintf` will consume the format and eager OCaml arguments while
capturing a delayed `Format.formatter -> unit` printer. The printer will be
rendered exactly once, with `Format.asprintf`, inside the same runtime
`logging_enabled` plus scoped-minimum admission branch used by `log`. It will
therefore not run at construction, when logging is disabled, or when the level
is below the scoped minimum. Record creation remains after formatting and the
record then follows the existing attrs -> intercepts -> sink pipeline.

### Allocation expectation

The watchlist will compare structurally identical, fully prebuilt 100k `logf`
chains at a minimum-filtered level and an enabled level. I predict:

- disabled formatting performs zero printer calls and adds no formatted string
  or log-record allocation; its measured minor words will be within 1 word per
  emission of an equivalent filtered prebuilt `log` chain;
- enabled formatting performs one printer call and creates one body string plus
  one log record per emission;
- enabled minus disabled will be positive and between 10 and 100 minor words per
  emission, including `Format` machinery and the existing emission pipeline.

The report will preserve measured totals and per-emission deltas rather than
calling the disabled path literally zero-allocation if runtime traversal has a
shared baseline.

### Behavioral and red-team predictions

- A side-effecting `%a` printer is untouched while disabled and called once
  while enabled.
- Scoped attrs precede per-call attrs before intercept transforms.
- `Drop` happens after the one formatting call and prevents the sink call.
- A raising `%a` printer becomes `Cause.Die` through ordinary capture.
- An intercept cannot bypass the level gate because it receives no filtered
  record.
- Ordinary format arguments remain eager at blueprint construction; only the
  formatting/printer application is deferred.

### Census / footgun prediction

| Measure | Delta |
| --- | ---: |
| Public values | **+1** (`logf`) |
| Public types/modules/dependencies | **+0** |
| Logging concepts | **+0** (formatted spelling of existing `log`) |
| Disclosed semantic traps | **+2** (eager args; Drop occurs after formatting) |
| Undisclosed footguns | **+0** |

Recommendation prediction: **PROMOTE** if the named laws, allocation
measurement, red-team probes, and all five Nix gates pass.

## Evidence (post-seal)

The compiler accepted the predicted encoding unchanged. `Format.kdprintf`
captures the delayed printer and `Format.asprintf "%t"` invokes it inside the
runtime admission branch. The six named laws pass on the shared Eio suite and
are registered as R112–R115 in the E22 executable-law registry.

The disabled allocation prediction passed exactly: filtered `log` and filtered
`logf` both measured 2,097,146 minor words/100k. The enabled-delta range
prediction failed: enabled `logf` measured 28,311,400 minor words/100k, a delta
of 26,214,254 or 262.14254 words/emission. The raw result is preserved in
`measurement/runtime-watchlist.txt`; the extra allocation is enabled-only
`Format` work and does not weaken the disabled-path claim.

All five required Nix gates passed. Red-team attacks passed, census matched
the seal, and no undisclosed footgun emerged. Detailed evidence and the
promotion recommendation are in `report.md`.

## Follow-up 2 — correction after review

### The sealed claim was wrong

The reviewer found that `Format.kdprintf` gives only partial deferral.
`CamlinternalFormat.make_printf` performs built-in conversions such as `%d`,
`%f`, `%S`, width, and precision while the variadic call is being applied.
Only `%a`/`%t` printers and final output assembly remain delayed. Credit to the
reviewer's discriminating probe: `"%1000000d"` allocated approximately 1 MB
before the delayed printer was invoked.

This corrects both sealed sources: the orchestrator's sealed complete-deferral
claim and my independent prediction were wrong. My first evidence suite failed
to see the error because every invocation counter used `%a`, the conversion
that actually is delayed, while the allocation watchlist reused one prebuilt
blueprint 100k times and therefore amortized construction away.

### Shape decision: closure API

The corrected surface is:

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  (Format.formatter -> unit) ->
  (unit, 'err) t
```

The formatter closure itself is invoked inside runtime admission. Therefore
built-in conversions, `%a`/`%t` printers, and argument-producing work written
inside the closure are all deferred. Work performed before calling `logf`
remains ordinary eager OCaml evaluation. The closure also retains captured
values for the blueprint's lifetime; a permanently filtered long-lived
blueprint therefore retains its captures, though it does not retain a formed
body string or record unless admitted.

The decision follows three review criteria:

1. It provides honest, complete deferral; `format4` cannot because
   `make_printf` is eager by design.
2. T2: the wrong thing looks wrong. The closure makes the deferred boundary
   visible, whereas the variadic format shape invited the false reading that
   fooled both sealed authors and the first suite.
3. T8: the closure's deferral contract is one sentence. The narrowed variadic
   contract spends three caveat sentences explaining its split semantics.

### Rejected alternative — exact proposed mli text

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  ('a, Format.formatter, unit, (unit, 'err) t) format4 ->
  'a
(** Formatted {!log}. [%a] and [%t] printers run only after runtime level
    admission. Built-in conversions and ordinary arguments are evaluated when
    the effect is built. Output assembly and record construction run after
    admission. *)
```

Rejected: this is accurate but not complete deferral, invites the wrong mental
model at the call site, and consumes the documentation budget on caveats for a
semantic that the closure API expresses directly.

### Corrected evidence

Named tests now discriminate `%d`, `%a`, and `%t` under disabled and enabled
admission, the million-width built-in case, inside-versus-outside work,
retention, composition, Drop ordering, and defect capture.

The corrected watchlist constructs every formatter closure and `logf` blueprint
inside each 100k measured run:

- filtered: 5,242,866 minor words/100k;
- enabled: 33,554,300 minor words/100k;
- enabled minus filtered: 28,311,434, or 283.11434 words/emission;
- filtered `%1000000d`: 5,242,866 minor words/100k, exactly equal to ordinary
  filtered construction, proving the million-character padding was not built.

All five required Nix gates passed again after the closure redesign, including
the separate `_build-mainline` build and laws run.

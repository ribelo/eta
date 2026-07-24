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

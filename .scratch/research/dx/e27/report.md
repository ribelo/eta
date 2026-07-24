# DX-E27 report — completely deferred formatter logging

## Recommendation

**PROMOTE the closure API.** `Effect.logf` now takes a
`Format.formatter -> unit` closure and invokes it once only after runtime logger
and minimum-level admission. Built-in conversions, `%a` printers, `%t` thunks,
and work placed inside the closure are all deferred. The corrected per-emission
measurement and all five required Nix gates pass.

**Reject the variadic `format4` API.** Review proved its deferral was partial:
`CamlinternalFormat.make_printf` eagerly performs built-in conversion while the
variadic call is applied. The first suite saw only lazy `%a` printers and the
first benchmark reused one blueprint, so both missed the defect. The journal
preserves the sealed mistake, the reviewer's million-width evidence, and the
exact rejected narrowed mli text.

## Final surface

```ocaml
val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  (Format.formatter -> unit) ->
  (unit, 'err) t
```

Use sites make the deferred boundary visible:

```ocaml
Effect.logf (fun fmt -> Format.fprintf fmt "db.find %d" id)
Effect.logf pp_db_find
```

The formatter is called inside the existing admission branch, after
`logging_enabled` and the scoped minimum check. The formed body and record then
follow the unchanged scoped attrs -> per-call attrs -> intercepts -> sink
pipeline. `Drop` can discard the record after formatting, and a raising
formatter follows ordinary defect capture.

Work inside the closure is deferred; work performed before `logf` is ordinary
eager OCaml evaluation. The blueprint retains values captured by its closure
for the blueprint's lifetime. Thus a permanently filtered long-lived blueprint
retains captures, but forms no body string or record.

## Review correction and shape decision

The reviewer used `"%1000000d"` to show that `Format.kdprintf` allocated about
1 MB before its delayed printer was invoked. This falsified the original
complete-deferral claim. The closure shape was selected because:

1. it gates the whole formatter invocation, including built-in conversions and
   argument-producing work inside the closure;
2. the deferred boundary is syntactically visible (T2), unlike a format call
   that misleadingly looks wholly deferred;
3. complete deferral takes one contract sentence (T8), while the accurate
   variadic alternative requires separate `%a`/`%t`, built-in, and output-stage
   caveats.

The exact rejected alternative and rejection reason are recorded append-only in
`journal.md`.

## Named behavioral evidence

| Named test | Discriminator |
| --- | --- |
| `logf disabled does not invoke builtin user or thunk formatters` | `%d` closure, `%a` printer, and `%t` thunk all remain at zero under no logger and minimum filtering; interceptor and sink also remain at zero. |
| `logf enabled invokes builtin user and thunk exactly once` | Each path is invoked exactly once and emits the expected three bodies. |
| `logf disabled defers million-width builtin conversion` | Filtered `%1000000d` closure is never entered. |
| `logf work inside formatter is deferred` | Inside work remains zero before and after a disabled run, then becomes one after an enabled run; prior work remains eager. |
| `logf blueprint retains formatter captures` | A weak reference confirms a closure capture remains live with the blueprint. |
| `logf composes attrs and intercepts` | Scoped attrs precede per-call attrs and the transformed body reaches the sink. |
| `logf Drop occurs after formatting` | Formatter count is one and sink count is zero. |
| `logf raising printer becomes defect` | The same exception appears in `Cause.Die`; sink count is zero. |

The focused OxCaml/Eio shared suite passes with 598 tests. E22 rows R112–R115
register every new normative claim. Census totals are reconciled: Effect
external rows 93 -> 97, overall external rows 110 -> 114, and total covered
rows 213 -> 217.

## Corrected allocation measurement

The corrected workload constructs each of 100k formatter closures and `logf`
blueprints during the measured run instead of reusing one prebuilt blueprint.

```sh
taskset -c 0 nix develop -c dune exec \
  bench/runtime_watchlist/runtime_watchlist.exe -- \
  --samples 10 --filter overhead.eta.logf
```

| Row | Minor words/100k | Per emission |
| --- | ---: | ---: |
| construction + minimum filter | 5,242,866 | 52.42866 |
| construction + enabled emit | 33,554,300 | 335.54300 |
| enabled minus filtered | 28,311,434 | 283.11434 |
| construction + filtered `%1000000d` | 5,242,866 | 52.42866 |

All ten samples in every row had zero minor-word variance. The adversarial
million-width row is exactly equal to ordinary filtered construction, proving
that its padding is not allocated on the disabled path. The disabled number is
the honest closure/blueprint construction and runtime traversal cost; it
contains no formatted body or log record. Enabled execution adds formatter,
body, record, and normal emission-pipeline allocations.

Corrected raw JSON is `measurement/runtime-watchlist.txt`. The superseded
prebuilt/format4 JSON remains as `measurement/runtime-watchlist-format4.txt` so
the evidence correction is auditable rather than overwritten.

## Red-team and review packet

Every attack passes; see `redteam/VERDICT.md`. The review packet now compares
`log` + `Printf.sprintf` with closure-form `logf` on three real-shaped sites and
asks when formatting runs, what happens to arguments, and what captures are
retained:

- `review/log-old.ml`
- `review/log-new.ml`
- `review/QUESTIONS.md`

## Census and footguns

| Measure | Final delta |
| --- | ---: |
| Public values | **+1** (`logf`) |
| Public types/modules/dependencies | **+0** |
| Logging concepts | **+0** (formatted spelling of `log`) |
| Removed misleading semantic | variadic call no longer implies complete deferral |
| Disclosed residual cost | formatter captures retained for blueprint lifetime |
| Undisclosed footguns | **+0** after follow-up review |

## Gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force` | PASS |

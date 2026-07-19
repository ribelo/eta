# DX-E7 Report — Error-renderer deriver in `ppx_eta`

## Recommendation

**PROMOTE.** `[@@deriving eta_error]` makes meaningful typed-failure telemetry
the short path while generating only an ordinary typed match. Wiring remains
explicit. The one-pager promotion gate is met: 100% example renderer coverage
and zero hand-written example `Format` error printers.

## Delivered surface

- `ppx_eta` structure deriver for closed polymorphic variants.
- Generated `pp_<type> : Format.formatter -> <type> -> unit`.
- Stable lowercase tag strings with underscores preserved.
- Built-ins: `string`, `int`, `int64`, `float`, `bool`.
- `[@eta.render f]` identifier escape hatch, including explicit override of a
  built-in renderer.
- PPX-time rejection with what/where/what-next messages; no payload placeholder.
- Explicit use through `Effect.named` / `Effect.fn` `?error_pp` or
  `Effect.with_error_pp`; no ambient policy.

## Gates

| Command | Attempts | Result |
| --- | ---: | --- |
| `nix develop -c dune build @install` | 1 | PASS |
| `nix develop -c dune runtest --force` | 1 | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | 1 | PASS |

No JS-track package contains newly generated code, so no mainline JS target was
required.

## Snapshot and golden-test evidence

- Eight positive printed expansions: nullary, all five built-ins, mixed, and
  custom override.
- Two complete compiler-error snapshots: unsupported payload and nominal
  variant.
- Total: **10 / 10 sealed fixtures**.
- Real Eio runtime + `Tracer.in_memory`: the same `Effect.fail (`Db 7)` has
  `Error "<typed failure>"` without a printer and `Error "db:7"` with generated
  `pp_err`.
- Raising custom printer through generated code becomes `Cause.Die`, preserving
  the E25 totality contract.

## Coverage census

| Surface | Before | After |
| --- | ---: | ---: |
| Hand-written example `Format` error printers | 47 | 0 |
| Derived declarations in examples | 0 | 54 across 49 files |
| Named/fn sites with direct generated `~error_pp` | 0 / 23 | 23 / 23 |
| Concrete derivable error declarations in docs | 0 | 0 |

Nested rows derive their own payload printer and use the documented escape
hatch. The signal example lists its public tags rather than requiring inherited
row expansion. Remaining string-returning `render_*` helpers serve business
mapping/output, not telemetry formatting.

## Census and footgun actuals vs predictions

| Measure | Sealed | Actual | Result |
| --- | ---: | ---: | --- |
| Snapshot fixtures | 10 | 10 | matched |
| PPX forms | +1 | +1 | matched |
| Footgun delta | -1 / +0 | -1 / +0 | matched |
| Eligible coverage | 100% | 100% | matched |
| Hand-written example error printers | 0 target | 0 | matched |

Observable predictions scored **5/5**. Predicted human ratings and reviewer
misreadings remain pending rather than being self-awarded; the review packet is
under `.scratch/research/dx/e7/review/`.

## Red-team outcome

1. **Placeholder attack:** rejected at PPX time; full error snapshotted.
2. **Raising printer:** real runtime returns `Cause.Die`.
3. **Tag rename:** consecutive commits change `db_down` to `database_down`,
   proving telemetry stability is honest and constructor-controlled.

Result: **3 / 3 passed**. See `.scratch/research/dx/e7/redteam/VERDICT.md`.

## Deviations

- Ppxlib's standard warning/Merlin include surrounds generated deriver items in
  printed AST. The enclosed `pp_<type>` is exactly the required typed plain
  match and is extracted verbatim in the review packet.
- Generated binders use fresh internal names instead of illustrative `fmt` /
  payload names to prevent capture by `[@eta.render f]` identifiers.
- Private polymorphic aliases fail early with guidance because a compile probe
  proved the generated binding cannot pattern-match them.

These deviations preserve rather than weaken the plain-match, syntactic, and
fail-loudly contracts.

# DX-E8 Report — `[%eta.result "name" body]` leaf sugar

## Recommendation

**PROMOTE.** The expansion is the hand-written form a reviewer would accept
verbatim: `Effect.fn __POS__ __FUNCTION__ (Effect.named "…" (Effect.sync_result
(fun () -> body)))`. Snapshots, parity, red-team, and all four gates pass.
Adoption followed a stated IO/trust boundary rule without dropping `~error_pp`
wiring.

## Delivered surface

- `[%eta.result "name" body]` via `expand_sync_like ~kind:"sync_result" ~form:"result"`.
- Form-named PPX rejection: `expected [%eta.result "name" body]`.
- Docs: README alongside `[%eta.sync]`, `docs/api-dx.md` leaf guidance,
  `docs/type-errors.md`.
- Expansion snapshot + two compile-error snapshots + runtime parity test.
- 12 example leaf conversions under the sealed adoption rule.

## Gates

| Command | Attempts | Result |
| --- | ---: | --- |
| `nix develop -c dune build @install` | 1 | PASS |
| `nix develop -c dune runtest --force` | 1 (+ focused re-runs after parity fix) | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | 2 (parity loc assertion fix) | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo` | 1 | PASS |

## Snapshot and parity evidence

- Positive printed expansion matches the sealed contract
  (`test/ppx_expansion/cases/i_result.ml`).
- Negatives: non-string name and wrong arity both report
  `expected [%eta.result "name" body]` (T7 what/where/what-next via form name +
  type-errors doc).
- Runtime parity (`test_ppx_result_parity`): Ok value, typed `Error (`Db 7)`, and
  `Cause.Die` match hand-written form; leaf span name `db.find`; source `loc`
  present on outer `fn` spans (identical to `Effect.fn` / `here_attr` placement).

## Adoption vs prediction

| | Sealed | Actual | Score |
| --- | ---: | ---: | --- |
| Example conversions | 10 | 12 | close (+2) |
| Remaining example `sync_result` | 16 | 14 | close (−2) |

Non-conversions are honest: `~error_pp`, dynamic names, lifecycle
acquire/release, pedagogical quickstart, and outer-named wrappers.

## Census and footgun actuals

| Measure | Sealed | Actual |
| --- | ---: | ---: |
| Leaf sugar forms | 1 → 2 | 1 → 2 |
| Rejection paths | +0 | +0 (shared path, form-named message) |
| Core vals | +0 | +0 |
| Footguns | +0 / +0 | +0 / +0 |

## Red-team outcome

1. Raising body → `Cause.Die` with `db.boom` error span.
2. Nested outer `Effect.named` → multi-span; documented noisy-but-harmless.
3. T9 audit: every identifier is use-site string/body or `__POS__`/`__FUNCTION__`.

Result: **3 / 3 passed**. See `.scratch/research/dx/e8/redteam/VERDICT.md`.

## Deviations

- Parity test asserts `loc` on outer `fn` spans, not on the inner named leaf —
  matches existing `Effect.fn` semantics (`here_attr` then `named`), not a sugar
  special case.
- Adoption slightly above sealed guess (12 vs 10) under the same rule.
- Reviewer ratings remain pending independent review; not self-awarded.

## Promote / hold / kill

Against the one-pager: promote with E1 (already promoted). Expansion needs no
explanation beyond the one-liner. **PROMOTE.**

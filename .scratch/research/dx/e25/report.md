# DX-E25 Report — Family consistency: `with_scope`, `named ?kind`, `now_ms`, `error_pp`

## Summary

| Before | After |
|---|---|
| `Effect.scoped` | `Effect.with_scope` |
| `named` + `named_kind ~kind` | `named ?kind ?error_pp` |
| `Effect.now` | `Effect.now_ms` |
| `with_error_renderer` / `?error_renderer` (`err -> string`) | `with_error_pp` / `?error_pp` (`Format.formatter -> 'err -> unit`) |

Deletions (no shims): `scoped`, `named_kind`, `now`, `with_error_renderer`,
`?error_renderer`. Default observability text remains `"<typed failure>"`.

Semantic edge: `error_pp` renders at most once per span status/exception event
(memoized by physical identity of the typed failure). A raising printer becomes
a defect through the ordinary capture path; the old
`"<error renderer raised>"` swallow is removed from that path.

## Gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/js_jsoo lib/jsoo` | PASS (existing integer-overflow warnings only) |

Focused development gate:

```text
nix develop -c dune runtest test/core_eio --force
502 tests run — PASS
```

No call sites found under `test/cache_jsoo` or `test/http_js` for this surface.
`signal_jsoo` left untouched (pre-broken per F1).

## Golden-test evidence

| Obligation | Evidence |
|---|---|
| Domain string from `error_pp` in span status | `named error_pp domain string` |
| Render-once (status + exception event share one pp call) | `error_pp render once` (counter == 1) |
| Raising `error_pp` → defect, not swallowed status | `error_pp raise becomes defect` |
| Optional omission yields `Effect.t` | `named optional omission yields effects` |
| Migrated status / kind / finalizer rendering | existing observability + supervisor suites |

## Census and footgun actuals

Independent post-migration census from `effect.mli`:

| Metric | Before | Actual after | Delta |
|---|---:|---:|---:|
| Observability-cluster public vals (`named`, `named_kind`, `with_error_renderer`, `now`) | 4 | 3 (`named`, `with_error_pp`, `now_ms`) | −1 |
| Lifecycle resource-scope name outside `with_*` (`scoped`) | 1 | 0 (`with_scope`) | rename; family uniform |
| Net public vals for E25 surface | — | — | −1 (`named_kind` only) |

**Footgun delta: −1 / +0.** The `named` vs `named_kind` choice is gone. No new
trap counted: optionals are erasable before the mandatory name/effect;
`now_ms` states units; `with_*` lifecycle naming is uniform; default status text
unchanged.

## Prediction scoring

| Prediction | Actual | Score |
|---|---|---|
| Net public vals −1 | Exact | hit |
| Footguns −1/+0 | Exact | hit |
| Lifecycle family uniform `with_*` | `with_scope` + `with_error_pp` | hit |
| Omission calls type as `Effect.t` | Erasure probe compiles | hit |
| Raising pp → defect | Golden test | hit |
| Render-once | Golden test | hit |
| Gates green; `signal_jsoo` untouched | Exact | hit |
| Possible `with_scope` vs `Supervisor.scoped` confusion | Not observed in gates; vocabulary collision remains as adjacent follow-up only | partial (predicted scrutiny, no revert evidence) |

## Red-team

Artifacts: `.scratch/research/dx/e25/redteam/`.

1. Raising `error_pp` → defect + closed span: **PASS**.
2. `named`/`named_kind` dual-verb bug unwriteable: **PASS**.

## Review

Packet: `.scratch/research/dx/e25/review/` (two A/B pairs, manifest, questions).

## Deviations and follow-ups

- Public printer type is `Format.formatter -> 'err -> unit` as specified; internal
  frame field remains an `Obj.t -> string` renderer built by
  `Format.asprintf "%a" pp` with a one-shot memo cache.
- Span close path catches a raising printer, finishes the span with a defect
  status, then re-raises via the ordinary cause path so open spans do not leak.
- `Supervisor.scoped` and prose “scoped” (subscription, nursery) intentionally
  unchanged; only `Effect.scoped` renamed.
- Adjacent follow-up (not in E25 scope): whether `Supervisor.scoped` should later
  join the `with_*` family for full vocabulary uniformity.

## Per-rename recommendation

| Change | Recommendation |
|---|---|
| `scoped` → `with_scope` | **Promote** — lifecycle family consistency; no gate/review evidence to revert |
| merge `named_kind` into `named ?kind` | **Promote** — footgun removed; erasure holds |
| `now` → `now_ms` | **Promote** — unit explicit; aligns with runtime `?now_ms` |
| `with_error_renderer` / `?error_renderer` → `with_error_pp` / `?error_pp` | **Promote** — Format culture fit; render-once + defect contract proven |

**Overall: promote the full E25 package.**

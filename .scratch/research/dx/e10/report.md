# DX-E10 Report — Function-level `let%eta` / `[@@eta.trace]`

## Recommendation

**HOLD.**

Both spellings are implemented, share one expansion path, pass expansion
snapshots, error-location corpus, red-team, `.mli` invariance, and the three
Nix gates. Technical success does **not** clear the one-pager promote bar:

- Hold is the pre-registered default even on success.
- Frequency: `Effect.fn __POS__` appears at **5** sites, all in tests; E8's
  `[%eta.result]` already absorbed the leaf boilerplate this sugar targeted.
- T4 (sugar follows demonstrated frequency) is not met.
- Promote requires independent reviewers still asking after E7/E8; this report
  does not self-award that demand.

Kill gate (error locations ≤ 3 and unimprovable) **does not fire** — corpus
rates **4–5**.

## Delivered surface (experiment only)

- `let%eta` structure-item and expression extension (`eta`).
- `[@@eta.trace]` value-binding attribute via `~impl` structure mapper.
- Shared `wrap_result_position` → `Eta.Effect.fn __POS__ __FUNCTION__ body`
  after all parameters (`Pexp_function` result body; `let rec` wrapper inside).
- Expansion snapshots `j_`–`o_` in `test/ppx_expansion/`.
- Error corpus: wrong return type, non-effect body (`let%eta` + attr), deep body
  type error in `test/type_errors/`.
- Runtime parity + rec span tests in `test/ppx_common/ppx_common_suites.ml`.
- Research artifacts under `.scratch/research/dx/e10/` (this report, journal,
  redteam, review, mli_invariance).

No mass call-site conversion; no docs promotion (scope fence).

## Gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (after rec-span name suffix fix) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |

PPX is compile-time; no JS-track impact observed.

## Expansion corpus

Printed expansions match the sealed one-liner shape:

| Case | File | Shape |
| --- | --- | --- |
| Plain | `j_let_eta_plain.ml` | `let f x = Eta.Effect.fn __POS__ __FUNCTION__ (…)` |
| Labeled | `k_let_eta_labeled.ml` | params preserved; wrap on body |
| Optional | `l_let_eta_optional.ml` | `?(flag= false)` preserved |
| `let rec` | `m_let_eta_rec.ml` | wrapper **inside** recursive body |
| Curried | `n_let_eta_curried.ml` | `let f x y z = … fn …` |
| Attribute | `o_eta_trace_attr.ml` | identical to plain |

Reviewer-acceptable verbatim hand form (T4 expansion bar): **yes**.

## Error-location corpus + kill gate

| Case | Loc points to | Rating (1–5) |
| --- | --- | ---: |
| Wrong return type | body / pure application | 4 |
| Non-effect body (`let%eta`) | the `1` | 4 |
| Non-effect body (`[@@eta.trace]`) | the `1` | 4 |
| Deep body `1 + "x"` | the `"x"` | 5 |

Aggregate vs kill gate (≤ 3): **pass (no kill)**. Residual: messages speak in
`Effect.t` terms rather than naming the sugar form — representation-level and
acceptable; not improvable without inventing custom type errors.

## Frequency analysis

| Measure | Value |
| --- | ---: |
| `Effect.fn __POS__` sites (non-scratch tree) | 5 |
| In tests | 5 |
| In production `lib/` | 0 |

Sites:

1–3. `test/ppx_common/ppx_common_suites.ml` (hand parity for result sugar)
4. `test/core_common/observability_common_suites.ml` (`test_observability_fn_loc`)
5. `test/core_common/effect_common_suites.ml` (`diagnostic.fn` with custom name)

After E8, definition-site `fn` is rare. Sugar would mainly decorate pedagogical
or diagnostic tests.

## Red-team

See `.scratch/research/dx/e10/redteam/VERDICT.md`.

- Non-effect body: honest type error on user body (4/5).
- `let rec`: per-call spans (4 spans for `countdown 3`); documented.

## `.mli` invariance

`.scratch/research/dx/e10/mli_invariance/`: hand / `let%eta` / `[@@eta.trace]`
all compile against the same `.mli` (`run.sh`).

## Predictions scored

| Prediction | Actual | Score |
| --- | --- | --- |
| Expansion is one-liner `fn __POS__ __FUNCTION__ body` | Yes | hit |
| Error locs aggregate ~4, kill unfired | 4–5, unfired | hit |
| Frequency 5 sites / tests only | Confirmed | hit |
| Review / gate recommendation HOLD | HOLD | hit |
| `let rec` re-enters `fn` per call | Confirmed in suite | hit |

## Promote / hold / kill against one-pager

| Gate | Result |
| --- | --- |
| Hold by default even on success | **Applies → HOLD** |
| Promote only if reviewers still ask after E7/E8 | Pending independent cohort; not self-awarded |
| Kill if error locs ≤ 3 unimprovable | **Does not fire** |

**Author recommendation: HOLD.** Ship neither spelling unless the review cohort
explicitly requests one form despite the five-site census. If a future cohort
promotes, choose **one** spelling (prefer `let%eta` for visibility of sugar at
the definition keyword, or `[@@eta.trace]` for lighter syntax — defer to
reviewers).

## Deviations / notes

- `__FUNCTION__` under nested functors may be a qualified path (suite asserts
  suffix `countdown`), matching existing `[%eta.fn]` behaviour — not E10-
  specific.
- Attribute consumption uses `Driver.register_transformation ~impl` because
  value-binding attributes are not fully covered by `Rule.attr_replace` for
  structure `let`s in the needed way; extension rules remain context-free.
- Snapshot script for type_errors now also passes `-I` eta CMI for `ppx_*`
  cases (compatible with existing stub-only PPX negatives).

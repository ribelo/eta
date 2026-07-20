# DX-E10 Journal — Function-level `let%eta` / `[@@eta.trace]`

Branch: `research/dx-e10-function-sugar`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e10`
Phase: C (syntax & PPX) · Effort M · Risk med · **default state: HOLD**

## Predictions (sealed)

Sealed before implementation, expansion fixtures, error corpus, red-team,
review packet, or report edits. Wrong predictions stay as evidence; this
section will not be edited after its commit.

### Decision under test

Should Eta ship definition-site sugar for `Effect.fn __POS__ __FUNCTION__ body`
as either `let%eta f x = body` or `let f x = body [@@eta.trace]`?

One-pager gates (from objective):

- **Hold by default** even on technical success.
- Promote only if reviewers still ask for it after E7/E8.
- Kill if generated-code error locations rate ≤ 3 and cannot be improved.

T4: sugar follows demonstrated frequency. Pre-change census (this worktree):
`Effect.fn __POS__` appears at **5 sites** (3 in `test/ppx_common`, 1
observability suite, 1 effect/runtime diagnostic suite). Leaf boilerplate that
motivated earlier sugar is already absorbed by `[%eta.result]` / `[%eta.sync]`.

### Expected expansion shapes

Both spellings share one expander. Result-position wrapping only (after all
parameters, including labeled/optional); `let rec` keeps the wrapper *inside*
so recursive calls re-enter `fn`.

```ocaml
let%eta f x = body
(* and *)
let f x = body [@@eta.trace]
(* both expand to the one-liner shape: *)
let f x = Eta.Effect.fn __POS__ __FUNCTION__ body
```

Labeled / optional:

```ocaml
let%eta f ?(flag = false) ~name x = body
(* -> *)
let f ?(flag = false) ~name x = Eta.Effect.fn __POS__ __FUNCTION__ body
```

`let rec`:

```ocaml
let%eta rec countdown n =
  if n <= 0 then Effect.pure () else countdown (n - 1)
(* -> wrapper on the recursive body; each recursive entry re-enters fn *)
let rec countdown n =
  Eta.Effect.fn __POS__ __FUNCTION__
    (if n <= 0 then Effect.pure () else countdown (n - 1))
```

Multi-arg currying is ordinary OCaml desugaring of the binding; the sugar
still wraps only the final body expression, not intermediate arrows.

Generated identifiers: only `__POS__`, `__FUNCTION__`, and the use-site body
(T9). No fresh symbols, no inferred names, no kwargs (`~kind`, `~error_pp`,
`~attrs` stay out of sugar).

`.mli` signatures unchanged: wrapper is representation-level on the RHS.

Malformed / rejected:

- `[@@eta.trace]` with a non-empty payload → PPX error naming the form.
- `let%eta` on non-function / unsupported binding shapes → PPX error naming
  the form (or a clear "expected function binding" message).

### Error-location quality prediction

| Case | Predicted loc quality (1–5) | Notes |
| --- | ---: | --- |
| Wrong return type at binding | 4 | type error should point at body or pattern, not ghost `fn` apply |
| Non-effect body (`int` / bare value) | 4 | error on body expression; ghost-loc risk medium if body loc is not preserved |
| Type error deep inside body | 5 | body locations preserved; sugar should be transparent |
| Aggregate against kill gate (≤3) | **4** | expect **not** to kill; residual ghost risk only on the synthetic `fn` node itself |

Prediction: kill gate does **not** fire. Residual ghost locations on the
synthetic `Eta.Effect.fn` application node are acceptable if user-authored
subexpressions keep their source locations.

### Snapshot / corpus prediction

| Fixture class | Count |
| --- | ---: |
| Expansion: plain function | 1 |
| Expansion: labeled args | 1 |
| Expansion: optional args | 1 |
| Expansion: `let rec` | 1 |
| Expansion: multi-arg currying | 1 |
| Expansion: attribute twin of plain | 1 (shared path proof) |
| Error corpus: wrong return type | 1 |
| Error corpus: non-effect body | 1 |
| Error corpus: deep body type error | 1 |
| `.mli` invariance probe | 1 pair (hand vs sugar) |
| Red-team: non-effect body message quality | 1 |
| Red-team: `let rec` span semantics via tracer | 1 |

### Frequency analysis prediction

| Measure | Value |
| --- | ---: |
| `Effect.fn __POS__` sites (repo, non-scratch) | **5** |
| Of which tests | **5** (all test helpers / suite cases) |
| Production `lib/` definition sites needing sugar | **0** observed |
| Sites that `[%eta.result]`/`[%eta.sync]` already cover better | most former leaf wrappers |

Conclusion prediction: frequency alone fails T4 for definition sugar. A/B
review is still required for the promote-exception path ("reviewers still ask").

### Expected review outcome

| Material | Prediction |
| --- | --- |
| Expansion readability | 5/5 (one-liner) |
| Guess-the-semantics ("what does it expand to?") | most reviewers recover `Effect.fn` |
| "Behaviour vs tracing only?" | correctly: tracing/span only |
| "Would you reach for this at 5 sites?" | **No** for most reviewers |
| **Gate recommendation** | **HOLD** |

Two likeliest reviewer misreadings:

1. **“`let%eta` turns any OCaml body into an effect.”** No — body must already
   be `('a,'err) Effect.t`; sugar only wraps with `fn` for span/loc.
2. **“`let rec` spans once for the whole recursion.”** No — wrapper is inside;
   each recursive entry creates a new `fn` span (document in red-team).

### Promote / hold / kill prior

Predict **HOLD**:

- Technical implementation succeeds (expansions exact; error locs > 3).
- Kill gate unfired.
- Frequency evidence (5 sites, tests only) fails T4 demonstrated-frequency.
- Hold is the one-pager default even on success; promote needs post-E7/E8
  reviewer demand that this experiment does not self-award.

Would change to promote only if independent review cohort explicitly asks for
the sugar despite the census. Would change to kill only if error locations
rate ≤ 3 after location-discipline fixes.

### Implementation shape prediction

- One shared body-wrap helper: `Effect.fn __POS__ __FUNCTION__ body` (reuse
  `expand_fn` / same AST as `[%eta.fn]`).
- `let%eta`: structure-item extension rewriting `Pstr_value` bindings.
- `[@@eta.trace]`: value-binding attribute via `Rule.attr_replace` on
  expression context is insufficient; implement via value-binding attribute
  consumed in a structure mapper, or `attr_replace` if expression-context
  placement works for binding attributes — verify during implement.
- No docs promotion, no mass call-site conversion (scope fence).

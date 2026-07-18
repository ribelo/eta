# DX-E25 Journal — Family consistency: `with_scope`, `named ?kind`, `now_ms`, `error_pp`

Branch: `research/dx-e25-family-consistency`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e25`
Phase: A (idiom pass)

## Predictions (sealed)

Sealed before any code or signature edits. Wrong predictions stay as data; this
section will never be edited after the predictions commit.

### Teach-back expected answers

1. **Which combinator opens a resource scope?**
   `Effect.with_scope`. Resources registered with `acquire_release` inside
   `with_scope` release when the scope exits (success, typed failure, defect,
   cancellation), reverse-order. Nested scopes release inside-out. The old name
   was `scoped`; lifecycle helpers are uniform `with_*`.

2. **What does `error_pp` change, and what stays `"<typed failure>"`?**
   `error_pp` is a `Format.formatter -> 'err -> unit` printer injected as
   diagnostic policy for span status and exception-event messages (and rendered
   finalizer diagnostics that already used the renderer). The typed error value
   itself is unchanged and remains on the `Effect.t` error channel. When no
   `error_pp` / `with_error_pp` is installed, observability still shows the
   default `"<typed failure>"` string. Omission of `?error_pp` on `named`/`fn`
   does not change that default.

3. **Is `now_ms` wall time?**
   No. `Effect.now_ms` reads the active monotonic runtime clock in milliseconds
   (runtime elapsed time). Runtime constructors and tests override it with their
   existing `?now_ms` argument. It is not wall/civil time.

4. **When is `error_pp` invoked, and what if it raises?**
   Rendered at most once per span status/exception event for a given failure
   path (no double-render across status + exception event for the same failure
   presentation). The printer must be total. A raising `error_pp` becomes a
   defect through the ordinary capture path — telemetry degrades honestly
   rather than swallowing the raise into a fallback status string.

5. **How do `named` and the old `named_kind` relate?**
   One verb: `named ?kind ?error_pp name body`. `?kind` defaults to the old
   `named` default (`Internal`). Choosing between `named` and `named_kind` is
   unwriteable after the merge; `named_kind` is deleted with no shim.

### Expected census / footgun deltas

Independent pre-census of the observability/lifecycle rename cluster on the
public `effect.mli` surface:

| Metric | Before | Predicted after | Delta |
|---|---:|---:|---:|
| Observability-cluster public vals (`named`, `named_kind`, `with_error_renderer`, plus clock `now`) | 4 | 3 | −1 |
| Lifecycle resource-scope val names outside uniform `with_*` (`scoped`) | 1 | 0 | −1 |
| Uniform lifecycle `with_*` resource/scope openers (`with_resource`, `with_resource_exit`, `with_background`, `with_scope`, `with_error_pp`) | mixed (`scoped` + `with_error_renderer`) | uniform `with_*` | 0 net vals; naming family uniform |

Before observability-ish vals counted for the −1 claim: `named`, `named_kind`,
`with_error_renderer` (3) collapsing to `named`, `with_error_pp` (2) is −1 val
in the named/render pair; separately `now` → `now_ms` is a rename (0 val
delta); `scoped` → `with_scope` is a rename (0 val delta). Net public-val
delta for the whole E25 surface: **−1** (loss of `named_kind` only).

**Footgun delta:** expect **−1 / +0**.

- Removed trap: guessing `named` vs `named_kind` for span kind, and remembering
  that only one of the pair accepted `~kind` while both accepted
  `?error_renderer`.
- No new trap predicted: `?kind` and `?error_pp` sit before the mandatory
  `string` and effect (erasable); `now_ms` unit is in the name; `with_scope` /
  `with_error_pp` match the lifecycle `with_*` family; default remain
  `"<typed failure>"`.

### Two likeliest reviewer misreadings

1. **“`now_ms` is wall-clock epoch milliseconds.”**
   The intended reading is monotonic runtime elapsed ms via the active runtime
   clock, same as old `now`. The `_ms` suffix only makes the unit explicit and
   aligns with runtime `?now_ms`.

2. **“A raising `error_pp` still yields `"<error renderer raised>"` status and
   preserves the original typed failure.”**
   That is the *current* pre-E25 behavior of `error_renderer`. E25 changes the
   contract: a raising pp becomes a defect via the ordinary capture path. Tests
   must prove defect, not the old fallback string. Render-once is a separate
   obligation: status and exception-event presentation must not re-run a
   side-effecting pp twice for one event pair in a way that double-renders.

### Migration / parity prediction

- Compiler-guided migration removes every public occurrence of `scoped` (as
  `Effect.scoped`), `named_kind`, `with_error_renderer`, `?error_renderer`, and
  `Effect.now` (the effect val), including docs code blocks and the
  `lib/jsoo/eta_jsoo.mli` cross-reference wording that mentions
  `{!Eta.Effect.now}`.
- `Supervisor.scoped` and other non-`Effect.scoped` “scoped” prose remain;
  only the Effect resource-scope combinator renames.
- Call-site shape for renderers changes from `err -> string` to
  `Format.formatter -> err -> unit`. Existing string renderers migrate with
  `Format.pp_print_string fmt (render err)` or equivalent.
- Omission calls `named "x" eff`, `named ~kind:k "x" eff`, and
  `named ~error_pp:pp "x" eff` all type as `Effect.t` (erasure probe).
- Golden tests: domain string from `error_pp` appears in span status; render
  once; raising pp surfaces as defect.
- Predict native gates green; mainline `test/js_jsoo` + `lib/jsoo` green;
  `signal_jsoo` remains pre-broken and untouched.

### Promote/hold/kill prior

Predict **promote all four renames/merges** (`with_scope`, merged `named`,
`now_ms`, `with_error_pp` / `?error_pp`) if gates pass, golden tests close the
render contract, census is −1 val / footgun −1/+0, and red-team shows the old
`named`/`named_kind` choice is unwriteable while raising `error_pp` defects
honestly. Revert only a single rename if evidence shows genuine confusion
(most likely candidate to scrutinize: `with_scope` vs remaining
`Supervisor.scoped` vocabulary collision); do not hold the whole package for
one name.

---

## Execution log

### Step 1 — seal predictions

This section was committed before API or implementation edits.

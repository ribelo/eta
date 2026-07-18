# DX Phase B batch 1 — sealed predictions (E1 / E2 / E3)

Branch: `research/dx-e1e2e3-hygiene`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e1e2e3`
Phase: B (hygiene)

**Sealed before any code or signature edits for E1/E2/E3.** Wrong predictions
stay as data; this section is never edited after the predictions commit.

Evidence IDs (orchestrator): `V-DX-E1-*`, `V-DX-E2-*`, `V-DX-E3-*`.
Per-experiment journals/reports live under `e1/`, `e2/`, `e3/` and may
reference this seal.

---

## E1 — `sync_result` / `sync_option` (additive)

### Teach-back expected answers

1. **What does `sync_result` do that `sync` alone does not?**
   It composes the recommended leaf: `sync` (exceptions → `Cause.Die`) then
   flattens a returned OCaml `result` into the typed failure channel. Success
   is `Ok x`; typed failure is `Error e`; a raised exception is still a defect,
   not a typed failure.

2. **Does `sync_result` catch exceptions into the typed channel?**
   No. Same defect model as `sync` / `Eta_blocking.run_result`: ordinary
   exceptions become `Die`; only an explicit `Error e` becomes typed failure.
   If a persona expects catch-into-typed, the kill/rename gate fires toward
   `attempt_result`.

3. **How does `sync_option` relate to `from_option`?**
   Same `if_none:` label and `None` → typed failure semantics, but for a
   synchronous thunk. `Some x` → success; raised exceptions → `Die`.

4. **Does `flatten_result` go away?**
   No. It remains for hand-rolled pipelines after any effect that yields a
   `result`, not only the sync leaf. `sync_result` only names the recommended
   two-step leaf.

### Expected census / footgun deltas

| Metric | Before | Predicted after | Delta |
|---|---:|---:|---:|
| Construct-cluster public vals (`from_result`, `from_option`, `flatten_result`, `sync`, +new) | 4 | 6 | +2 |
| Construct-cluster concepts (sync leaf, typed-result leaf, option leaf) | ~3 | ~4 | +1 concept (`sync_result`/`sync_option` as named sync-typed leaf) |

**Footgun delta:** **−1 / +0**.

- Removed trap: forgetting the second combinator on the recommended leaf
  (`sync` alone leaves a nested `result`, or people invent ad hoc exception
  mapping).
- No new trap predicted if docs keep the Die-vs-typed boundary explicit; the
  kill gate watches for the name teaching attempt-model.

### Two likeliest reviewer misreadings

1. **`sync_result` converts raised exceptions into typed `Error`.**
   Intended: only `Error e` is typed; raises are defects. Red-team must show
   `Die`.

2. **`flatten_result` is deprecated / every `sync |> flatten_result` must migrate.**
   Intended: only recommended-leaf docs/examples re-point; hand-rolled
   flatten stays.

---

## E2 — `discard` + generalized `ignore_errors` (breaking)

### Teach-back expected answers

1. **What does `discard` do to typed failures?**
   Nothing special: all causes (typed failure, defect, interruption, finalizer
   diagnostics) propagate unchanged. Only the success value becomes `()`.

2. **What does `ignore_errors` do to defects?**
   Defects remain visible (as do interruption and finalizer diagnostics). Only
   typed failures are suppressed; success values of any type are discarded to
   `()`.

3. **Why was `Effect.ignore` deleted?**
   It combined value-discard with typed-failure suppression under a name that
   reads like `Stdlib.ignore` (which suppresses nothing about failures). The
   honest split is `discard` vs `ignore_errors`.

4. **Is generalizing `ignore_errors` source-breaking for unit effects?**
   No for correct unit-typed call sites: `(unit, _) t` still works. The old
   value-and-suppress spelling moves to the explicit pair after deleting
   `ignore`.

### Expected census / footgun deltas

| Metric | Before | Predicted after | Delta |
|---|---:|---:|---:|
| Handle-cluster vals involving ignore/discard | `ignore` + `ignore_errors` (2) | `discard` + `ignore_errors` (2) | −1 val (`ignore`) +1 val (`discard`) = 0 net; transform +1 concept honesty |
| Transform: pure success discard without recovery | 0 named | 1 (`discard`) | +1 |

Objective census prediction: handle −1 val + transform +1 val.

**Footgun delta:** **−1 / +0**.

- Removed trap: `Effect.ignore` sounding like `Stdlib.ignore` while swallowing
  typed failures.
- No new trap: both names state the policy; swallowed-error cleanup must spell
  `ignore_errors` explicitly.

### Two likeliest reviewer misreadings

1. **`discard` also suppresses typed failures (old `ignore` muscle memory).**
   Tests must show typed failure still fails.

2. **`ignore_errors` on a non-unit success is a type error or still requires
   prior `map` to unit.**
   Intended: generalized signature discards any success value.

### Hold-gate prediction

Migration of the 7 `ignore` uses: all are behavior tests of the combined
meaning. Expect split into `discard` tests and `ignore_errors` tests; no
production call sites. Hold only if evidence shows most uses wanted
value-discard alone — then reassess naming, not the split. Prediction: no hold.

---

## E3 — `race_either` (additive)

### Teach-back expected answers

1. **Why not always use `race`?**
   `race` needs a uniform success type. Heterogeneous branches force map-
   wrapping both sides into a shared variant; `race_either` tags the winner as
   `` `Left `` / `` `Right ``.

2. **Which side is `` `Left ``?**
   The first argument wins as `` `Left of 'a ``; the second as `` `Right of 'b ``.

3. **Loser cancellation / resources?**
   Same as `race`: first success wins; losers cancelled; resource lifetime
   owned by scopes; permit-acquisition caveat copied from `race` verbatim.

4. **Shared error channel?**
   Both branches share `'err`; typed failures from the race still follow
   `race` semantics (all-fail concurrent causes, etc.).

### Expected census / footgun deltas

| Metric | Before | Predicted after | Delta |
|---|---:|---:|---:|
| Concurrency public vals (`race`, +new) | 1 in race family | 2 | +1 |
| Concurrency concepts (homogeneous race, heterogeneous race) | 1 | 2 | +1 |

**Footgun delta:** **+0** (predicted). Naming tags are positional; kill gate
if reviewers find named variants at call sites clearer than `` `Left``/`` `Right ``.

### Two likeliest reviewer misreadings

1. **`` `Left `` is the left-of-screen / faster branch rather than the first
   argument.**
   Intended: first argument = Left, second = Right, independent of finish order.

2. **`race_either` changes cancellation or permit semantics relative to `race`.**
   Intended: pure success-type tagging over the same race engine.

---

## Shared gate predictions

All three experiments pass:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo lib/http_js
```

`signal_jsoo` stays pre-broken / untouched.
`docs/api-dx.md` re-points recommended leaf to `sync_result`.
CHANGELOG idiom-pass entry extends with E2 only (E1/E3 additive; E2 breaking).

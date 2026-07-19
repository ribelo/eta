# DX-E8 Journal — `[%eta.result "name" body]` leaf sugar

Branch: `research/dx-e8-eta-result-sugar`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e8`
Phase: C (syntax & PPX) · Effort S · Risk low

## Predictions (sealed)

Sealed before documentation, implementation, test, or example edits. Wrong
predictions stay as evidence; this section will not be edited after its commit.

### Expected expansion shape

```ocaml
let user = [%eta.result "db.find" (Db.find db id)]
(* expands to *)
Effect.fn __POS__ __FUNCTION__
  (Effect.named "db.find" (Effect.sync_result (fun () -> Db.find db id)))
```

This reuses `expand_sync_like ~kind:"sync_result"` exactly as `[%eta.sync]` reuses
`~kind:"sync"`. Generated identifiers are only `__POS__`, `__FUNCTION__`, the
string name from the use site, and the body expression from the use site (T9).
No fresh symbols, no ambient policy, no inferred names.

Malformed payloads fail at PPX time with a form-named message, e.g.
`expected [%eta.result "name" body]` (mirrors the existing
`expected [%eta.sync "name" body]` path, generalized to name the actual form).

### Snapshot / parity corpus prediction

| Fixture class | Count |
| --- | ---: |
| Positive expansion (`[%eta.result "…"]` exact contract) | 1 |
| Negative: non-string name | 1 |
| Negative: wrong arity / bare payload | 1 |
| Behavioral parity (Ok / Error / exception + span name + loc) | 1 suite case |
| **Expansion snapshot fixtures** | **1 positive** (in `test/ppx_expansion/`) |
| **Compile-error snapshots** | **2** (in `test/type_errors/`) |

The existing expansion corpus is deriver-only; the result positive case joins it
as one additional printed expansion. Negatives join the type-error compile
corpus next to `ppx_sync_nonstring.ml`.

### Adoption rule (stated before conversion)

Convert a `sync_result` leaf to `[%eta.result "name" body]` only when all of:

1. The leaf crosses an IO / trust / domain boundary (lookup, load, decode,
   request, external call) — not pure glue, not acquire/release plumbing.
2. A **static** span name is meaningful and fixed at the call site.
3. The site does **not** need `~error_pp`, dynamic names, `~kind`, or other
   `fn`/`named` kwargs the sugar cannot express.

Otherwise leave the hand-written form. Sites that already use
`Effect.named ~error_pp:…` keep that explicit wiring (E7 contract); sugar does
not carry `error_pp`.

### Adoption count guess

Pre-census: **56** `sync_result` textual hits across shipped tree (examples,
tests, docs strings, lib definition); **26** real call sites in `examples/`;
**45** `Effect.sync_result` hits excluding definition/docs noise.

Of the **26 example call sites**, predict **10 converted** under the rule above
(domain/IO leaves with static names and no special kwargs). Remaining 16 stay
hand-written (lifecycle glue, dynamic names, `~error_pp` sites, demo leaves
that intentionally show the primitive, or pure-result helpers without a
boundary story).

Operator count on converted sites: **4 → 1**
(`fn` + `named` + `sync_result` + thunk → `[%eta.result]`), or **2 → 1** when
the site was bare `sync_result` without naming (sugar adds span+loc as the
point of the conversion).

### Census table prediction

| Measure | Before | After | Delta |
| --- | ---: | ---: | ---: |
| PPX forms (`eta.fn`, `eta.sync`, `eta.sql.table`, `eta_error`, +result) | 4 | 5 | **+1** (forms 1→2 leaf sugars: sync+result; total PPX surfaces 4→5) |
| Leaf sugar forms (`eta.sync`, `eta.result`) | 1 | 2 | **+1** |
| Rejection paths (sync-like malformed) | 1 shared | 1 shared (message names form) | **+0** |
| Core vals (`Effect.sync_result` etc.) | unchanged | unchanged | **+0** |
| Footguns removed / added | — | — | **+0 / +0** |

Candidate footgun noticed but not counted as introduced: nesting
`[%eta.result]` inside an outer `Effect.named` produces two spans for one leaf
(noisy-but-harmless). Document in red-team; do not add runtime guards.

Objective census wording "PPX forms 1 → 2" is read as the leaf-sugar pair
(`sync` → `sync`+`result`).

### Expected review ratings

| Material | Rating |
| --- | ---: |
| Expansion readability / PR approval | 5/5 (verbatim hand-written form) |
| Heavy-module screenshot clarity | 4/5 |
| Contract docs (≤8 lines) | 5/5 |

### Two likeliest reviewer misreadings

1. **“`[%eta.result]` is for any `result` value, including already-computed
   pure results.”** No — it is the synchronous leaf sugar over
   `Effect.sync_result`. Already-computed results stay on
   `Effect.from_result` / `flatten_result`. The body runs inside a thunk and
   exceptions become `Cause.Die`.
2. **“The span name is inferred from the body / function name.”** No — the
   name is the string literal at the use site (T9). `__FUNCTION__` only feeds
   the outer `Effect.fn` location span, same as `[%eta.sync]`.

### Promote / hold / kill prior

Predict **promote** if: expansion matches the sealed shape, both negative
messages name the form, parity shows Ok/Error/Die + span name + loc, adoption
follows the stated rule with honest non-conversion reasons, red-team (a)(b)(c)
pass, census/footgun +0/+0, and all four gates pass. Hold if adoption blurs
into converting `~error_pp` sites by dropping printers. Kill the day the
expansion needs explaining beyond the one-liner contract.

---

## Execution log

### V-DX-E8-001 — Predictions sealed

This section committed before docs, PPX, tests, or example edits.

### V-DX-E8-002 — Docs-first contract

`README.md` documents `[%eta.result]` next to `[%eta.sync]` with the exact
expansion, channel semantics, and the keep-hand-written rule for `~error_pp` /
dynamic names / already-computed results. `docs/api-dx.md` leaf-boundary
guidance and `docs/type-errors.md` form-named rejection text were written before
the PPX implementation commit. Contract prose stayed within the ≤8-line budget
at the primary README call site.

### V-DX-E8-003 — Implementation

`expand_sync_like` now takes `~form` so rejection messages name the actual
extension. `eta.result` registers with `~kind:"sync_result"`. Generated
identifiers remain `__POS__`, `__FUNCTION__`, the use-site string, and the body.

### V-DX-E8-004 — Snapshots and parity

- Positive expansion: `test/ppx_expansion/cases/i_result.ml` → exact contract.
- Negatives: `ppx_result_nonstring.ml`, `ppx_result_wrong_arity.ml` with
  `expected [%eta.result "name" body]`.
- Behavioral parity: `test_ppx_result_parity` — sugar ≡ hand-written for Ok,
  `Error (`Db 7)`, and `Cause.Die`; leaf span name `db.find`; source `loc` on
  outer `fn` spans (same as existing `fn`/`here_attr` placement).

### V-DX-E8-005 — Adoption (scored vs prediction)

| | Predicted | Actual |
| --- | ---: | ---: |
| Example sites converted | 10 | **12** |
| Example `sync_result` remaining | 16 | **14** |

Rule applied: convert IO/trust leaves with static names and no special kwargs.

**Converted (12):** `batch_concurrency`, `connection_pool`, `retry_schedule`,
`resource_retry` (load only), `stream_decode`, `service_composition` (lookup),
`semaphore_permits`, `admission_control`, `observability` (load_user),
`typed_error_boundary`, `workflow_test`, `cli_business`.

**Not converted (reasons):**

| Site | Why |
| --- | --- |
| `blueprint_names` named+sync_result (2) | needs `~error_pp` |
| `cached_resource` / `manual_resource_refresh` | needs `~error_pp` |
| `race_mirror` | dynamic span name |
| `source_locations` | `~error_pp`, `~kind`, custom attrs |
| `resource_retry` acquire/release | lifecycle plumbing |
| `scoped_resource` open/close + load | lifecycle / outer named+error_pp |
| `service_composition` open_ | acquire plumbing |
| `background_lifecycle` load_user | outer named+error_pp owns naming |
| `quickstart` | pedagogical primitive demo |

Operator count on converted bare leaves: 1 primitive → 1 sugar form that adds
`fn`+`named` (net 2→1 concepts for the named leaf pattern when starting from
the full hand-written form).

### V-DX-E8-006 — Census / footguns

| Measure | Sealed | Actual |
| --- | ---: | ---: |
| Leaf sugar forms | 1 → 2 | 1 → 2 |
| Rejection paths | +0 (shared, form-named) | +0 |
| Core vals | +0 | +0 |
| Footguns | +0 / +0 | +0 / +0 |

Nested-span candidate footgun documented in red-team as noisy-but-harmless.

### V-DX-E8-007 — Red-team

3 / 3 passed. See `.scratch/research/dx/e8/redteam/VERDICT.md`.

### V-DX-E8-008 — Gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo` | PASS |

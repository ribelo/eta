# DX-E5 Journal — Negative compile tests and "Eta type errors, translated"

Branch: `research/dx-e4e5-cause-corpus-type-errors`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e4e5`
Phase: B (hygiene, batch 2) · effort S · risk low

## Predictions (sealed)

Sealed before constructing any repro or capturing any compiler output.
Wrong predictions stay as data; surprises are findings, recorded raw.

### Compile-time vs runtime verdicts (per one-pager category)

| # | Category | Predicted verdict | Predicted message shape |
|---|---|---|---|
| 1 | `Supervisor` child-handle escape (return a `child` from the `scoped` body) | **COMPILE-TIME** | type error on the rank-2 `'s` phantom; predict the words "would escape its scope" appear |
| 2 | `Supervisor` child escape via `ref` leak | **COMPILE-TIME** | same class as #1 |
| 3 | Resource-handle escape (use an acquired handle after `with_resource` / `with_scope` closes) | **NOT compile-time** — `Resource.t` and `with_resource` carry no phantom; lifetime is runtime-managed. Predict either a runtime failure with a "closed"-flavored message or silent success; record raw |
| 4 | Same-domain `Channel` misused across `eta_par` domains | **RUNTIME-ONLY** — OCaml types do not track domains, and `channel.ml` has no domain fence (verified by grep). Predict a low-level exception, a hang, or silent misbehavior; record raw. `Queue` (documented cross-domain) works and serves as the contrast case |
| 5 | Same-domain `Pubsub` / `Pool` across domains | **RUNTIME-ONLY**, same reasoning as #4 |
| 6 | PPX rejection paths (`Location.raise_errorf` in `ppx_eta.ml`) | **COMPILE-TIME** | exact texts from the source, e.g. `expected [%eta.sync "name" body]` |

### Expected corpus messages (5–8)

1. Supervisor child escape — compile-time skolem/rigid-variable escape error.
2. `[%eta.sync]` malformed payload — `expected [%eta.sync "name" body]`.
3. `[%%eta.sql.table]` on a non-record type —
   `eta.sql.table expects a record type declaration`.
4. `[%%eta.sql.table]` with an unsupported field type —
   `eta.sql.table supports int, int64, string, bool, float, bytes, and option fields`.
5. `[%%eta.sql.table]` with a bad column attribute —
   `attribute primary_key does not take a payload` (or the unsupported-attribute variant).
6. Cross-domain `Channel` misuse — runtime output, captured raw (whatever it is).
7. Resource-handle-after-close — runtime output, or a documented "no error
   exists" finding if the handle simply keeps working.

Seven entries predicted; 6 and 7 may merge or split per archaeology.
The `table type name is empty` rejection in `ppx_eta.ml` is predicted
**unreachable from source** (syntax forbids empty type names); if confirmed
it is recorded as dead-code follow-up, not corpus material.

### Snapshot harness prediction

Repo has no cram convention. Predict the lightest thing that works is a
`test/type_errors/` directory with per-case `.ml` repros, committed
`.expected` outputs, and a dune-driven compile-and-diff harness such that
`dune runtest --force` fails on message drift. Compiler invocation via the
workspace toolchain (ocamlfind + built cmi paths or the install alias);
exact mechanism chosen during archaeology — mechanics are not predictions.

### Review outcome prediction

Reviewer without the page: flounders on the rank-2 escape, likely reaches
for `Obj.magic` or proposes weakening the API. With the page: explains the
rank-2 rationale in their own words ("`'s` is a fresh brand per `scoped`
block; letting it escape would allow awaiting a child of a dead
supervisor"). Predict PASS-with-page.

### Census / footgun deltas

- Census: **+0 API vals** — docs page plus test harness only.
- Footgun: predict **−3** (rank-2 escape demystified; same-domain
  cross-domain misuse demystified; PPX rejection wall demystified),
  **+0** new traps.

### Gates

Predict green: `nix develop -c dune build @install`,
`nix develop -c dune runtest --force`, `nix develop -c eta-oxcaml-test-shipped`.
No jsoo check needed (no lib code touched).

### Promote/hold/kill prior (pre-evidence)

Predict **promote unconditionally** once the corpus lands, per the one-pager.
The by-product is the list of messages needing compiler-side work.

---

## Execution log

### Step 1 — seal predictions

Committed this section before constructing any repro
(`docs(dx-e5): seal predictions`).

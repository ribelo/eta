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

### Step 2 — archaeology

Lab: `.scratch/research/dx/e5/archaeology/` (`capture.sh` compiles probes
against the main workspace build — the switch-installed `eta` is stale,
verified: it lacks e23's `bind_error`). All outputs below are ACTUAL
compiler/runtime output, not typed from memory.

**Verdicts vs sealed:**

| # | Category | Sealed | Actual | Score |
|---|---|---|---|---|
| 1 | Supervisor escape (return child) | compile, "would escape its scope" | compile, **`This field value has type … which is less general than 's. …`** | verdict hit, **message-shape miss** |
| 2 | Supervisor escape (ref leak) | compile, same class | compile, same class — and the message does not contain the word `child` or name `stolen` at all | hit |
| 3 | Resource-handle escape | not compile-time | **compiles** (exit 0), both `with_resource` and `Pool.with_resource` | hit |
| 4 | Channel across eta_par domains | runtime-only | runtime-only, and worse than predicted: non-blocking `try_send` **silently works**; the first blocking pair **hangs forever with no message** (timeout exit 124). `Queue` contrast completes cleanly | hit, stronger than sealed |
| 5 | Pubsub/Pool across domains | runtime-only | same-family as Channel (same Sync_lock waiter design); not separately probed — recorded as extrapolation, not evidence | partial (scoped) |
| 6 | PPX rejections | compile-time | compile-time; 7 rejection texts captured with exact locations | hit |

**Surprises recorded raw:**

- **S1 (message shape).** No variant of the supervisor escape produces the
  words "would escape its scope" — not the plain return, not the ref leak,
  not the explicit `(type s)` style, not closure/tuple smuggling (red-team
  r1/r2). OCaml reports the rank-2 record-field generalization failure as
  `less general than 's.` uniformly. The page's entry 1 quotes the real
  text and tells the reader the escape route is never named.
- **S2 (probe artifact).** My first resource probe failed to compile — but
  on the *value restriction* (`contains the non-generalizable type
  variable(s): '_weak1`), not on any scope fence. Eta-expanding the probe
  removed the artifact. Finding: it genuinely compiles; but repros must be
  built carefully or the measurement captures a different error class.
- **S3 (unreachable rejections).** `eta.sql.table requires at least one
  field` is unreachable from hand-written source — `type t = { }` is a
  syntax error before the ppx runs (captured: `Error: Syntax error`).
  `table type name is empty` is likewise unreachable from source. Both are
  defensive dead code from the user's perspective → journal follow-up.
- **S4 (first-contact error).** `Supervisor.Scope.start` takes a `Scope.t`,
  not an `Effect.t`; writing `start sup (Effect.pure 42)` gives
  `This expression has type (int, 'a) Eta.Effect.t but an expression was
  expected of type ('b, 'c, 'd) Eta.Supervisor.Scope.t`. Not in the
  one-pager's categories; captured as a follow-up page-entry candidate.

### Step 3 — snapshot harness

`test/type_errors/` — script + committed expected outputs (the lightest
thing that works). Findings that shaped it:

- **dune cram rejected**: verified experimentally that cram scripts do not
  expand `%{...}` variables (dune 3.22), so a cram test cannot address the
  built cmi/ppx driver without fragile relative paths. Rule actions DO
  expand them, and `DUNE_SOURCEROOT`/`INSIDE_DUNE` env vars give absolute
  roots — the script+rule design uses those.
- `snapshot_compile.sh` compiles each `cases/*.ml` (supervisor cases
  against the workspace cmi, ppx cases through the workspace driver) and
  concatenates output; `(diff expected_compile.txt actual_compile.txt)`
  under `runtest` fails on drift; `dune promote` re-records. Negative
  fixture: broke a case, gate fired, restored.
- Compiler fence: `(enabled_if (= %{ocaml_version} "5.2.0+ox"))` — snapshot
  text is pinned to the gate compiler; other compilers word errors
  differently. Re-record on compiler upgrade.
- Runtime outcomes live in a separate **opt-in** alias
  `@type-errors-runtime` (try-send / queue-contrast / blocking-pair):
  gating a hang in `dune runtest` would cost a 12 s timeout on every run
  and invites load-dependent flakes. The hang is documented in the page and
  the runtime snapshot instead.

### Step 4 — `docs/type-errors.md`

8 entries (sealed predicted 5–8, expected 7 — the resource no-error entry
splits the count to 8): (1) supervisor `less general than 's.`, (2)
`[%eta.sync]` shape, (3) sql.table non-record, (4) sql.table field types,
(5) sql.table attribute discipline, (6) sql.table 8-field limit, (7)
cross-domain hang (runtime, quotes the real probe output), (8) resource
handle escape (no error exists). Every quoted message verified
character-identical to `expected_compile.txt` by a mechanical check
(journal step: `ALL VERBATIM`).

### Step 5 — gates

```
nix develop -c dune build @install          # OK
nix develop -c dune runtest --force         # OK (includes the snapshot gate)
nix develop -c eta-oxcaml-test-shipped      # OK
nix develop -c dune build @type-errors-runtime   # OK (opt-in)
```

### Step 6 — red-team

`.scratch/research/dx/e5/archaeology/r1_closure_leak.ml` and
`r2_tuple_leak.ml`: defer-via-closure and bundle-via-tuple escapes. Both
produce the identical `less general than 's.` class (S1 holds across every
route tried). The ref-leak remains the most opaque: its message contains
neither `child` nor the ref's name — that nuance is now in page entry 1.

### Step 7 — review packet

Files under `.scratch/research/dx/e5/review/` as required.

### Step 8 — report

See `report.md`.

### Census / footgun actuals

- Census: **+0 API vals** (docs page + test harness only) — as sealed.
- Footgun: **−4 / +0** vs sealed −3 / +0 — favorable miss: the
  no-error resource escape (entry 8) is a fourth defused trap the sealed
  list didn't count.

### Follow-up notes (out of scope)

- **Dead ppx rejections** (S3): `eta.sql.table requires at least one field`
  and `table type name is empty` are unreachable from source. Engineering
  rules favor deletion; left in place because E5's fence is docs/tests
  only. Candidate for a future hygiene batch.
- **`start` argument confusion** (S4): a page entry for
  `Scope.t vs Effect.t` at `Supervisor.Scope.start` would serve
  first-contact users; deferred — not in the one-pager's four categories.
- Pubsub/Pool cross-domain probes (category 5) extrapolated from Channel,
  not measured; the extrapolation is marked as such in the page and report.

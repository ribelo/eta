# Plan: replace Lwt with a jsoo-native Eta backend

## Decision (approved)

Eta's JavaScript story is delivered by a **jsoo-native runtime backend that
implements `Runtime_contract.RUNTIME` directly against `Js_of_ocaml`
primitives**. **Lwt is dropped entirely** — both the native `eta_lwt` backend
and the `eta_lwt_jsoo` host. Eio remains the only native backend.

Two options were weighed and one rejected:

- **Rejected — "compile Eio with `--effects=cps`":** category error. `--effects=cps`
  is a jsoo codegen mode, not a runtime. `eta_eio` pulls `eio` + `eta_blocking`
  + `cstruct`; `eio_main` is the platform layer (io_uring/epoll/luv, fds,
  domains) and has no browser/Node backend. "Compile Eio to JS" silently
  expands into "write a jsoo Eio scheduler" — strictly more work than the
  backend below, against a larger, Unix-shaped surface.
- **Chosen — jsoo-native `RUNTIME` backend, no Lwt:** the contract seam already
  hosts a jsoo backend today (`eta_lwt_jsoo` works). Lwt in it is incidental
  (~7 touchpoints). Replace them with raw JS primitives; keep the concurrency
  model byte-for-byte.

`--effects=cps` stays regardless: the Eta interpreter (`lib/eta/effect_core.ml`)
is direct-style, so `await` must suspend an OCaml fiber, which needs effects in
JS. This is the floor for *any* jsoo Eta backend and is **not** part of the
Lwt-vs-Eio decision.

## Current repository state (audited, not exhaustively)

`HEAD` carries a committed hand-rolled `lib/js` JS runtime ("feat(js)" Phases
0-10): a ~6k-LOC Melange-style fork with its own scheduler, promise, fiber, and
effect modules, no OCaml 5 effects, no Lwt.

The **working tree is a large uncommitted in-progress migration** (≈1.9k
insertions / 37k deletions across 293 files) that:

- deletes the hand-rolled `lib/js/*` runtime and turns `eta_js` into a thin
  facade over `lib/eta`;
- adds untracked backends `lib/lwt/` (native `eta_lwt`) and `lib/lwt_jsoo/`
  (`eta_lwt_jsoo`), plus `eta_lwt.opam` / `eta_lwt_jsoo.opam`;
- splits HTTP into backend-neutral `lib/http` (core) + new `lib/http_eio/`
  (Eio transport: h1/h2/tls/ws/connect moved out of core) + new `lib/http_lwt/`,
  plus `eta_http_eio.opam` / `eta_http_lwt.opam`;
- restructures tests into `*_common` / `*_eio` / `*_lwt` trees with
  `BACKEND-SPLIT.md` notes, `run_eio.ml` / `run_lwt.ml` runners, and
  `*_common_suites.ml` shared suites; deletes the old monolithic test files;
- modifies `lib/eta` (`runtime_contract.mli` +~20 lines to `RUNTIME`,
  `runtime_core.ml`, `runtime.ml`/`.mli`, `pool.ml`, `semaphore.ml`),
  `lib/eio/eta_eio`, `lib/utop` (still depends on `eta_lwt`), `dune`,
  `dune-project`, `flake.nix`, and various opam files;
- adds `docs/plans/2026-06-09-eta-js-lwt-jsoo-migration.md` (the **superseded**
  Lwt-based handoff plan) and deletes older eta_js docs.

> Honesty note: I have read the key directories, the contract diff header, the
> Lwt touchpoints, and the migration plan, but **not all 293 changed files**.
> Bucket assignments below are by pattern and best inference; verify each during
> execution. Items I could not confirm are marked **[verify]** or **[explore]**.

## Bucket 1 — KEEP (let the working-tree change stand)

These align with the decision (shared core via jsoo, Eio native, HTTP split):

- **`lib/js/*` deletions** — the hand-rolled JS runtime stays deleted. Shared
  core is the path. `eta_js` stays a facade (it will be repointed in Bucket 3).
- **HTTP core split:** `lib/http` core changes + new **`lib/http_eio/`** +
  `eta_http_eio.opam`. Backend-neutral core also helps a future jsoo HTTP, so
  keep it. (jsoo HTTP transport itself is out of scope here.)
- **Eio + common test trees:** all `test/*_common/`, `test/*_eio/`,
  `BACKEND-SPLIT.md`, `*_common_suites.ml`, `run_eio.ml`, and the deletions of
  the old monolithic test files. **[verify]** each `*_common` suite does not
  import an Lwt runner.
- **`lib/eio/eta_eio` changes** — Eio backend alignment to the (modified)
  contract. **[verify]**
- **`lib/eta` contract/runtime changes** — KEEP **only if** each change benefits
  Eio too. The migration's own constraint was "no contract change that helps
  Lwt but complicates Eio." **[verify]** the `RUNTIME` additions and
  `runtime_core`/`pool`/`semaphore` edits are not Lwt-only concessions; a
  jsoo-native backend must satisfy the same contract, so anything genuinely
  needed by jsoo stays.
- **`lib/otel`, `lib/schema_test`, `lib/sql`, `lib/stream`, `lib/test`
  changes** — appear to be test-split / API alignment, orthogonal to Lwt.
  **[verify]**
- **`bench/*`, `flake.nix` (non-Lwt parts), `dune`** — orthogonal. **[verify]**
  flake/dune-project still need the Lwt entries removed (Bucket 2).
- **Deleted docs** (`docs/eta_js/*`, old `docs/plans/...readiness.md`,
  root `js-runtime-*.md`) — stay deleted.

## Bucket 2 — REVERT / DROP (Lwt must leave the repo)

Mechanism: untracked additions → `rm -rf`; tracked modifications → `git restore`
or edit to remove Lwt portions.

### Native Lwt backend and HTTP transport (untracked → remove)
- `lib/lwt/` (`eta_lwt`) and `eta_lwt.opam`.
- `lib/http_lwt/` (`eta_http_lwt`) and `eta_http_lwt.opam`.

### jsoo Lwt host (untracked → remove **after** it seeds Bucket 3)
- `lib/lwt_jsoo/` (`eta_lwt_jsoo`) and `eta_lwt_jsoo.opam`. This is the template
  for `eta_jsoo`; copy first, then delete.

### Native `*_lwt` test trees and Lwt runners (untracked → remove)
- `test/lwt/`, `test/ai_lwt/`, `test/backend_lwt/`, `test/blocking_lwt/`,
  `test/connectors_lwt/`, `test/core_lwt/`, `test/http_lwt/`, `test/otel_lwt/`,
  `test/par_lwt/`, `test/ppx_lwt/`, `test/redacted_lwt/`, `test/runtime_lwt/`,
  `test/schema_lwt/`, `test/schema_test_lwt/`, `test/sql_lwt/`,
  `test/stream_lwt/`, `test/test_lwt/`.
- Lwt runners inside split suites: `test/ai/*/run_lwt.ml`,
  `test/sql_driver/run_lwt.ml`, and any other `run_lwt.ml`. Keep the matching
  `run_eio.ml` and `*_common_suites.ml`.

### dune-project / flake / dune (edit, remove Lwt only)
- Delete `(package (name eta_lwt) ...)`, `(package (name eta_lwt_jsoo) ...)`,
  `(package (name eta_http_lwt) ...)` from `dune-project`. Remove `lwt`,
  `js_of_ocaml-lwt` from the `eta_js` / `eta_js_test` package deps.
- `flake.nix`: remove `ocamlPackages.lwt`, `js_of_ocaml-lwt` (keep
  `js_of_ocaml`, `js_of_ocaml-ppx`). **[verify]** nothing else needs them.

### `eta_utop` (modified → repoint or delete)
- `lib/utop/dune` still lists `eta_lwt`. **Repoint to `eta_eio`** (recommended)
  or delete the package. Do not leave a dangling `eta_lwt` dep.

### Superseded plan doc
- `docs/plans/2026-06-09-eta-js-lwt-jsoo-migration.md` assumes native Lwt +
  Lwt jsoo host. Mark obsolete or replace with a jsoo-native version derived
  from this file.

## Bucket 3 — WRITE (the new jsoo-native backend)

### New package `eta_jsoo` (`lib/jsoo/`)
Seed from `lib/lwt_jsoo/eta_lwt_jsoo.ml`. Keep the cancel-context tree, scopes,
fibers, `protect`, streams, the `Await` effect, and the `Effect.Deep` handler
**unchanged**. Replace only the Lwt touchpoints:

| Lwt today | jsoo-native replacement |
|---|---|
| `Lwt.task ()` / `wakeup_later` / `wakeup_later_exn` | one-shot cell: `{ mutable state : Pending of (('a,exn) result -> unit) list \| Settled of ('a,exn) result }` |
| `Lwt.on_any p ok err` | subscribe a callback to the cell |
| `Lwt.async` + `Lwt.pause` | `queueMicrotask` (or `Promise.resolve().then`) |
| `Lwt.join children` (`await_children`) | completion-counter cell that settles when N children finish |
| `Lwt_js.sleep s` | `setTimeout` (bound via `Js_of_ocaml.Js.Unsafe`) |
| `Lwt_main.run` / `run_lwt` returning `_ Lwt.t` | no global loop; `run` returns via callback / a settled cell. Node entry resolves a `Promise` or calls `process.exit`. |

Other facts to preserve: `Worker_context` stays the trivial stub
(`run f = f ()`, `active () = false`); `now_ms` uses `Date.now`; the build keeps
`--effects=cps`.

`eta_jsoo` deps: `eta`, `js_of_ocaml` (no `lwt`, no `js_of_ocaml-lwt`).
Add `eta_jsoo.opam` and the `dune-project` package stanza.

### Repoint the facade and tests
- `lib/js/eta_js.ml` / `.mli`: `module Runtime = Eta_jsoo.Runtime`,
  `module Lwt_host = Eta_jsoo` (rename), drop `lwt` deps in `lib/js/dune` and
  the `eta_js` package.
- `lib/js_test`, `lib/js_stream`: drop `lwt` / `js_of_ocaml-lwt` deps; repoint
  any `Eta_lwt_jsoo` references to `Eta_jsoo`.
- `test/js_jsoo/`: rename `test_eta_lwt_jsoo.ml` → `test_eta_jsoo.ml`, swap
  `Eta_lwt_jsoo.*` → `Eta_jsoo.*`, drop `lwt` from `dune`. Keep
  `--effects=cps`. Keep `test_eta_js_jsoo.ml` (facade test), repointed.
- `test/js_stream/`: drop `lwt` deps, keep node run.

### Measurement (the only real open risk)
Measure the `--effects=cps` bundle size and throughput of `eta_jsoo` node tests
and compare against the deleted hand-rolled CPS runtime baseline (recover from
`HEAD:lib/js` if a number is needed). This cost is independent of the backend
choice but determines whether jsoo Eta is viable at all. **[explore]**

## Execution order

1. **Snapshot** the Lwt-jsoo host source (it seeds `eta_jsoo`).
2. Decide `eta_utop` fate (repoint to `eta_eio` / delete).
3. Create `lib/jsoo/` `eta_jsoo` from the host, replacing the 7 touchpoints;
   write `eta_jsoo.mli`, `dune`, `eta_jsoo.opam`, and the `dune-project` stanza.
4. Repoint `eta_js`, `eta_js_test`, `eta_js_stream`, `test/js_jsoo`,
   `test/js_stream` to `Eta_jsoo`; drop their `lwt` deps.
5. Remove `lib/lwt/`, `lib/lwt_jsoo/`, `lib/http_lwt/` and their opam files.
6. Remove all native `*_lwt` test trees and `run_lwt.ml` runners.
7. Remove `eta_lwt`, `eta_lwt_jsoo`, `eta_http_lwt` from `dune-project`; remove
   `lwt` / `js_of_ocaml-lwt` from remaining package deps and `flake.nix`.
8. Update/replace the superseded migration plan doc.
9. Regenerate opam files; grep for stragglers; build and test.

## Verification

- `grep -rnE "\blwt\b|Lwt\.|Lwt_js|Lwt_main|eta_lwt|Eta_lwt|js_of_ocaml-lwt" lib test dune-project flake.nix`
  returns nothing (the new backend is `eta_jsoo` / `Eta_jsoo`).
- `nix develop -c dune build` clean; `nix develop -c dune runtest --force` green
  (Eio + common suites).
- jsoo node tests run under `--effects=cps`: `test/js_jsoo`, `test/js_stream`
  execute with `node`.
- `dune build @install` shows `eta_jsoo` and no `eta_lwt*` / `eta_http_lwt`.
- A recorded bundle-size / throughput number for `eta_jsoo` vs the old runtime.

## Open questions — honest must / should / explore

**Must (blockers if wrong):**
- `eta_jsoo` must satisfy the full `RUNTIME` contract; confirm the modified
  contract (`runtime_contract.mli` +~20 lines) is implementable on a
  single-threaded cooperative substrate without faking native facilities.
- `--effects=cps` must actually run the suspend/resume path correctly under
  Node for the new promise cell (no Lwt scheduler underneath). Prove with the
  ported `test/js_jsoo` suite before deleting `eta_lwt_jsoo`.

**Should:**
- Repoint `eta_utop` to Eio rather than delete, to keep the dev REPL helper.
- Keep `BACKEND-SPLIT.md` notes as the rationale record for the test layout.
- Confirm the `lib/eta` contract edits are Eio-neutral (no Lwt-only concession
  left behind now that Lwt is gone).

**Explore (need investigation before committing effort):**
- Bundle size / throughput cost of `--effects=cps` vs the deleted CPS runtime.
  If unacceptable, the question becomes "is jsoo Eta viable at all," not
  "Lwt vs Eio."
- Whether `Lwt.join`-style `await_children` maps cleanly to a counter cell under
  cancellation (the trickiest semantic port; cover with the nested-cancel test).
- The exact set of `lib/eta` / `lib/eio` diffs that are load-bearing vs
  migration noise — needs a file-by-file read of the modified core before any
  `git restore` there.

## Risks

- **Coverage:** deleting `*_lwt` suites drops Lwt-substrate coverage of
  backend-neutral packages. Acceptable: covered by `*_common` + `*_eio`, and
  Lwt is no longer a target. jsoo keeps its own `test/js*` coverage.
- **Uncommitted base:** all of this sits on an uncommitted working tree. Commit
  the KEEP set first (or stash deliberately) so Bucket 2 removals and Bucket 3
  writes are reviewable and reversible.
- **Boundary intact:** nothing here should change the *intent* of
  `Runtime_contract`. We are removing one backend family (Lwt) and adding
  another (jsoo-native) against the same seam, not reshaping the seam.

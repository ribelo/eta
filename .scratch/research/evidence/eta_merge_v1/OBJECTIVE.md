# Port-Branch Merge — Master Objective

Status: Ready. Backlog task Eta-merge-ports (will be filed under epic
Eta-x48 sibling). Single agent. ~1 hour of work at AI speed.

This is the single source of truth for landing the parallel-track port
branches into `rename-effet-to-eta` with linear history. Read end-to-end
before starting.

---

## 0. Goal

Merge four port branches (Redacted, LogLevel, MutableRef, Semaphore) into
the current `rename-effet-to-eta` branch using cherry-pick. Preserve
linear git history. No merge commits. After each branch lands cleanly,
delete the worktree and close the corresponding backlog task.

The Latch worktree (`../Eta-latch`) is research in progress and **out of
scope** for this objective. The OxCaml-baseline worktree (`../Eta-otel-baseline`)
is reference-only and out of scope. The Heartbeat worktree
(`../Eta-heartbeat`) is out of scope per user direction.

---

## 1. Constraints

### 1.1 Linear history

- Use `git cherry-pick` exclusively. Never `git merge`. Never `git pull`.
- Each port lands as the original commit(s) replayed onto the current tip.
- For multi-commit branches, cherry-pick each commit in order. Do not squash.
  (Authorship + bisectability preserved.)

### 1.2 Verify per branch

After each cherry-pick lands:

1. `nix develop -c dune build` — the whole project builds.
2. `nix develop -c dune runtest packages/eta --force` — eta core tests pass.
3. `nix develop -c dune runtest packages/eta-http --force` — eta-http tests still pass.
4. `nix develop -c eta-oxcaml-test-shipped` — the project gate still passes.
5. (Semaphore only) `bash packages/eta-http/audit/run.sh` — refresh the audit
   counts; verify the dep-usage and eta-escapes catalogs still classify
   correctly.

If any verification step fails, **abort the cherry-pick** (`git cherry-pick
--abort` or `git reset --hard HEAD~N`) and stop. Report the failure to
the planner; do not push through.

### 1.3 Audit-from-day-one applies to merges too

If the Semaphore extraction introduces a new dep call site or escape pattern
into eta-http (e.g. eta-http now reaches `Eta.Semaphore.acquire` directly),
the audit catalogs must reflect it. Run `audit/run.sh` and update sites if
the count changes. The catalogs are not gates; they are the truth-of-record.

---

## 2. Inventory

Current branch tip: `89b3d84 docs: eta-http v1 OBJECTIVE status + ADRs 0004-0006 + journal entries`.

### 2.1 Mergeable branches (committed work, ready)

| Worktree | Branch | Commits | Files touched | Conflict risk |
| --- | --- | --- | --- | --- |
| `../Eta-redacted` | `research-port-redacted` | `217c3b2` (1 commit, 108 LOC) | `README.md`, `packages/eta/redacted.{ml,mli}`, `packages/eta/test/test_eta.ml` | LOW — README and test_eta.ml grew on rename-effet-to-eta during eta-http v1; expect 2 conflicts at append points. |
| `../Eta-loglevel` | `research-port-loglevel` | `9dc27b2` (1 commit, 302+/14- LOC) | `dune-project`, all `*.opam`, `journal.md`, `packages/eta/log_level.{ml,mli}`, `packages/eta/test/test_eta.ml` | MEDIUM — `dune-project` and `*.opam` files were regenerated during eta-http v1; `journal.md` has many V-Http-S\* entries appended; `test_eta.ml` grew. Expect ~5 conflicts at append/regeneration points. |
| `../Eta-mutable-ref` | `research-port-mutable-ref` | **uncommitted** — `packages/eta/mutable_ref.{ml,mli}` untracked, `packages/eta/test/test_eta.ml` modified, `PLAN.md` and `journal/` untracked | LOW once committed | LOW — pure addition; no shared files except `test_eta.ml`. |
| `../Eta-semaphore` | `research-port-semaphore` | `0dc8b69` (extract Pool wait-slot) + `770a16d` (V-Semaphore-Extract journal) | `packages/eta/pool.ml`, `packages/eta/semaphore.{ml,mli}`, `packages/eta/test/test_eta.ml`, `journal.md` | **HIGH** — refactors `pool.ml` (175 lines deleted, replaced by Semaphore consumption). Pool may have evolved on `rename-effet-to-eta` since the branch point. eta-http consumes Pool — any Pool API drift must be reconciled. |

### 2.2 Out of scope

- `../Eta-latch` (branch `research-h-latch`) — research lab in progress
  (`.scratch/research/evidence/eta_research/latch_survival/` untracked, journal modified, no
  shipped Latch port commit). Leave the worktree alone.
- `../Eta-otel-baseline` — reference snapshot for the eta-otel rebuild
  epic (Eta-5zo). Read-only context.
- `../Eta-heartbeat` — autoresearch/scheduler experimentation, separate
  arc, user-direction out of scope.
- `../Effet`, `../Effet-OxCaml` — predecessors. Untouched.

---

## 3. Order of operations

**1. Eta-redacted** → cleanest. Pure addition. README + test_eta.ml conflict
   resolution sets the pattern for the next branches.

**2. Eta-loglevel** → next. Touches dune-project + opam files + journal.md
   + test_eta.ml. Larger but still pure addition (new module, no refactor).

**3. Eta-mutable-ref** → commit the uncommitted work first (see §4.3),
   then cherry-pick. Pure addition.

**4. Eta-semaphore** → land last. Pool refactor is the highest-risk merge.
   By landing last, Pool's state is at its most stable; any conflicts
   resolve against the latest version of Pool. **This is the only
   refactor in the set.**

After step 4, run the full ship-gate: `dune build` + `dune runtest --force`
+ `eta-oxcaml-test-shipped` + `bash packages/eta-http/audit/run.sh`. Confirm
all green before declaring done.

---

## 4. Per-branch flow

### 4.1 Eta-redacted

```sh
cd /home/ribelo/projects/ribelo/ocaml/Eta
git cherry-pick 217c3b2
```

**Expected conflicts**:

- `README.md` — eta-http v1 added a Features table entry; Redacted commit
  also adds one. Resolve: union the entries. Order alphabetically or by
  the existing convention (whichever fits the surrounding rows).
- `packages/eta/test/test_eta.ml` — eta-http v1 added Channel/Pool/Timeout
  test groups; Redacted adds its own. Resolve: append the Redacted test
  group at the end (or in module-name alphabetical order if that's the
  convention).

**After resolution**:

```sh
git add README.md packages/eta/test/test_eta.ml
git cherry-pick --continue
```

**Verify** per §1.2 steps 1–4. Then:

```sh
git worktree remove ../Eta-redacted
```

**Backlog**: planner closes `Eta-jo5` with `217c3b2 cherry-picked → <new SHA>`
recorded.

### 4.2 Eta-loglevel

```sh
git cherry-pick 9dc27b2
```

**Expected conflicts**:

- `dune-project` — eta-http v1 added the eta-http package stanza;
  Log_level commit may have added log_level wiring or version bumps.
  Resolve: keep both stanzas.
- All `*.opam` files (`eta.opam`, `eta-http.opam`, `eta-otel.opam`, etc.) —
  these are regenerated by `dune build` from `dune-project`. Strategy:
  resolve `dune-project` first, then `git checkout --ours *.opam` and
  regenerate via `dune build` (or `dune subst`).
- `journal.md` — Log_level commit adds 46 lines; current journal has
  V-Http-S\* entries. Resolve: append the V-Log_level entry at the
  current bottom of the file (after the eta-http v1 entries),
  preserving chronological order.
- `packages/eta/test/test_eta.ml` — same pattern as Redacted; append the
  Log_level test group.

**After resolution**:

```sh
git add dune-project *.opam journal.md packages/eta/test/test_eta.ml
nix develop -c dune build  # regenerate any opam drift
git add *.opam              # if regeneration changed anything
git cherry-pick --continue
```

**Verify** per §1.2. Then `git worktree remove ../Eta-loglevel`. Planner
closes `Eta-mw8`.

### 4.3 Eta-mutable-ref (commit-first path)

The mutable_ref work is uncommitted. **Commit first, then cherry-pick.**

```sh
cd ../Eta-mutable-ref
git status --short                # confirm what's uncommitted
git add packages/eta/mutable_ref.ml packages/eta/mutable_ref.mli
git add packages/eta/test/test_eta.ml
# Decide whether to include PLAN.md and journal/ — they were never
# committed before; if they're useful documentation, add them too.
# If they're scratch worktree-only files, leave them out.
git diff --cached --stat          # sanity check before commit
git commit -m "feat: ship Eta.Mutable_ref port

Implement packages/eta/mutable_ref.{ml,mli} as a named primitive
over Atomic.t. Public API: make, get, set, update, compare_and_set.

Provides vocabulary (this is a shared mutable ref, not a counter)
for upcoming research items (Latch internals, FiberRef, RcRef) and
keeps eta-otel state-cell intent explicit."
```

Then back to the Eta worktree:

```sh
cd /home/ribelo/projects/ribelo/ocaml/Eta
git cherry-pick <SHA from above>
```

**Expected conflicts**:

- `packages/eta/test/test_eta.ml` — same append-group pattern.

**Verify** per §1.2. Then `git worktree remove ../Eta-mutable-ref`. Planner
closes `Eta-lho`.

### 4.4 Eta-semaphore (highest risk)

```sh
git cherry-pick 0dc8b69 770a16d
```

**Expected conflicts**:

- `packages/eta/pool.ml` — **the hard one**. The Semaphore commit deletes
  175 lines of Pool's wait-slot internals and replaces them with calls
  into the new `Eta.Semaphore` module. Pool's external API is unchanged
  per the commit message. If `pool.ml` has changed on
  `rename-effet-to-eta` since the branch point, the cherry-pick will
  fail with overlapping changes.

  **Resolution strategy**:
  1. Read the current `packages/eta/pool.ml` and the original Semaphore
     commit's diff side-by-side.
  2. Identify the wait-slot region in current Pool (look for
     Eio.Mutex/Eio.Condition usage around acquire).
  3. Replace that region with `Eta.Semaphore.acquire` / `release` /
     `with_permits` calls per the original commit's intent.
  4. Preserve any post-branch Pool improvements (logging, metrics, observ-
     ability hooks, audit hooks added by S0–S6 of eta-http v1).
  5. If post-branch changes are incompatible with the Semaphore
     extraction (e.g. Pool now exposes a wait-slot internals API that
     other code depends on), **stop and report** — this is a structural
     conflict, not a textual one.

- `packages/eta/test/test_eta.ml` — append the Semaphore test group.
  Existing Pool tests must continue to pass unchanged (Pool external API
  unchanged per the commit message; verify this).

- `journal.md` — append V-Semaphore-Extract entry at current bottom.

**After resolution**:

```sh
git add packages/eta/pool.ml packages/eta/semaphore.ml packages/eta/semaphore.mli packages/eta/test/test_eta.ml journal.md
git cherry-pick --continue
# If two commits, repeat for the second
```

**Verify** per §1.2 steps 1–5 (including the audit re-run at step 5,
since Pool internals changed and eta-http consumes Pool).

**Audit impact**:

- `eta-escapes.md` may gain or lose escape sites depending on whether
  Eio.Mutex/Eio.Condition usage moved from Pool's internals to
  Semaphore's internals. The escape doesn't disappear; it relocates.
  Run `audit/run.sh` and confirm the count changes are explained by
  the move (not by a new escape pattern).
- `dep_usage.md` may gain `Eta.Semaphore` call sites if eta-http
  consumes Semaphore directly. Promote-to-public: per the OBJECTIVE
  3-consumer rule, if eta-http + eta-otel + one more consume
  Semaphore directly, the primitive is doing its job.

Then `git worktree remove ../Eta-semaphore`. Planner closes `Eta-1gj`.

---

## 5. Stop conditions

Return to planner if any of these hold:

- A cherry-pick produces conflicts that suggest a structural redesign of
  the port (e.g. Semaphore's API doesn't fit current Pool's lifecycle).
- After a cherry-pick, `dune build` fails and the failure is not a
  trivial conflict-resolution mistake.
- After a cherry-pick, `dune runtest packages/eta-http --force` fails.
  This means the port broke eta-http v1; investigate before continuing.
- `eta-oxcaml-test-shipped` regresses.
- Pool API drift (Semaphore branch) requires changes beyond the commit's
  original scope. Do not silently expand scope; report and ask.
- The `audit/run.sh` count after Semaphore lands shows a new
  unclassified escape that doesn't match the documented Semaphore
  extraction. Investigate.

---

## 6. Linear-history discipline

- After all four cherry-picks land, `git log --oneline` should show:
  ```
  <new SHA> docs: add V-Semaphore-Extract journal entry
  <new SHA> feat: extract Eta.Semaphore from Pool wait-slot
  <new SHA> feat: ship Eta.Mutable_ref port
  <new SHA> feat: ship Eta.Log_level port
  <new SHA> feat: ship Eta.Redacted port
  89b3d84 docs: eta-http v1 OBJECTIVE status + ADRs 0004-0006 + journal entries
  b09a172 feat(eta-http): S6 OTel observability
  ...
  ```
- No merge commits. `git log --merges` between the new tip and `89b3d84`
  must return empty.
- `git log --first-parent --oneline` and `git log --oneline` must produce
  identical output for the new commits (no branching structure).

---

## 7. Backlog closures

After all four ports land:

| Task | Closes when |
| --- | --- |
| Eta-jo5 (Redacted) | Eta-redacted lands |
| Eta-mw8 (LogLevel) | Eta-loglevel lands |
| Eta-lho (MutableRef) | Eta-mutable-ref lands |
| Eta-1gj (Semaphore) | Eta-semaphore lands |
| Eta-merge-ports (this task) | All four above closed |

Closures are planner actions. Experimenter records the new SHAs in a
`.backlog/Eta-merge-ports.md` note as each lands.

---

## 8. Worktree cleanup

After each branch lands cleanly:

```sh
git worktree remove ../Eta-{slug}
git branch -d research-port-{slug}    # local branch can also be deleted
```

If the local branch deletion fails because of "not fully merged" —
double-check that the cherry-pick actually included the same content as
the branch tip. If yes, force with `git branch -D`.

Worktrees that **stay** after this objective:

- `../Eta-latch` — research in progress.
- `../Eta-otel-baseline` — reference snapshot.
- `../Eta-heartbeat` — out of scope per user direction.
- `../Effet`, `../Effet-OxCaml` — predecessor repos.

---

## 9. What the experimenter should not do

- Use `git merge` (any flavor — no `--no-ff`, no `--squash`).
- Push through a failing test by relaxing the gate.
- Silently expand scope when Semaphore conflicts force restructuring.
- Touch `../Eta-latch`, `../Eta-otel-baseline`, or `../Eta-heartbeat`.
- Commit the uncommitted mutable-ref work without first reading what's in
  `PLAN.md` and `journal/` (they may be local-only scratch that should be
  excluded from the commit).
- Skip `audit/run.sh` after the Semaphore land — Pool internals changed.
- Re-introduce a dependency the project rejected (no cohttp-eio, no
  conpool, no uri etc. — applies to ports too if they accidentally pull
  in deps).

---

## 10. After it lands

The next session can pick up the eta-otel rebuild (Eta-5zo) with all four
primitives in place. Specifically:

- `Eta.Log_level` is in place for the eta-otel logs pipeline (S3 of the
  eta-otel rebuild).
- `Eta.Redacted` is in place for OTLP attribute redaction at exporter
  boundaries.
- `Eta.Semaphore` is in place for OTLP batch admission control.
- `Eta.Mutable_ref` is in place as the named substrate for upcoming
  research (Latch, FiberRef, RcRef).

The merge does not commit us to running eta-otel rebuild next; the user
can pick any direction. The merge just lands work that's been ready for
days.

---

This document is the master objective. When in doubt, this file wins.

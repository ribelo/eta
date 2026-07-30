# Objective: DX-E42b — Hygiene batch: ppx_sql split, docs tiering, Mutable_ref purity, race naming

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e42b`
- Branch: `research/dx-e42b-hygiene-batch` (already checked out here; do not create others)
- Wave: EOP hardening, item 10/14 · Four small disjoint items in one batch
- Evidence IDs: `V-DX-E42B-*` (orchestrator log); your journal is the branch record

## Executor profile

Four hygiene items, each small, none requiring design invention — but each
demanding a different discipline: package plumbing (the ppx split),
defensible classification prose (the tier map), precise contract writing
(the purity clause), and evidence-driven verdict writing (the race
question). The difficulty is doing all four cleanly without letting any
one of them sprawl. Docs-first where a contract changes; journal one
section per item.

Consumption model (V-DX-PRINC-1): every surface here is public and
externally consumed. In-repo usage counts bound the repo's migration, not
the API's value.

## Read first (in order)

1. `AGENTS.md` — package-boundary policy (least astonishment: opam name ↔
   dune public name ↔ OCaml module line up), Nix-only gates, no shims,
   delete old paths, conventional commits.
2. `lib/ppx/ppx_eta.ml` + `lib/ppx/dune` — the file being split.
3. `lib/eta/mutable_ref.mli` — current `update`/`update_and_get` docs.
4. `lib/eta/effect.mli` — the `race` doc block.
5. `.scratch/research/dx/e41/report.md` — batch format reference.

## The four items (each is a contract)

### 1. `ppx_sql` split

`ppx_eta` must not contain SQL. Move all `sql_*` machinery and the
`sql_table_extension` registration out of `lib/ppx/ppx_eta.ml` into a new
package:

- New public library: `ppx_eta_sql` → module `Ppx_eta_sql`
  (`lib/ppx_sql/`), `(kind ppx_rewriter)`, `ppxlib`-only dependency (the
  generated code references `Eta_sql` names; the rewriter itself needs no
  SQL dependency).
- `ppx_eta` keeps: `eta_error` deriver + `fn`/`sync`/`result` extension
  rules. Nothing else.
- **The user-facing extension name `eta.sql.table` does NOT change** —
  it is already sql-namespaced; renaming it breaks users for zero
  semantic gain. Document the package move in the changelog instead.
- Migrate every consumer's `(preprocess (pps …))`: `test/sql_common`,
  `test/type_errors` (6 sql cases), `test/connectors_loader`, plus any
  others you find. `test/type_errors` cram snapshots: verify byte-stability
  of the rejection messages; if the transformation name leaks into output,
  record the snapshot update explicitly in the journal with before/after.
- opam/dune-project plumbing per the repo's pattern (check how `ppx_eta`
  is declared and mirror it).

### 2. Docs-level tiering

The audit warned the monorepo's production circumference can steer the
core. Answer it with a public map: `docs/packages.md` (new), linked from
`README.md`, classifying all 48 public packages into four tiers with a
one-line rule per tier:

- **core** — what an ordinary Eta program needs;
- **batteries** — general-purpose, no external service/protocol deps;
- **integrations** — external protocols, services, drivers, codecs;
- **labs** — unstable/experimental; may change without ceremony.

Every package gets exactly one tier with a one-line justification where
non-obvious. The tier definitions are rules, not vibes: a reviewer must be
able to re-derive every classification from them. If a package fits two
tiers, the journal records the tie and the rule that broke it. No package
moves — this is docs-only.

### 3. `Mutable_ref` purity contract

`update : 'a t -> ('a -> 'a) -> unit` retries on CAS failure — the
callback may be re-executed an arbitrary number of times, and effects in
it would multiply. The adjudicated deliverable is a **prose-only
contract**:

- `lib/eta/mutable_ref.mli`: `update` and `update_and_get` docs must state
  loudly that `f` must be pure, that it may run zero-to-many times, and
  what happens to effects if it isn't (they multiply — logging, sends,
  increments). State the why (CAS retry) in one sentence.
- `docs/api-dx.md`: one new footgun entry (accepted-and-mitigated class).
- Journal: one paragraph on whether OxCaml mode/purity annotations could
  enforce this, and why prose was chosen (the adjudication already
  decided prose; your paragraph is the record for future re-examination).
- No type changes.

### 4. `race` naming — review question, evidence-decided

`race : ('a, 'err) t list -> ('a, 'err) t` — "first child to produce a
value wins" (first-success). JS `Promise.race` is first-settlement (a
failure can win). The audit proposed `race_success`/`race_first`; the
adjudication weakened it to a review question.

Deliverable: an evidence-based verdict in the journal, plus its
consequences:

- Count `race` call sites repo-wide; survey the mli/docs for how the
  semantics are taught today.
- Check for any in-repo evidence that the JS-divergent semantics (failure
  does not win) actually surprised a caller (test names, comments,
  red-team notes).
- **Pre-registered flip condition:** if such evidence exists, rename to
  `race_success` and migrate. Otherwise keep `race` and add one explicit
  doc sentence naming the JS divergence ("unlike `Promise.race`, a typed
  failure does not win — it only wins when every child fails" or whatever
  the exact semantics are — verify against the implementation, not the
  doc's first sentence alone).

## Protocol (predictions FIRST; one journal section per item)

1. **Seal your predictions** in `.scratch/research/dx/e42b/journal.md`:
   per item — expected census/paths delta, expected verdict shape, one
   likeliest review reservation. Commit before any code change
   (`docs(dx-e42b): seal predictions`). Never edit afterward.
2. **Docs-first** where contracts change (mutable_ref.mli, race doc,
   packages.md).
3. **Implement** item by item; commit per item (`feat(ppx): …`,
   `docs: …`, `docs(dx-e42b): …` as appropriate).
4. **Gates** (exact, on the final tree):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo
   ```
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras**: census table (packages, ppx_eta rules, vals
   touched); footgun delta (+1 documented / +0 removed expected);
   type_errors snapshot-stability note; race call-site count.
6. **Red-team pass (lightweight):** for the tier map — try to
   misclassify two packages using the tier rules as written; if the rules
   allow two defensible answers, tighten them. For Mutable_ref — write the
   multiplying-effect bug once, show the docs now warn against it.
7. **Report** `.scratch/research/dx/e42b/report.md`: per item — evidence,
   actuals vs sealed predictions (scored), deviations, verdict. End with
   one promote/hold/kill recommendation per item.

## Done means

Final message ends with exactly one of: `E42B READY FOR REVIEW` /
`E42B BLOCKED: <reason>` / `E42B STOP: <stop condition>`.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/dx.md`, `docs/research/dx-ledger.md`,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in the four items. Adjacent findings → journal follow-ups.
- `objective.md` stays uncommitted; `.scratch/research/dx/e42b/` must be
  committed.

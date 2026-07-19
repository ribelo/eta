# Objective: DX-E7 — Error-renderer deriver in `ppx_eta` (generates `pp_err`)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e7`
- Branch: `research/dx-e7-error-pp-deriver` (already checked out here; do not create others)
- Phase: C (syntax & PPX) · Effort M · Risk low
- Evidence IDs: `V-DX-E7-*` (orchestrator log); your journal is the branch record

## Executor profile

First deriver in `ppx_eta` (currently 424 lines, extension points only — you
are adding `str_type_decl` infrastructure). OCaml AST/ppxlib work with
snapshot-tested expansions and PPX-time rejection messages that are
reviewed as API (T7). The difficulty is AST correctness, honest rejection
messages, and keeping the expansion to "code a reviewer would approve
verbatim" (T4) — not design invention; the expansion shape below is the
contract. Taste demand: moderate (telemetry strings are user-facing).

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Telemetry
defaults must *mean* something: `"<typed failure>"` in a span status is a
DX bug (T6). This experiment makes the meaningful default the path of least
resistance. No ambient magic (T9): the deriver only generates a plain `pp`
function; wiring it into spans is always explicit (`?error_pp` /
`with_error_pp`).

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/ppx/ppx_eta.ml` — the whole file (424 lines); note there are no
   derivers yet, and note the two dead rejection paths you must NOT touch
   (orchestrator backlog item — journal-note them only).
3. `lib/eta/effect.mli` — the `?error_pp` socket: `with_error_pp`,
   `named ?error_pp`, `fn ?error_pp` (post-E25 spellings), including the
   totality contract (a raising `error_pp` becomes a defect).
4. `lib/eta/effect_core.ml` and `lib/eta/runtime_observability.ml` — where
   the `"<typed failure>"` placeholder is produced today.
5. Two example error types, e.g. `examples/typed_error_boundary.ml` and
   `examples/error_rendering.ml`.
6. `.scratch/research/dx/e23/journal.md` — format bar for your journal.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Design is decided; skip hypothesis theatre. Proof obligations: expansion is
exactly the plain-match shape below (snapshot corpus), unsupported payloads
fail at PPX time with rubric-passing messages (negative snapshots), and a
golden span-status test proves the derived `pp_err` renders through the
real tracer.

Working artifacts in `.scratch/research/dx/e7/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E7)

**Proposal.** A `ppx_eta` deriver, strictly syntactic (T9):

```ocaml
type err =
  [ `Not_found of string
  | `Db of int
  | `Unavailable ]
[@@deriving eta_error]
```

expands to a review-acceptable plain function (T4):

```ocaml
let pp_err : Format.formatter -> err -> unit = fun fmt -> function
  | `Not_found id -> Format.fprintf fmt "not_found:%s" id
  | `Db code -> Format.fprintf fmt "db:%d" code
  | `Unavailable -> Format.pp_print_string fmt "unavailable"
```

v1 scope: polymorphic variants only; built-in payload renderers for
`string`, `int`, `int64`, `float`, `bool`; any other payload is a
**PPX-time error** unless the constructor carries `[@eta.render f]` naming
a `pp` — no silent `<payload>` placeholders (placeholders are how
`"<typed failure>"` reproduces). Nominal variants only if they keep the
same plain-match shape.

Usage: `Effect.named ~error_pp:pp_err "db.save" …`, or one
`Effect.with_error_pp pp_err` per module subtree.

**Semantics & edges.** None — pure generation. Rendered strings are stable
telemetry: renaming a tag changes dashboards; documented as honest and
visible.

**Gates from the one-pager.** Promote if coverage hits 100% without
hand-written renderers remaining in examples. Kill if the payload long tail
forces the deriver past "plain match you would approve in review" — then
the honest answer is manual `pp` + better docs, not a smarter PPX.

## Protocol (predictions commit FIRST and separately; then step commits)

1. **Seal your predictions** in `.scratch/research/dx/e7/journal.md`:
   expected expansion shapes and snapshot count, expected census deltas,
   expected review ratings (before/after telemetry), two likeliest reviewer
   misreadings. Commit before any code change
   (`docs(dx-e7): seal predictions`). Never edit afterward.
2. **Docs-first.** Write the deriver's documentation (in `ppx_eta` docs /
   mli surface as appropriate, plus the `docs/api-dx.md` telemetry section)
   before implementing: supported shapes, the tag-naming rule (constructor
   `Not_found` → `not_found`), the `[@eta.render f]` escape hatch, the
   PPX-time rejection contract, and the "renaming a tag changes dashboards"
   stability note. ≤ the doc budget; overruns mean redesign, not prose.
3. **Implement the smallest change.** v1 scope only. Every rejection path
   uses `Location.raise_errorf` with a message that answers what/where/
   what-next (T7).
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   PPX work is compile-time; if any generated code lands in a JS-track
   package, add `nix develop .#mainline -c dune build --build-dir=_build-mainline <targets>`
   (JS builds use the dedicated `_build-mainline` directory since the F1
   fix — never share `_build` between compiler tracks). Fix-forward up to three attempts per
   failure class, then BLOCKED.
5. **Mechanical extras.**
   - **Expansion snapshot corpus** (printed AST → expected-file tests):
     nullary constructors; each built-in payload type; mixed; `[@eta.render
     f]` override; rejection snapshots for an unsupported payload and (if
     nominal variants are out of v1) a nominal variant. Rejection snapshots
     capture the full compiler error text.
   - **Golden span-status test** with the in-memory tracer:
     `Effect.named ~error_pp:pp_err "db.save" (Effect.fail (`Db 7))` yields
     a span status containing `db:7` — end to end, not unit-mocked.
   - **Coverage census** of `examples/`+`docs/` error types: derive
     `pp_err` for each and wire it where spans are named; target 100%
     renderer coverage, zero hand-written renderers remaining. Table in
     your journal.
   - Census: PPX forms cluster +1. Footgun delta: expect −1/+0.
6. **Red-team pass**, committed under `.scratch/research/dx/e7/redteam/`:
   (a) attempt to make the deriver emit a placeholder — must be impossible
   (PPX-time error, snapshot it); (b) a raising `pp_err` — confirm the E25
   contract holds (defect, not silent telemetry loss); (c) a tag renamed
   across two commits — show the telemetry string changes (honest,
   documented).
7. **Review packet** in `.scratch/research/dx/e7/review/`, labeled (the
   orchestrator randomizes): (a) `telemetry-before.txt` / `telemetry-after.txt`
   — real span-status/log excerpts for the same programs, placeholder vs
   derived rendering; (b) two expansion excerpts (`expansion-1.ml`,
   `expansion-2.ml`) as "would you approve this in a PR" material;
   (c) `MANIFEST.md`; (d) `QUESTIONS.md` — e.g. "is `pp_err` wired
   automatically?", "what happens to a payload type the deriver doesn't
   know?", "what does a raising pp become?".
8. **Report** in `.scratch/research/dx/e7/report.md`: gates summary,
   snapshot/golden-test evidence, coverage table, census/footgun actuals
   vs. sealed predictions (scored), red-team outcome, deviations, and your
   promote/hold/kill recommendation against the one-pager's gates.

## Done means

Your final message ends with exactly one of:

- `E7 READY FOR REVIEW`
- `E7 BLOCKED: <reason>`
- `E7 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E7 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E7's surface. The two dead PPX rejection paths are a backlog
  item — do not delete them here; journal-note only. Other derivers
  (`show`-style, nominal variants if out of v1) are out of scope.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e7/` must be committed.

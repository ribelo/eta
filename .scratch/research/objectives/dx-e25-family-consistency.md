# Objective: DX-E25 — Family consistency: `with_scope`, `named ?kind`, `now_ms`, `error_pp`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e25`
- Branch: `research/dx-e25-family-consistency` (already checked out here; do not create others)
- Phase: A (idiom pass) · Effort S–M · Risk low
- Evidence IDs: `V-DX-E25-*` (orchestrator log); your journal is the branch record

## Executor profile

Four mechanical renames with a large raw line count (~490 call-site lines),
plus one semantic edge that needs care: `error_pp` rendering semantics (at
most once per span status/exception event; a raising pp becomes a defect
through the ordinary capture path). Difficulty is thoroughness and gate
patience; design is fully dictated below. E23/E24 are merged on master —
the surface you build on is final.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. One name per
verb family; OCaml's `Format` culture (`pp` functions, `[@@deriving show]`)
should plug straight into telemetry. North star: *`Effect` is `Result` with
concurrency and spans.*

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/effect.mli` — `scoped` (~line 525), `with_error_renderer`
   (559), `named` (603), `named_kind` (675), `fn` (921), `now` (373), and
   the lifecycle `with_*` family around them.
3. `docs/api-dx.md` — sections touching these names.
4. `.scratch/research/dx/e24/report.md` — the previous experiment's report;
   match or beat its evidence standard. Note how the E24 blocker was
   handled: if you find the contract below unwritable or its semantics
   unstatable, stop with a reproducible probe — do not improvise.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Design is decided; skip hypothesis-space theatre. Proof obligations:
migration completeness, behavior parity (renames change nothing), and the
`error_pp` rendering contract (the one new semantic statement).

Working artifacts in `.scratch/research/dx/e25/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E25)

**Proposal.**

```ocaml
val with_scope : ('a, 'err) t -> ('a, 'err) t        (* was scoped *)
val named :
  ?kind:Capabilities.span_kind -> ?error_pp:(Format.formatter -> 'err -> unit) ->
  string -> ('a, 'err) t -> ('a, 'err) t             (* absorbs named_kind *)
val now_ms : (int, 'err) t                           (* was now *)
val with_error_pp :
  (Format.formatter -> 'err -> unit) -> ('a, 'err) t -> ('a, 'err) t
  (* was with_error_renderer; renders internally, once per failure *)
```

Deletions (no shims): `scoped`, `named_kind`, `now`, `with_error_renderer`,
and `?error_renderer` everywhere (`fn`, `named`) — replaced by `?error_pp`.
The `"<typed failure>"` default is unchanged; only the injection shape
changes. Erasure check (E24 lesson): the two optionals in `named` are
followed by mandatory `string` and the effect — omission calls must yield
`Effect.t`, verify.

**Semantics & edges.** None. `error_pp` output is rendered at most once per
span status/exception event; the pp must be total — a raising pp becomes a
defect via the ordinary capture path (document this).

## Protocol (predictions commit FIRST and separately)

1. **Seal your predictions** in `.scratch/research/dx/e25/journal.md`:
   expected teach-back answers, census/footgun deltas, two likeliest
   reviewer misreadings. Commit before any code change
   (`docs(dx-e25): seal predictions`). Never edit afterward.
2. **Docs-first.** Rewrite the four `.mli` contracts (plus `fn`'s
   `?error_pp`) before implementation. Each ≤ ~10 lines. The `error_pp`
   docs must state: rendered at most once per span status/exception event;
   pp must be total; a raising pp becomes a defect.
3. **Implement the smallest change.** Renames, merge, deletion; migrate
   every call site the gates build, including docs code blocks and the
   `lib/jsoo/eta_jsoo.mli` doc cross-reference.
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo lib/jsoo
   ```
   (`test/cache_jsoo`, `test/http_js` have no call sites per orchestrator
   pre-check — if you find any, build them too and note it. `signal_jsoo`
   stays pre-broken per F1; do not touch it.)
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - **Golden span-status test**: a typed failure inside
     `named ~error_pp:pp_err "db.save" …` renders the pp's domain string
     into the span status (T6 socket for E7's deriver); a second test
     proves render-once (no double-render); a third proves a raising pp
     surfaces as a defect, not a swallowed status.
   - Erasure probe: omission calls (`named "x" eff`, `named ~kind:k "x"
     eff`, `named ~error_pp:pp "x" eff`) all yield `Effect.t` — compile
     evidence.
   - Census table: observability cluster before/after (expect −1 val);
     lifecycle family uniform `with_*`; verify independently.
   - Footgun delta: expect −1/+0.
   - `docs/api-dx.md` updated — explicit checklist item.
6. **Red-team pass.** (a) A raising `error_pp` — show the defect path and
   that telemetry degrades honestly; (b) the `named`/`named_kind`
   guess-which-one bug the old pair invited — show the merged `named`
   makes it unwriteable.
7. **Review packet** in `.scratch/research/dx/e25/review/`, labeled: two
   A/B pairs, 10–30 lines each — (a) a scoped resource region + named span,
   old vs. new; (b) an error-rendered named leaf, old vs. new.
   `MANIFEST.md`, `QUESTIONS.md` ("which combinator opens a resource
   scope?", "what does `error_pp` change and what stays `"<typed
   failure>"`?", "is `now_ms` wall time?").
8. **Report** in `.scratch/research/dx/e25/report.md`: gates summary,
   golden-test evidence, census/footgun actuals vs. sealed predictions
   (scored), red-team outcome, deviations, and a per-rename
   promote/revert recommendation (the one-pager allows reverting a single
   confusing rename while promoting the rest — only with evidence).

## Done means

Your final message ends with exactly one of:

- `E25 READY FOR REVIEW`
- `E25 BLOCKED: <reason>`
- `E25 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E25 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E25's surface. Adjacent footguns → journal follow-ups.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e25/` must be committed.

# Objective: DX-E20 — `Effect.intercept_log` / `intercept_metric`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e20`
- Branch: `research/dx-e20-intercept` (already checked out here; do not create others)
- Phase: D (runtime & model) · Effort M · Risk low–med
- Evidence IDs: `V-DX-E20-*` (orchestrator log); your journal is the branch record

## Executor profile

Fiber-local machinery applied to two new pipeline stages: interception
transforms for log records and metric points, composed with the existing
filter/attributes stages and E19's scoped overrides. E19 just built the
pattern and documented the order — your job is exact composition, parity
proofs, and one honest benchmark line. Import provenance: polysemy
`intercept` (cite in the journal).

## Mission

Eta may be complicated inside; using Eta must feel beautiful. polysemy's
`intercept` interposes on an effect: observe or transform its calls
without replacing the implementation. Eta already owns two private cases
of that shape — `annotate_logs` (enrich) and `with_minimum_log_level`
(filter). The general form unifies them and unlocks redaction, sampling,
and record-and-assert testing. Redaction becomes a mechanism, not a
discipline (T6).

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/effect_observability.ml` — the fiber-local log stages
   (`annotate_logs`, `with_minimum_log_level`) you compose with.
3. `.scratch/research/dx/e19/report.md` and the E19 section of
   `docs/zio-boundaries.md` — the **documented order is the contract**:
   scoped min-level filter → scoped/per-call attributes → **intercept
   transform** → sink. Your implementation and docs must match it exactly.
4. `lib/eta/capabilities.mli` — `log_record` and `metric_point` types.
   Note: there is NO bare `metric` type; the one-pager's
   `(metric -> metric option)` means `metric_point`.
5. The E19 `with_logger`/`with_tracer` contracts in `lib/eta/effect.mli` —
   interplay you must document against.
6. `bench/runtime_watchlist/` — where the fast-path benchmark line lives.

## The experiment (one-pager, from DX-PRD-0001 §E20)

```ocaml
val intercept_log :
  (Capabilities.log_record -> Capabilities.log_record option) ->
  ('a, 'err) t -> ('a, 'err) t
val intercept_metric :
  (Capabilities.metric_point -> Capabilities.metric_point option) ->
  ('a, 'err) t -> ('a, 'err) t
```

`None` drops the record. `annotate_logs`/`with_minimum_log_level` remain
the friendly special cases (progressive disclosure: common tasks keep
one-word answers; the general mechanism serves power users). Transforms
compose outermost-to-innermost; `None` short-circuits. Intercept runs
before the logger/meter; order vs. E19 overrides documented (transform
applies to whatever sink is currently bound). Hot-path cost: one function
call per record, documented; no allocation when the transform is
`Some`-identity (fast path).

**Gates from the one-pager.** Promote if shorthands' parity is exact and
hot-path cost is noise-level on the watchlist. **Kill the metric half**
if nobody can write a compelling `intercept_metric` use case in review
(the log half stands on its own).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: exact parity of the shorthands, composition order,
drop semantics, one benchmark line. Working artifacts in
`.scratch/research/dx/e20/` **on this branch** (commit them):
`journal.md`, `report.md`, `redteam/`, `review/`.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e20/journal.md`
   before any code change (`docs(dx-e20): seal predictions`).
2. **Docs-first.** Write the `.mli` contracts before implementing. Must
   state within budget: fiber-local (only records emitted in the
   subtree); runs AFTER the min-level filter and attribute stages (the
   E19 order — restate it); `None` drops the record AND short-circuits
   later transforms; composition is outermost-to-innermost; applies to
   the currently bound sink (with E19 interplay example); `Some`-identity
   is allocation-free.
3. **Implement** the smallest change over the existing locals.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo
   ```
   (`signal_jsoo` is expected-fail on master — do not touch it.)
5. **Mechanical extras.**
   - Composition order test (two nested intercepts: outer sees record
     first; inner's `None` prevents outer? no — outer-to-inner means
     outer's transform runs FIRST, then inner's; document and test the
     exact direction with a trace of transform calls).
   - Drop semantics: `None` → record never reaches the sink; later
     transforms never run.
   - Shorthand parity: `annotate_logs` and `with_minimum_log_level`
     behave byte-identically to pre-E20 (existing suites stay green
     unchanged).
   - E19 interplay: `with_logger` inside vs outside an `intercept_log` —
     both orders tested and documented.
   - Redaction use case: a scrub transform (e.g., rewrite a
     password-bearing attribute to `"[redacted]"`) — executable.
   - Metric use case: per-subtree label enrichment (e.g., add
     `tenant=acme` to every metric point in a subtree) — executable;
     this is the metric half's survival evidence.
   - Fast-path benchmark line in `bench/runtime_watchlist/`:
     `Some`-identity intercept vs no intercept — record the numbers.
   - jsoo parity for `intercept_log`.
   - Census: observability cluster +2 vals / +1 concept; footguns +0
     with the three trap candidates recorded as disarmed-by-docs.
6. **Red-team pass** in `.scratch/research/dx/e20/redteam/`: (a) write
   the code that expects `intercept_log` to see a record the min-level
   filter dropped — show it can't, and the mli said so; (b) an intercept
   that raises — record what happens (defect via ordinary capture path,
   per E25's totality contract) and whether docs cover it.
7. **Review packet** in `.scratch/research/dx/e20/review/`: (a)
   `redact-old.ml` (today's discipline: a hand-filtered wrapper logger)
   vs `redact-new.ml` (`intercept_log` with an inline scrub); (b)
   `metric-old.ml` vs `metric-new.ml` for subtree label enrichment —
   if you cannot make the metric case compelling HONESTLY, say so in
   the report and recommend the metric kill (that is a legitimate,
   pre-registered outcome). `MANIFEST.md`, `QUESTIONS.md` ("which
   combinator drops records?" / "in what order do filter, attributes,
   and intercept run?").
8. **Report** in `.scratch/research/dx/e20/report.md`: gates, parity
   evidence, composition/drop results, benchmark numbers, census/
   footguns vs. predictions (scored), red-team outcomes, and your
   recommendation — with the metric half's fate argued separately.

## Done means

Your final message ends with exactly one of:

- `E20 READY FOR REVIEW`
- `E20 BLOCKED: <reason>`
- `E20 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E20 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E20's surface: the two intercept combinators, their tests,
  docs, benchmark line. Do NOT reimplement `annotate_logs`/
  `with_minimum_log_level` as intercept shorthands (they stay as they
  are — parity is the point), do NOT touch `eta_redacted`,
  `Schedule.t`, or E19's combinators.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e20/` must be committed.

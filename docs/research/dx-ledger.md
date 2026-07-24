# DX ledger — what / rationale / decision / decision rationale

The programme's complete map: what we want, why we want it, what we
decided, and why we decided that. Companion records: `dx-journal.md`
(protocol log, `.scratch/research/`), `dx.md` (curated conclusions),
`dx-prd-0001.md` (the original plan). Status: **promoted / killed /
held / in-flight / queued / proposed**. Every kill is a success with
evidence; every hold names its re-entry trigger.

## Shipped — Phase A (idiom pass)

### E23 — Error channel mirrors `Result` — promoted
- What: `catch`→`bind_error`; `recover`/`or_else_succeed`→`fold`;
  `result`/`option`/`exit`→`to_result`/`to_option`/`to_exit`.
- Rationale: OCaml already owns the `Result` mental model; the error
  channel becomes teachable in one sentence.
- Decision rationale: blind review 4,4,4 vs 3,3,1; `catch` produced its
  invited bug ("try/with") on demand; top footgun removed by construction.

### E24 — Iteration mirrors `List` — promoted
- What: `map_par ?max_concurrent f xs` absorbs `for_each_par[_bounded]`;
  `retry`/`retry_or_else`/`repeat` labeled data-last. `retry_or_else`
  KEPT; `Schedule.t` untouched (slimming held → E24b).
- Rationale: `for_each` collects = name/type lie; optional args are the
  OCaml shape.
- Decision rationale: oracle consultation proved two-error
  `retry_or_else` irreplaceable by `map_error`; default cap 8 made
  explicit + tested. Review 5,4 vs 3,3.

### E25 — Family consistency — promoted
- What: `scoped`→`with_scope`; `named_kind`→`named ?kind`; `now`→
  `now_ms`; `with_error_renderer`→`with_error_pp`.
- Rationale: one name per verb family; Format culture for renderers.
- Decision rationale: call sites read uniformly; prepares the socket
  E7's deriver plugs into.

## Shipped — Phase B (hygiene)

### E1 — `sync_result` / `sync_option` — promoted
- What: one-word lifting for result/option-returning thunks.
- Rationale: the hottest leaf pattern was two combinators deep.
- Decision rationale: `sync_result` clean promote. `sync_option` killed
  on zero usage, then **promoted by human decision authority** — the
  symmetry argument won at the top level. (Recorded: evidence said kill,
  human said ship; both on record.)

### E2 — `discard` + generalized `ignore_errors` — promoted
- What: `Effect.ignore` deleted; value-discard (`discard`) and
  error-suppression (`ignore_errors`) are now two honest names.
- Rationale: `ignore` silently swallowed typed failures — the most
  misleading name in the surface.
- Decision rationale: old rated 1, split rated 5; the swallowed-error
  bug now requires explicit intent.

### E3 — `race_either` — **killed**
- What: heterogeneous race via `` `Left/`` `Right ``.
- Decision rationale: domain-tagged variants (`` `Timeout/`` `Done ``)
  beat positional tags (5 vs 4). Map-wrapped recipe remains the
  recommendation. Library stays one val smaller.

### E4 — `Cause` rendering corpus — promoted
- What: `Cause.pp_compact` one-liner; snapshot corpus; structured
  encoding for otel.
- Rationale: span statuses/log fields needed a one-line form; tree
  rendering was unreviewed for ugly composites.
- Decision rationale: kill gate fired on the first notation (lost
  finalizer role), rework fixed it (`suppressed: finalizer(f)`), double
  re-review passed. Corpus is the model documentation.

### E5 — Type-error translations — promoted
- What: cram-style negative compile tests + `docs/type-errors.md`
  ("Eta type errors, translated").
- Rationale: rank-2/skolem errors are correct and unreadable; library-
  owned error UX (polysemy lesson).
- Decision rationale: reviewers solve with the page and explain the
  rank-2 rationale back. Snapshots fail CI on drift.

### E6 — Parallel resource acquisition — **helpers killed, recipe promoted**
- What: proposed `Scoped.with_2/3` helpers; the
  `with_scope + acquire_release + map_par` recipe.
- Decision rationale: helper cohort 3,3,3 vs ladder 5,5,4 — labelled
  boilerplate lost. The recipe is the one obvious spelling. **`and@` is
  killed by this experiment's existence.**

## Shipped — Phase C (syntax & PPX)

### E7 — `[@@deriving eta_error]` — promoted (+E7b rework)
- What: generates `pp_err`; span statuses show domain errors, not
  `"<typed failure>"`. E7b added the `.mli` signature generator.
- Rationale: telemetry should mean something by default (T6).
- Decision rationale: 100% example coverage; expansions rated
  "approve verbatim" (5,5); telemetry before 2 → after 4.

### E8 — `[%eta.result "name" body]` — promoted
- What: the named result-leaf as one expression (expands to
  `fn`/`named`/`sync_result`).
- Rationale: most-frequently-typed boilerplate; sugar follows frequency.
- Decision rationale: operators per leaf 4 → 1; expansion accepted as
  verbatim PR rewrite (T4). `[%eta.option]` excluded — sugar follows
  frequency, not symmetry.

### E9 — `Syntax.Parallel`/`Applicative` split — **held**
- What: module-switched `and*` semantics.
- Decision rationale: measured comprehension delta 0 (baseline 2/6,
  explicit 2/6); module names carry no semantics. Superseded by E9b.
  Branch kept as provenance.

### E9b — Sequential `and*` — promoted
- What: `and*`/`and+` sequential everywhere; concurrency spelled
  `Effect.par`.
- Rationale: under old `and*`, misreading wrote a correctness bug;
  under sequential, it costs latency only. Human chose option B (least
  astonishment).
- Decision rationale: 0/6 dangerous misreadings; the race became
  unwriteable. Safety beats comprehension for lazy blueprints.

### E10 — Function sugar — **`let%eta` killed; `[@@eta.trace]` pre-selected**
- What: definition-site tracing sugar.
- Decision rationale: `let%eta` killed unanimously (names the library,
  not the intent). `[@@eta.trace]` validated (5×6) with a defined
  promote trigger (real-app frequency) — measured by E31.

## Shipped — Phase D (runtime & model)

### E26 — `Effect.fresh` / `fresh_named` — promoted
- What: runtime-owned monotonic unique tokens (fused-effects `Fresh`).
- Rationale: fiber names, correlation ids, fixtures need uniqueness
  without DIY counters.
- Decision rationale: per-runtime semantics documented AND tested
  (cross-runtime collision is an executable test). F6: scope misread
  watch.

### E19 — Scoped capability overrides — promoted (+E19b rework)
- What: `with_clock`/`with_random`/`with_logger`/`with_tracer` —
  fiber-local dynamic bindings (polysemy `reinterpret` in Eta's idiom).
  E19b closed the Expert bypass (call-time selectors).
- Rationale: fake clock for one test without a bespoke runtime.
- Decision rationale: 13-case edge matrix green; review 4 vs 3.
  Flagship import. A scoped substrate is only as good as its fences.

### E20 — `intercept_log`/`intercept_metric` — promoted (as E20b)
- What: `Keep | Drop | Replace` transforms (polysemy `intercept`).
- Rationale: redaction, sampling, record-and-assert as mechanism.
- Decision rationale: option-repr HELD on measured allocation
  (+10.5 words/record); the variant repr is free by construction;
  control measurement showed the residual is the shared scoped-stage
  cost. Cost contracts are measured, never asserted.

### E12 — `audit` / `describe` — promoted; **manifest role killed**
- What: blueprint introspection (names, capability footprints, static
  tree) + 7 `Eta_test` assertions.
- Rationale: the blueprint is reified; claims should be executable (T5).
- Decision rationale: API promoted (properties green; tutorial 5/5).
  Manifest killed: flags mislead exactly at dynamic continuations —
  became E17's gate evidence. Honest boundaries beat total claims.

### E11 — `Eta_test.Run` — promoted; **`finalizer_events` killed**
- What: one golden outcome record (exit, logs, spans, metrics, sleeps,
  pending fibers) + printers.
- Rationale: the hard questions ("did retry sleep 10/20/40; is any
  fiber pending") needed one call, no wall time (polysemy
  `runOutputMonoid`).
- Decision rationale: old assembly's evidence proven CIRCULAR cold
  (rated 1). `finalizer_events` killed per the zero-cost seam gate;
  printer says "unavailable" instead of faking.

### E13 — `Effect.async` — promoted
- What: callback-shaped leaf with six guarantees, both substrates.
- Rationale: wrapping an emitter/timer/JS promise/C callback required
  the `Expert.make` escape hatch.
- Decision rationale: oracle found a jsoo retention leak pre-merge
  (fixed: removable subscriptions). The `addEventListener` wrap is 20
  lines vs a page of Expert boilerplate.

### E14 — `Eta.Promise` — promoted
- What: backend-neutral one-shot cell (create/await/resolve).
- Rationale: `Eio.Promise` pins code to native; the leak had reached
  the public test API.
- Decision rationale: correctness review CORRECT with zero rework;
  first-commit ordering; `Eta_test.Async` migration held with evidence
  (eta_test is eio-flavored).

## Shipped — Phase E (research)

### E22 — Law-property policy — promoted
- What: "every law in an mli has a test" — 63 qcheck properties, census
  (LAWS.md), AGENTS.md policy, `effect.mli` gained normative equations.
- Rationale: untested prose is where models drift (fused-effects
  hedgehog culture).
- Decision rationale: 3 oracle rounds; 10 findings closed (incl. a
  vacuous schedule property — vacuous tests fake the safety net).
  Registry: 99 direct + 101 external + 23 dated-debt rows.

### E24b — Schedule-hook ownership — promoted (decision)
- What: is the third `Schedule.t` parameter load-bearing? Verdict:
  policy-owned hooks are correct *while they exist*, but **delete the
  channel** (zero production producers; better ordinary recipe;
  falsifiable reversal gate).
- Rationale: registered at E24's slimming hold.
- Decision rationale: verdict flipped twice on evidence; the deletion
  baseline was almost never written down.

### E24c — Hook-channel deletion — promoted
- What: `Schedule.t` 3→2 params; taps/suspended-step/step_plan/
  step_with_hooks/no_hook removed; engine rewritten.
- Decision rationale: 62 law properties green; deliberate regression
  caught by the net; mli 140→100 lines. The library's ugliest public
  type parameter is gone.

### E24d — Retry cause-alignment — promoted
- What: `retry` shares the `bind_error` catchability boundary;
  composites retry; original cause preserved at every terminal.
- Rationale: two `retry*` combinators had two silent ideas of a
  retryable failure.
- Decision rationale: divergence proven accidental with commit
  evidence; prediction full sweep; review flipped executor's
  empty-composite `invalid_arg` to conservative pass-through.

## In flight

### E15 — `Effect.interruptible` — promoted 2026-07-24
- What: restore cancellation inside `uninterruptible` (masks stack,
  innermost wins; finalizers never restore).
- Rationale: an uninterruptible accept loop or cleanup-that-awaits was
  inexpressible without dodging the mask.
- Decision rationale: shipped after the programme's deepest arc — a
  rigorous kill, an evidence-based kill rejection
  (`Eio__core__Switch.run_in` found + reproduced), and four review
  rounds (fork-inheritance deadlock → fiber-local bindings; descendant
  `cancel_sub` bypass → both-context relay; first-wins race →
  synchronous observer). Model: masks cover children; restoration is
  fiber-local; listens to mask-entry parent + entry-time context; first
  cancellation call wins; at most once. Cost measured (~1.8M/sec).
  Follow-ups: upstream `run_in` exposure (human files); child-restore
  (R AND Q) registered as possible future experiment.

## Queued (decided, awaiting staging)

### E27 — `Effect.logf` — human pre-approved (next)
- What: Logs-style format4 logging; format only when the level is
  enabled.
- Rationale: THE OCaml logging idiom (T11); allocation only when
  enabled; E20 interception settled composition; parking-lot trigger
  ("revisit after E20") met.
- Decision: human 2026-07-23 — "necessary, useful, nice; should be
  there even without tests." Experiment is about doing it sensibly
  (signature, allocation semantics, E20 composition), not whether.

### E30 — `Eta_js.from_js_promise` — human pre-approved
- What: one adapter from a host JS `Promise` to `('a,'err) Effect.t`
  over `Effect.async`, with loud capability check (ADR 0001).
- Rationale: the jsoo track lives on callbacks; this is its most common
  interop shape. E13's first public consumption.
- Decision: human 2026-07-23 — "obvious and turbo necessary; I have
  decided that I want this." Experiment is about doing it sensibly.

### E28 — `all` vs `map_par` T1 audit
- What: are `all` and `map_par` two ways for one task? Engine census +
  cold-read → merge or differentiate with a crisp contract.
- Rationale: T1; if users can't say which to reach for, that's the
  disease E24 cured elsewhere.
- Decision: queued by human 2026-07-23.

### E29 — Concurrent product ergonomics (`par3`/`par4`)
- What: pleasant explicit concurrency for 3–4 effects (nested
  `par (par a b) c` yields nested tuples).
- Rationale: E9b made concurrency explicit; the explicit form should be
  pleasant, not penance.
- Decision: queued by human 2026-07-23.

### E31 — `[@@eta.trace]` promote-trigger measurement
- What: count real `Effect.fn __POS__ __FUNCTION__` sites; decide by
  E10's pre-registered trigger.
- Rationale: close E10 by evidence, not nostalgia.
- Decision: queued (pre-registered).

### E32 — `fold ~ok:Fun.id` usage-data re-check
- What: ~25 sites carry the noise. Does a shorthand earn its val, or
  does E23's verdict (one both-channel fold) hold?
- Rationale: F2 watch item; one look with numbers. Sealed prediction:
  verdict holds.
- Decision: queued.

### E16 — `Reader` validation race
- What: build the rival (`Reader` module) and race it against
  value-passing on one real service.
- Rationale: the no-`R` boundary should rest on in-repo evidence, not
  taste. Expected kill — either way the boundary becomes *tested*.

### E21 — Resumable-failure probe
- What: `.scratch`-only probe: can a typed-failed subtree be resumed
  without the `Cause` tree lying? Timeboxed 1 day.
- Rationale: pins down what Eta's model *forbids* and why — a boundary
  doc money can't buy. Pre-registered kills (continuation machinery vs
  no-`catchAllCause`; scope escape; `Cause` honesty).

### E17 — Runtime-capability phantom rows — **gated**
- What: `('a, 'err, 'caps) Effect.t` over a closed capability set
  (branch-only prototype).
- Gate: E12 promoted ✓ + audit data showing bugs the preflight class
  cannot catch (registered: the killed-manifest golden). Whether those
  are "real integration bugs" is the experiment's measurement.
- Decision: staged only after E16/E21, gate re-checked then.

### E18 — Deterministic simulation testing
- What: seeded single-domain scheduler interleaving fibers at
  documented checkpoints; replay-identity.
- Rationale: concurrency bugs should be found by the suite, not by
  luck. Promote when it finds its first real bug.

## Proposed (no decision yet)

### E33 — `map_par` default-cap bench ("why 8")
- What: vary the cap across workload shapes (pure compute, sleep-bound
  IO, short/long lists) on the existing bench infrastructure.
- Rationale: the 8 is measured-once-years-ago; make the documented
  default a *measured* default.
- Decision: proposed 2026-07-23; no decision recorded.

## End of queue (approved for the very end)

- **Golden tutorial programs** — the W1–W6 walkthrough tasks as living,
  tested example programs.
- **`docs/model.md`** — the blueprint/interpreter model in one page,
  using `describe`/`audit` output.
- **Law-census extension** — otel/stream/http modules into the E22
  scope (ongoing-policy work).

## Follow-ups ledger (F-items)

- F1 signal_jsoo bit-rot — **fixed** (`077f763e`).
- F2 `fold ~ok:Fun.id` noise — watch → became E32.
- F3 `catch_recovery.ml` filename — **fixed** (`c29832cc`).
- F4 `map_par` omission misreading — mitigated (mli sentence + docs +
  default-cap test); watch.
- F5 span-status typed-vs-defect encoding — otel/E4-adjacent; open.
- F6 `fresh` scope misread — watch (same class as F4).
- F7 scoped-stage active cost (~10.5 minor words/record) — runtime-
  instrument territory; benefits ALL scoped stages; open.
- F8 `Eta_test.Run` failure output cites Alcotest internals, not
  user-code location ("where" rated 3) — open.
- E22 dated law debts (CD-E22-004/008/020/022/023 named by oracle as
  readily coverable) — prioritize, don't let them fossilize.
- E22 registry granularity (compound rows R82–R93) — split on next
  census touch.

## Meta-record

- **Retro phase (2026-07-21/22):** all 19 then-shipped cases re-reviewed
  PR-style by fresh oracles; 14 fix commits; E7b/E19b reworks; the
  blind-snippet review protocol retired (V-DX-AMEND-3) in favor of
  PR-style correctness reviews + orchestrator taste assessment.
- **Scoreboard:** 20 promoted · 7 killed cleanly (E3, E6-helpers,
  `let%eta`, E11-finalizer_events, E12-manifest, E20-option-repr,
  sync_option-then-human-promoted) · 4 held (E9, E10-trace-trigger,
  Schedule-slimming→E24b, Async-migration) · 2 flips on review (E24b,
  E24d-edge) · 1 kill rejected on evidence (E15, in flight).

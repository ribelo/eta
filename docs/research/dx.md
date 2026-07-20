# Eta DX research — conclusions

Curated, durable conclusions of the DX-PRD-0001 programme
(`.scratch/research/dx-prd-0001.md`). This document exists so that a year
from now anyone can answer "why is the API shaped like this?" without living
memory. Protocol records (predictions, gates, ratings, decisions) live in
`.scratch/research/dx-journal.md`; per-experiment evidence lives on the
`research/dx-e*` branches.

Guiding star: *`Effect` is `Result` with concurrency and spans — `map`/
`map_error` on values, `bind`/`bind_error` on sequences, `fold` on both
channels.* Every conclusion here is judged by whether it moved Eta toward
that sentence.

**Status:** Phases A–C complete (A: 3 promoted · B: 4 promoted, 2 killed ·
C: 3 promoted, 2 held). Phase D: E26, E19 promoted.

## E19 — Scoped capability override (promoted 2026-07-20)

polysemy's `reinterpret`, in Eta's idiom — and explicitly **not** an
environment: `with_clock` / `with_random` / `with_logger` / `with_tracer`
are fiber-local dynamic bindings over the four runtime services, the same
machinery as `annotate_logs` at its natural home. A fake clock for one
assertion costs one combinator, not a bespoke runtime:
`Effect.with_clock (Test_clock.as_capability c) program`.

The semantics in one breath: children inherit at fork (no join-merge);
restore on success, typed failure, defect, and cancellation; innermost
wins; `par` siblings isolated; consulted at leaf call time (in-flight
sleeps and open spans don't retroactively change); daemons keep their
fork-time binding after the scope exits. All thirteen edge cases are
executable tests, on both backends.

Evidence: the W6 test (prove retry slept 10/20/40 ms) drops its
runtime-assembly ceremony for one combinator at the assertion; an
independent reviewer preferred it 4–3 and spotted the old form's footgun
unprompted (real `~clock` next to fake `~sleep`/`~now_ms`: which
operations remain real?). `Capabilities.clock` gained `now_ms` (was
sleep-only); the otel tracer gained a fiber-identity seam for open-span
ownership.

Provenance: `.scratch/research/dx/e19/` (on branch), V-DX-E19-001..002,
branch `research/dx-e19-scoped-capability-override`.

## E26 — `Effect.fresh` / `fresh_named` (promoted 2026-07-20)

Fiber names, span-correlation ids, and test fixtures get one honest source:
`fresh` (a per-runtime monotonic counter) and `fresh_named "worker"`
(formatting over the same counter). The contract that matters: unique and
increasing **only within one runtime** — explicitly not global (distinct
runtimes/domains may collide; correlate with your own namespace), and
`Eta_test` runtimes reset it, so test programs replay deterministically.
Native increments are atomic; jsoo uses a plain per-runtime cell.

Why a leaf at all: the steelmanned DIY case (hand-rolled `Atomic`, seeded
`Random`) was rejected in review — a library operation defines ownership,
isolation, reset behavior, formatting, and test determinism **once**, vs.
every caller choosing incompatible semantics. The four pre-existing
process-global counters (tracer context ids, interrupt ids, service keys,
runtime ids) keep their own cross-runtime jobs, deliberately unmigrated.

Accepted tradeoff: the name doesn't carry the runtime-local scope (cold
read misguessed it; the mli disarmed completely — rated 2-then-resolved,
preference still the new form). Logged as watch F6. Import provenance:
fused-effects `Control.Effect.Fresh`.

Provenance: `.scratch/research/dx/e26/` (on branch), V-DX-E26-001..002,
branch `research/dx-e26-effect-fresh`.

## E10 — Function-level sugar: `let%eta` killed, `[@@eta.trace]` held with a trigger (2026-07-19)

The hold-default experiment did its job. A 3-pass independent review cohort
unanimously **killed `let%eta`** (rated 3 everywhere: the name doesn't say
"trace", it says "some Eta transformation") and unanimously validated
**`[@@eta.trace]`** (rated 5 everywhere: metadata on an ordinary definition,
verbatim-PR acceptable). The promote condition ("reviewers still ask after
E7/E8") was met unconditionally by only 1 of 3 passes, so the default
holds — sharpened into a defined **promote trigger**: application code
showing the plain `Effect.fn __POS__ __FUNCTION__` wrapper pervasive at
function boundaries with `~error_pp`/`~kind` rare, or evidence that the
boilerplate suppresses function spans. The full implementation, expansion
corpus, and error-location corpus (rated 4–5; kill gate unfired) sit on the
kept branch — promotion becomes a merge when the trigger fires. Evidence:
`.scratch/research/dx/e10/` (on branch), V-DX-E10-001..002.

Frequency lesson adopted as protocol (V-DX-AMEND-2): Eta is a library —
frequency evidence counts **user-shaped code** (`examples/`, docs-taught
patterns), not Eta's own internal cross-package or test usage.

## E2 — `discard` / `ignore_errors` (promoted 2026-07-18)

`Effect.ignore` — the most misleading name in the surface, reading as
`Stdlib.ignore` while silently suppressing typed failures — is deleted.
Its two crushed-together meanings are now honest: `discard` (drop the
success value; *all* causes propagate) and `ignore_errors` (suppress typed
failures, named exactly for what it does, generalized beyond unit). The
swallowed-error bug now requires writing `ignore_errors` in plain sight.
Evidence: blind review rated the old name **1** and the split **5**.
Provenance: `.scratch/research/dx/e2/`, V-DX-E2-001..002.

## E1 — `sync_result` (promoted 2026-07-18); `sync_option` (promoted 2026-07-20)

The library's hottest leaf — a synchronous call returning `result`, written
81 times as `sync f |> flatten_result` — is now one word: `sync_result`.
The mli states the contract in one sentence: "`Ok x` succeeds, `Error e` is
a typed failure, and ordinary exceptions remain unchecked defects; it does
not catch exceptions into the typed channel."

The path here matters more than the name. A first review pass flagged the
name as misread-inviting and the pre-registered kill gate fired; the
fallback `attempt_result` tested decisively *worse* (it actively teaches
exception-catching, rated 2). An oracle consultation ruled the review
cohort incomplete and the endpoint mis-measured; the completed three-pass
cohort produced **0/3 wrong exception-routings**, median 4, and a 5 for the
final pass, whose reviewer used the signature's polymorphism as *proof*
that exceptions cannot enter `'err`. Lesson recorded: finish the cohort
before evaluating a gate, and "flagged ambiguity" is not "wrong
expectation".

`sync_option` was first killed on internal-usage evidence (`from_option` ×7,
sync+option leaf pattern 0), then promoted by human decision authority
(V-DX-E1-003) under the user-first amendment: the construct family is the
symmetric 2×2 `from_result`/`from_option` × `sync_result`/`sync_option`, and
zero internal call sites is weak evidence against a public boundary. The
thunk counterpart is `sync_option ~if_none`: `Some` succeeds, `None` is the
typed `if_none` failure, raises stay defects.

## E4 — Cause rendering (promoted 2026-07-19)

`Cause.pp_compact` renders any cause as **one truthful line** for span
statuses and log fields: `fail(A) + die(Failure("boom")) | suppressed:
finalizer(fail("cleanup failed") ; interrupt)`. A 10-case snapshot corpus
locks both `pretty` and `pp_compact` forms (rendering drift now fails CI),
backed by a ~380-cause newline-freedom property. `Eta_otel.Cause_json`
gives sinks structured encoding over `Cause.Portable.t`; core stays
JSON-free.

The notable event: the review board **fired the pre-registered kill gate**
— the first compact notation (`p | suppressed: f`) never said the right
side ran in a *finalizer*. One rework round wrapped the suppressed segment
in the existing `finalizer(...)` vocabulary; the double re-review
(continuity board + cold reviewer) then passed it twice. The gate did its
job: the shipped one-liner preserves the primary/finalizer distinction
provably, not by assertion.

## E5 — Type errors, translated (promoted 2026-07-19)

`test/type_errors/` is the repo's first negative-compile snapshot corpus
(10 cases: rank-2 supervisor escapes, PPX rejections), drift-gated by
`dune runtest` (orchestrator-verified by breaking it). `docs/type-errors.md`
translates the 8 most common messages — each quoted **verbatim** from its
snapshot — into what-you-tried / why-Eta-forbids / two canonical fixes.

Archaeology findings that outlive the experiment: supervisor escape
messages never say "escape" (always `less general than 's.`); **resource
and pool handles compile when escaped** (no fence exists — documented
trap); **cross-domain Channel blocking ops hang silently** (exit 124;
same-domain runtime fence is now the top backlog item); two PPX rejection
paths are unreachable dead code.

Provenance: `.scratch/research/dx/e4/`, `.scratch/research/dx/e5/`,
V-DX-E4-001..002, V-DX-E5-001..002, branch
`research/dx-e4e5-cause-corpus-type-errors`.

## E3 — `race_either` (killed 2026-07-18)

The programme's first full kill. Heterogeneous races do not need a new
combinator: map-wrapping branches into **domain-tagged variants**
(`` `Timeout ``/`` `Done ``) beat `` `Left``/`` `Right `` tags in blind
review (5 vs 4 — "explicit tags eliminate positional reasoning"). The
recipe is the recommendation; the library stays one val smaller. Evidence:
`.scratch/research/dx/e3/`, V-DX-E3-001..002, branch provenance.

## E25 — Family consistency (promoted 2026-07-18)

The last three naming inconsistencies of the idiom pass are gone:
`scoped` → `with_scope` (the lifecycle family is uniformly `with_*`),
`named_kind` absorbed into `named ?kind ?error_pp` (one span verb; optional
erasure compile-proven), `now` → `now_ms` (units in the name), and
`with_error_renderer` / `?error_renderer` → `with_error_pp` / `?error_pp`
— telemetry now eats OCaml's `Format` culture (`pp` functions,
`[@@deriving show]`) instead of demanding `Format.asprintf "%a" pp_err`
adapters per module.

Two contract points worth remembering: `error_pp` renders **at most once**
per span status/exception event (memoized), and a raising printer becomes
a **defect** through the ordinary capture path — the silent
`"<error renderer raised>"` fallback is deleted. Telemetry degrades loudly,
or not at all. The `"<typed failure>"` default is unchanged by design; E7's
deriver is what will make it rare.

Evidence: golden tests (domain string in span status, render-once counter,
raising→defect, omission erasure); independent review 4,4 vs 3,4 with the
new side preferred on the Format-composition argument. Provenance:
`.scratch/research/dx/e25/`, V-DX-E25-001..002, branch
`research/dx-e25-family-consistency`.

## E24 — Iteration mirrors `List` (promoted 2026-07-18)

`map_par ?max_concurrent f xs` absorbs `for_each_par` and
`for_each_par_bounded` (both deleted): function-first like `List.map` and
`Effect.map`, results in input order, fail-fast, and a **documented default
cap of 8** — what used to be a hidden `min n 8` is now an explicit, tested
contract. `retry`, `retry_or_else`, and `repeat` are labeled and data-last
(`eff |> retry ~schedule ~while_`).

Two findings changed the plan en route, and are the real conclusions:

1. **The proposed signatures were unwritable in OCaml** — trailing optional
   arguments cannot be erased (`map_par ids ~f` would return a partial
   application, not an effect). Caught by the executor with a reproducible
   probe before any code was written; fixed by putting optionals before a
   trailing mandatory argument.
2. **Absorbing `retry_or_else` into `retry` was a misdiagnosis.** Its
   two-error form (`'err1 → 'err2`) is genuine typed-error expressiveness
   that `map_error` cannot recover (the schedule would see the wrong error
   type; the fallback would lose the schedule output). The two operations
   also already differ in cause semantics (`retry`: bare `Cause.Fail` only;
   `retry_or_else`: composite causes) — now documented in the mli as a
   *current limitation*, with alignment deferred to a registered decision.

`Schedule.t` slimming is **held**: `Resource.auto` and `Eta_stream` (×4)
publicly drive hook-bearing schedules, and `Schedule.step_plan` is public —
so hook ownership (policy vs. driver) is an architectural question, not a
rename. Registered as experiment **E24b** with "keep hooks permanently" as
a live outcome.

Evidence: parity suite incl. default-cap-8 proven with 9 inputs;
construction-time `Invalid_argument` red-team; independent review rated the
new shapes 5 and 4 against 3 and 3 for the old. Provenance:
`.scratch/research/dx/e24/`, V-DX-E24-001..004, branch
`research/dx-e24-iteration-mirrors-list`.

## E9b — Honest `and*`: sequential everywhere (promoted 2026-07-19)

After E9's hold proved that module-switched `open`s carry no semantics, the
human picked the least-astonishment design: `and*`/`and+` are now a strict
left-to-right product — nothing is forked, left failure skips right — and
concurrency is spelled `Effect.par` at the exact call site.

The safety argument is the point: under the old par-`and*`, misunderstanding
wrote a silent race (correctness bug); under the sequential `and*`, the
worst misunderstanding costs latency, never correctness. Red-team proof:
the order-sensitive transfer written with `and*` is observably sequential
(correct by construction); a would-be-concurrent `and*` program is
correct-but-serialized. Review: zero dangerous misreadings (0/6);
`Effect.par` reads as concurrent from the name alone. Census unchanged:
5 vals, 1 module — the smallest possible diff.

Provenance: `.scratch/research/dx/e9b/`, V-DX-E9B-001..002, branch
`research/dx-e9b-honest-and-star`. (Master push of this merge is pending a
master-green state — see the ladybug incident, V-DX-E9B-002.)

## E9 — `Syntax.Parallel`/`Applicative` split (held 2026-07-19)

The question: does splitting the always-open `and*` (concurrent,
sibling-cancelling) into explicitly-opened `Syntax.Parallel` and
`Syntax.Applicative` modules make concurrency *visible*? The implementation
is complete, lawful, and green on the branch — and **unmerged**, because
the measured answer is that the split's value was its visibility, and the
visibility measured zero.

Two independent fresh-context reviews (pre-registered scoring): baseline
form **2/6**, explicit form **2/6**, delta **0** — neither the promote gate
(explicit ≥ 80% and materially better) nor the kill gate (baseline ≥ 80%)
fired, so the pre-registered rule says hold. Three durable findings:

1. The footgun is real: cold readers cannot tell what `and*` does — both
   reviewers named the trap unprompted.
2. The proposed names carry no semantics either: "`Parallel` communicates
   concurrency but not cancellation"; "`Applicative` does not intuitively
   communicate 'ordered'."
3. The premise is contested: one reviewer would accept an `open` as a
   declaration of intent; the other argues semantics should not silently
   travel via re-orderable `open`s at all.

E9b hypothesis registered (naming or distinct-operator shapes) with a
fresh sealed prediction required; no post-hoc retest of E9 shapes.
Provenance: `.scratch/research/dx/e9/`, V-DX-E9-001..002, branch
`research/dx-e9-syntax-parallel-applicative`.

## E8 — `[%eta.result "name" body]` leaf sugar (promoted 2026-07-19)

The named-leaf pattern — `Effect.fn __POS__ __FUNCTION__ (Effect.named "x"
(Effect.sync_result (fun () -> body)))`, four concepts for one intent — is
now one form: `[%eta.result "x" body]`. The expansion is exactly the
hand-written pattern (an independent reviewer confirmed they'd accept it as
a verbatim PR rewrite — the T4 bar for sugar). `[%eta.option]` was NOT
added at promotion time: sugar follows demonstrated frequency, not
symmetry, and the option leaf had no call-site pressure then. E1 later
promoted `sync_option` itself (V-DX-E1-003); option sugar remains a separate
adoption question.

Adoption followed a stated rule (IO/trust-boundary leaves with static
names; no special kwargs): 12 example sites converted, 14 deliberately not
(each with a recorded reason — `~error_pp`, dynamic names, lifecycle
plumbing, pedagogy). Converted sites gained spans they didn't have — a
deliberate telemetry upgrade. Red-team: raising bodies still surface as
`Cause.Die` with spans; nested naming is noisy-but-harmless and documented.

Provenance: `.scratch/research/dx/e8/`, V-DX-E8-001..002, branch
`research/dx-e8-eta-result-sugar`.

## E23 — Error channel mirrors `Result` (promoted 2026-07-18)

The handle cluster now mirrors `Stdlib.Result`: `bind_error` (was `catch`),
`fold ~ok ~error` (replaces `recover` and `or_else_succeed`), and
`to_result` / `to_option` / `to_exit` (were the bare nouns `result` /
`option` / `exit`). `catch_some` and `or_else` kept. Handle cluster: 11 vals
→ 10, 10 concepts → 8.

Why, in one sentence: OCaml already owns this mental model — `Result` has
`map`/`map_error` and `bind`/`bind_error` — so the whole error channel
became teachable as "`Effect` is `Result` with concurrency and spans".

Evidence: blind review (fresh-context reviewer, OCaml-native persona) rated
the new naming 4,4,4 against 3,3,1 for the old, and produced the old API's
invited bug on demand ("`catch` strongly suggests `try ... with`"). The
`to_*` prefix was validated from names alone. Red-team probe: `bind_error`
cannot swallow exceptions — defects surface as `Cause.Die`.

Accepted tradeoff: pure recovery-only sites are noisier (`fold ~ok:Fun.id`
where `recover f` used to do) — flagged by both the executor and the blind
reviewer. Accepted deliberately: one both-channel fold beats two extra
near-duplicate combinators. If usage data shows the pattern is hot, revisit
with evidence (follow-up F2 in the journal).

Provenance: `.scratch/research/dx/e23/` (executor journal, report, red-team,
review packet), journal entries V-DX-E23-001/002, branch
`research/dx-e23-result-error-channel`.

## E6 — Parallel resource acquisition: recipe yes, helpers no (2026-07-19)

The nested `with_resource` ladder stays the default for bootstrapping a few
resources — its lifecycle semantics are *structurally visible*: nesting is
sequencing, scope exit is cleanup. For acquisition concurrency, the docs now
carry a recipe (`with_scope` + `acquire_release` + a bridge that registers
each completed acquisition in the owner scope), backed by regression tests.

The proposed `Effect.Scoped.with_2`/`with_3` helpers were **killed by their
pre-registered gate**: three independent reviewers rated them 3/3/3 against
the ladder's 5/5/4. The diagnosis was identical each time and is the
experiment's durable finding:

> **Helper names must carry execution strategy, not just cardinality.**
> From `with_3`'s call site you cannot tell acquisition is concurrent, and
> release order hangs on interpreting ordinal labels. A combinator's
> semantics live in its docs; a ladder's semantics live in its structure.

Also settled: `and@` remains killed (CPS composition demonstrably
serializes; syntax machinery would not fix semantic invisibility). And a
runtime fact worth knowing: `par` children own local finalizer scopes, so
naive `map_par (acquire_release …)` drains releases early — the recipe's
bridge is *necessary*, not ceremony. It is documented and tested.

Provenance: `.scratch/research/dx/e6/`, V-DX-E6-001/002, branch
`research/dx-e6-scoped-with-helpers` (helpers' `feat` + `revert` both
preserved in branch history).

---

## Phase B synthesis (2026-07-19)

Phase B is complete: E1 (`sync_result` promoted 2026-07-18; `sync_option`
promoted 2026-07-20 by human decision authority after an earlier
usage-only kill), E2 (`discard`/`ignore_errors` promoted; `ignore`
rated 1 and deleted), E3 (`race_either` killed — named domain tags beat
positional either-tags), E4 (`Cause.pp_compact` + rendering corpus +
`Eta_otel.Cause_json` promoted after a kill-gate fire and one rework round),
E5 (negative compile tests + "Eta type errors, translated" promoted), E6
(above). One CHANGELOG entry ("idiom pass") covers the breaking renames.

The phase's record against rubber-stamping: two clean kills, one helper
kill, one gate-fire-then-rework, and one provisional gate *overturned* by
completing the review cohort (E1). Pre-registered gates overruled both
executor and orchestrator priors — E6's gate fired against both predictions.

Laws the phase produced:

1. **Complete the cohort before evaluating a gate** (≥3 comparable
   passes). Born from E1's near-miss.
2. **Named domain tags beat positional either-tags** (E3).
3. **Helper names must carry execution strategy, not just cardinality**
   (E6). Now a standing review criterion.
4. **Telemetry text is user-facing API** — `pp_compact` lost the finalizer
   role label in exactly the composite cases where it matters most;
   notation is semantics (E4).
5. **Internal usage is weak public-API evidence** — the first E1 kill of
   `sync_option` rested on zero internal call sites; V-DX-E1-003 later
   promoted the family-complete boundary under the user-first amendment.

## E7 — Error-renderer deriver (promoted 2026-07-19)

`[@@deriving eta_error]` (in `ppx_eta`) generates `pp_err` for closed
polymorphic-variant error types — a plain match you would approve in
review, nothing more. Built-in payloads (`string`/`int`/`int64`/`float`/
`bool`); anything else is a **PPX-time error with a what/where/what-next
message** unless the tag carries `[@eta.render f]`. No placeholders —
placeholders are how `"<typed failure>"` reproduced.

Wiring stays explicit (T9): `Effect.named ~error_pp:pp_err "db.save"` or
one `Effect.with_error_pp pp_err` per module subtree. Nothing is inferred
or automatic.

Why it matters: the default telemetry for typed failures was the literal
string `"<typed failure>"` — a DX bug (T6). After E25's `?error_pp` socket,
the remaining gap was that nobody hand-writes `pp` functions. Now the
meaningful default is the path of least resistance: golden test shows the
same failure rendering `<typed failure>` → `db:7` through the real tracer.
Renaming a tag changes telemetry — documented as honest, not hidden.

Evidence: error board rated before 2 / after 4, expansions 5,5
("approve verbatim"), comprehension 4/4 cold. 54 example declarations
migrated; zero hand-written telemetry printers remain. Provenance:
`.scratch/research/dx/e7/`, V-DX-E7-001..002, branch
`research/dx-e7-error-pp-deriver`.

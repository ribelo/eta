# Eta DX research — conclusions

Curated, durable conclusions of the DX-PRD-0001 programme. For the
complete programme map (what / rationale / decision / decision rationale
for every experiment, kill, hold, and queued item), see
`docs/research/dx-ledger.md`. Curated, durable conclusions of the
DX-PRD-0001 programme
(`.scratch/research/dx-prd-0001.md`). This document exists so that a year
from now anyone can answer "why is the API shaped like this?" without living
memory. Protocol records (predictions, gates, ratings, decisions) live in
`.scratch/research/dx-journal.md`; per-experiment evidence lives on the
`research/dx-e*` branches.

Guiding star: *`Effect` is `Result` with concurrency and spans — `map`/
`map_error` on values, `bind`/`bind_error` on sequences, `fold` on both
channels.* Every conclusion here is judged by whether it moved Eta toward
that sentence.

**Status:** Phases A–D complete (A: 3 promoted · B: 4 promoted, 2 killed ·
C: 3 promoted, 2 held · D: 7 promoted, 2 scoped kills, 1 hold-then-redesign).

## Phase D synthesis (2026-07-22)

The runtime & model phase delivered the scoped-semantics substrate and the
two substrate-bridging leaves. Its durable laws:

1. **Cost contracts are measured, never asserted** — E20's
   allocation-free fast path was unimplementable as written; the watchlist
   caught it, `Keep|Drop|Replace` made it true by construction, and a
   control measurement showed the residual is the shared scoped-stage
   machinery, not the transform.
2. **Honest boundaries beat total claims** — E12's audit API states where
   static preflight dies (dynamic continuations); E11's printer says
   "unavailable" instead of faking a journal. A stated boundary is a
   feature.
3. **A scoped-semantics substrate is only as good as its fences** — E19
   proved fiber-local override semantics; the retro found the Expert
   bypass; E19b closed it with call-time selectors.
4. **Two-substrate contracts converge on shared mechanisms** — E13/E14
   shipped one implementation each over `Runtime_contract`, no backend
   branches, no polyfills.
5. **Small surfaces with hard guarantees** — E14: 3 vals, 17-line mli,
   zero rework rounds. Complexity lives in the runtime, not the API.

Full evidence: V-DX-PHASE-D in the journal.

## E24b/E24c — Schedule-hook ownership closed by deletion (2026-07-23)

The question Phase A opened — is `Schedule.t`'s third parameter
load-bearing or the library's ugliest public type? — is decided, and the
answer flipped twice on evidence. Architecturally, policy-owned hooks are
correct *while they exist* (policy places hook values, drivers interpret
them through the suspended step; branch-local composition events prove
it). But zero production code constructs a tap, the common observation
case has a better ordinary recipe (instrument the source — it even sees
the initial attempt taps miss), and the unique structural capability has
no demonstrated demand. **E24c implemented the deletion**: `Schedule.t` and
its driver now have two parameters, every schedule uses direct stepping, and
the tap constructors, suspended-step protocol, and `no_hook` marker are gone.
The decision keeps an honest loss statement (all schedule-local effect boundaries) and a
falsifiable reversal gate: a shipped non-test producer, external adoption
needing schedule-local effects, or an integration the ordinary recipe
can't express.

The durable lesson: a decision experiment's hypothesis space must include
"delete the feature" — the first verdict ("retain permanently") survived
one review round and still fell to the baseline that was never written
down. Provenance: `.scratch/research/dx/e24b/`, V-DX-E24B-001..002, branch
`research/dx-e24b-hook-ownership`; implementation packet:
`.scratch/research/dx/e24c/review/` on
`research/dx-e24c-hook-deletion`.

## E22 — Law-property policy (promoted 2026-07-23)

**Every law in an mli has a test** is now repository policy with teeth:
AGENTS.md defines law-bearing prose precisely, requires same-change
coverage for any new or changed mli law (no debt escape hatch), and lists
the anti-vacuity shapes. The census (`LAWS.md`) is honest: five
inventory-complete modules — 99 direct claims × 63 qcheck properties, 101
registered external-suite rows (verified real), 23 dated-debt rows,
nothing open-ended. `effect.mli` now states its algebraic equations
(scoped, observable-equivalence wording).

The durable lesson is the review arc: three oracle rounds — INCORRECT
(census provenance unsound, a vacuous schedule property, four more) →
INCORRECT (policy-vs-debt inconsistency, three weaker-cousin properties) →
CORRECT-WITH-RESERVATIONS. The first delivery was unrecognizably weaker
than what promoted. A test suite's claims need the same adversarial
scrutiny as code — vacuous properties are worse than missing ones because
they fake the model's safety net.

Provenance: `.scratch/research/dx/e22/`, V-DX-E22-001..002, branch
`research/dx-e22-law-properties`.

## E12 — `Effect.audit` / `Effect.describe` (promoted 2026-07-21; manifest role killed)

The blueprint is now inspectable: `audit` reports names + six capability
flags (clock/logs/metrics/concurrency/resources/background), `describe`
prints the static tree with `<bind …>` for unforced continuations, and
seven `Eta_test` assertions make the docs' vocabulary executable
(`assert_no_clock`, `assert_pure_eff`, …). The honesty boundary is the
design: flags cover the **visible static spine plus declared library
leaves** — an opaque `bind` lambda is invisible, by docs and by an
executable red-team attack. A teaching review preferred the real
`describe` output over prose 5–4 for exactly that caveat.

The examples-manifest role was **killed by its own evidence**: the
54-example golden showed mechanically-correct-but-humanly-misleading
flags (`cli_business` all-false despite retry behavior; channel/queue
probes reporting no concurrency). Static preflight dies at dynamic
continuations — and that finding is now E17's entry-gate data, preserved
in `.scratch/research/dx/e12/manifest/`.

Provenance: `.scratch/research/dx/e12/` (on branch), V-DX-E12-001..002a,
branch `research/dx-e12-audit-describe`.

## E20 — `intercept_log` / `intercept_metric` (promoted 2026-07-21, as E20b)

polysemy's `intercept`, in Eta's idiom: fiber-local transforms over log
records and metric points — `Keep | Drop | Replace` — sitting in the
E19-documented pipeline: min-level filter → attributes → intercept
(outermost-to-innermost) → sink. `annotate_logs` and
`with_minimum_log_level` stay as the friendly special cases with exact
parity. Redaction and tenant-enrichment become scoped *mechanisms*, not
discipline: a deeper `with_logger` can no longer accidentally bypass the
policy (the old wrapper-sink style's invited bug, found blind in review).

Two findings shaped the outcome: (1) the `option` representation made the
"allocation-free identity" contract unfulfillable — the executor
self-rejected on measurement, and the variant representation fixed it
(`Keep` ≡ `Replace` in cost); (2) the residual active-scope cost (~10.5
minor words/record) turned out to be the shared fiber-local machinery —
a control measurement showed an active `annotate_logs` scope costs
*identically*. Zero cost when no interceptor is installed; when installed,
the same price as any scoped stage. The deep follow-up (allocation-free
lookup) is registered as F7 and benefits all scoped stages.

Provenance: `.scratch/research/dx/e20/` (on branch), V-DX-E20-001..002,
V-DX-E20B-001..002, branch `research/dx-e20-intercept`.

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

`Schedule.t` slimming was held here for the ownership experiment because
`Resource.auto` and `Eta_stream` (×4) drove hook-bearing schedules and
`Schedule.step_plan` was public. E24b later selected deletion after finding no
shipped tap producers, and E24c implemented the two-parameter schedule and
direct driver described above.

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

## E30 — `Eta_js.from_js_promise` (promoted 2026-07-24)

One word for the jsoo track's most common interop shape:
`from_js_promise ?on_cancel ~on_reject promise` awaits a host JS promise
over `Effect.async`, inheriting its contract wholesale.

The durable lessons are about *where user code runs*:

1. **Never run user callbacks in host context.** The first implementation
   mapped rejections inside the JS callback: a raising mapper escaped the
   runtime, stranded the effect, and produced an unhandled host rejection.
   The shipped shape transports raw settlement (`Fulfilled`/`Rejected`)
   through `Effect.async` and maps inside Eta — a raising mapper becomes
   `Cause.Die` via the ordinary capture path, and no user code runs after
   interruption detaches the waiter.
2. **Evidence beats sealed predictions.** Three orchestrator predictions
   died on contact: js_of_ocaml has no `Js.Promise` binding (input is
   `Js.Unsafe.any`); a live AbortController consumer justified
   `?on_cancel`; non-thenable is a forged-boundary defect, not a typed
   failure. Each override came with in-repo evidence, not preference.
3. **Library dependency ≠ package dependency.** Migrating `eta_http_js`
   onto the adapter updated `lib/http_js/dune` but initially not
   `dune-project`/`.opam`/`flake.nix`; the isolated `-p` build caught it.
   Mainline packages need the isolated-package gate.

Provenance: `.scratch/research/dx/e30/`, V-DX-E30-001/002, branch
`research/dx-e30-from-js-promise`, law rows R116–R126.

## E28 — Unified admission for `all` (promoted 2026-07-25)

`Effect.all` and `Effect.map_par` now share one admission policy
(`?max_concurrent`, default 8). The durable lessons:

1. **"Unbounded by design" was an inherited accident.** History gave no
   deliberate contract for `all`'s fork-per-effect fan-out — the perf
   commit capped only the mapper. When a safety property is accidental,
   uniformity beats archaeology.
2. **The traverse spelling is irresistible.** `all (List.map f xs)` is
   what users naturally write — production code did. A safety boundary
   that one eta-expansion bypasses is no boundary; admission had to be
   unified in the engine, not in the docs.
3. **`all`'s real differentiator is introspection.** Prebuilt children
   give static names and capability footprints; `map_par`'s mapper must
   never be forced at blueprint time. That — not scheduling — is why
   both names exist.
4. **Hazard warnings must be precisely true and provably registered.**
   "A child waiting on an unadmitted sibling deadlocks" was false as an
   absolute; the shipped form names the all-admitted-workers-blocked
   condition, with a bounded-barrier test that makes non-progress and
   clean teardown observable.

Provenance: `.scratch/research/dx/e28/`, V-DX-E28-001..003, branch
`research/dx-e28-all-vs-map-par`, law rows M114–M118, R127–R130.

## E29 — `par3`/`par4`: flat concurrent products (promoted 2026-07-26)

E9b made concurrency explicit, so 3–4-way concurrent fetches are the
common consumer shape — and nested `par` was never a design, just the
accident of a binary API. `Effect.par3`/`Effect.par4` collect flat
tuples in argument order with `par`'s fail-fast semantics; arity caps at
four with an explicit beyond-four rule.

Durable lessons:

1. **Frequency gates have a consumption-model exception.** In-repo
   frequency was ≈ 0 — and irrelevant: the consumers who feel the pain
   are downstream, and E9b's explicit-concurrency decision structurally
   forces this shape onto them. The structural need must be *argued and
   examined*, not waved through — but absence of in-repo use cannot
   answer it (V-DX-PRINC-1's first application).
2. **"Only ergonomics" can be enough** when the additions are
   predictable members of an existing family — they shrink call-site
   cognitive surface more than they grow API surface. The E6 criterion
   is the guardrail: the name must carry the execution strategy
   (`par3` does; `with_2` didn't).
3. **Registry discipline is per-row arithmetic, not vibes.** Three
   mechanical pre-merge fixes were all about the executable-law
   registry: totals that match the rows, properties that enumerate every
   documented branch deterministically, and audit tests that
   discriminate every child position.

## E31 / E10 — Function-level trace sugar: killed by evidence (2026-07-26)

E10 (`let%eta` / `[@@eta.trace]`) was held pending its trigger: "promote
only if reviewers still ask for it after E7/E8." E31 measured the answer:
4 remaining `Effect.fn __POS__ __FUNCTION__` sites, all framework-test
value bindings, **zero sugar-eligible, zero consumer-shaped**; a
16-experiment forcing-function analysis showing nothing promoted since
E10 makes definition-level sugar more needed — and E8's `[%eta.result]`
actively absorbing the boilerplate that motivated it. The cohort, shown
only the neutral material (never that a tested implementation existed),
answered NO-FIRE.

The durable lessons:

1. **Questions must close.** "Hold by default" is a decision to revisit
   with a measuring stick, not a shelf. E10's trigger was pre-registered;
   E31 was the scheduled measurement; the kill is the system working.
2. **Sunk cost must be invisible to the deciding review.** E10's
   implementation was complete and proven — and that fact was withheld
   from the cohort, because "it's already built" is not demand. The
   verdict came back clean in nine seconds.
3. **Eligibility matters more than counts.** "4 sites" sounds like
   demand until you look: all four are value bindings the sugar
   structurally cannot serve. Measure the shape, not the grep count.

## E32 — The `recover` recheck: verdict holds (2026-07-26)

F2's scheduled re-measure: 24 genuine `fold ~ok:Fun.id ~error:f` sites
(11 consumer-shaped, most in `examples/`). Frequency alone would have
earned the shorthand. What killed it was the name: two independent
reviews found `recover` alone invites the exception-recovery reading —
the contract corrects it, but a new name in this library must teach
correctly from the name alone (T3/T11). `bind_error` passes that bar
cold; `recover` fails it in both readings, because OCaml's dominant
recovery idiom is exception-catching.

Durable lessons:

1. **"The contract corrects it" is not good enough for a name.**
   Correct-at-selection is the floor; correct-from-the-name is the bar.
   The noise (`~ok:Fun.id` at 24 sites) is the accepted price of never
   needing a second look.
2. **Watch items close with evidence, either way.** F2 was a real
   possibility (R3 sanctions evidence reverts); the recheck was a real
   measurement; the outcome stands on two independent reviews, not on
   E23's sunk verdict.
3. **Progressive disclosure requires channel-honest shorthands.**
   E20's friendly special cases carry the channel in the name
   (`annotate_logs`); a special case whose name drops the channel is
   not disclosure, it's camouflage.

## E16 — The no-`R` boundary, now with evidence (killed 2026-07-26)

The `Reader` rival was built in its strongest form (~50-line optional
module, `ask`/`local`/`map`/`bind`) and raced against value-passing on a
real service. Value-passing won 4-0-1: fewer lines at real service
depths, materially more local compiler errors (names the wrong field,
not an incompatible whole record), less plumbing per added dependency,
and a 5-vs-3 comprehension gap (implicit env function, two `Reader.run`
boundaries, accessor-vs-local shadowing).

The durable lessons:

1. **The boundary holds — and its breaking condition is now documented.**
   Both the builder and the reviewer independently said Reader's case
   strengthens with deeper graphs (~6+ dependencies threaded across
   layers). If Eta's consumers report parameter-threading pain at that
   depth, E16's race is the reopening evidence — until then, no `R`.
2. **A fair race needs a strong rival.** The Reader port used its
   strongest form (parameter-free `program`, real `local` substitution)
   and still lost; the kill is evidence, not a strawman. Its one real
   win — a dependency-stable `program` signature — is on record as the
   legitimate cost of value-passing.
3. **Error locality is a design criterion.** The compiler naming
   `bad.clock` with its expected type beat "whole record incompatible"
   — the clearest single data point of the race, and it belongs in the
   model doc's no-`R` rationale.

## The environment question, settled (2026-07-26)

Why does Eta have no `R` channel, no `Layer`, no `provide`? Because each
alternative was built, measured, and found worse — twice over: once in
the project's own survival labs (2026-05) and once in an independent
compiler-lab evaluation adopted 2026-07-26
(`.scratch/research/envless-verdict-2026-07-26.md`).

Four independent evidence lines, two individually decisive:

1. **OxCaml portability (decisive).** Object-row environments are
   non-portable across domain boundaries; the shipped env parameter was
   removed for exactly this reason (`7417b03b`, V-Recovery-R2). An
   object-row R either kills the islands/portable direction — Eta's
   most distinctive engineering bet — or forces two effect types.
2. **Survival-tested pillars.** `provide` deleted (identical behavior,
   shorter without); restricted Layer merge "not materially better";
   2295-byte missing-capability row errors at 20 modules vs. 689 for
   arguments.
3. **The value restriction is structural.** Env-reading constructors
   force non-covariance → weak type variables → mandatory thunks →
   Layer values can't cross compilation units → memoisation-by-identity
   dies.
4. **Cross-library object-row keys are unsound** — global names, silent
   collisions, rename-is-breaking.

Plus the DX programme's own race (V-DX-E16): `Reader` vs. value-passing
on one real service went 4-0-1, with the boundary condition recorded
(deep graphs, ~6+ deps across layers).

The one genuine R win — deep leaf evolution touches 1 file instead of
~4 — is absorbed locally by composite subsystem records
(`docs/services.md`). Reopen conditions are measurable (verdict §7):
real-application churn after composite records; OxCaml portable
objects; a real cross-library ecosystem; a provide-forcing fixture; a
service-graph forcing case; language-level VR relief. Until one fires:
`('a, 'err) Effect.t`, ordinary dependencies, runtime-owned services,
no R, no Layer, no provide.

## E35 — Stack safety: established by measurement (2026-07-26)

The EOP audit's deepest technical worry ("no hard stack-safety
guarantee") is answered: the recursive interpreter (no trampoline) is
absorbed by both substrates — OCaml 5's heap-grown fiber stacks (1 GiB
default `stack_limit`) natively and in bytecode, and js_of_ocaml's
`--effects=cps` trampoline under Node. Every boundary case passes at 1M
(and 3M–10M beyond). No interpreter rewrite; the guarantee is pinned by
full-1M regression tests on all three substrates with strong semantic
checks.

Durable lessons:

1. **Measure before rewriting.** Both predictors (orchestrator and
   executor) sealed "this will blow the stack" and were wrong — the
   mistake was confusing the 8 MiB OS C stack with OCaml 5's heap-grown
   fiber stacks, and not knowing the jsoo CPS trampoline exists. A
   trampoline would have been built on a false mental model.
2. **State guarantees with their boundary.** The honest form is "1M
   under documented default configurations" — configuration-dependent
   (`OCAMLRUNPARAM` reopens it), substrate-mediated, not intrinsic.
   That is stronger than an unexamined absolute and cheaper than an
   unneeded rewrite.
3. **Calibration controls make depth claims credible.** A passing deep
   test proves nothing unless something nearby dies on cue: plain JS
   recursion dies at 12,513 frames on the same Node; raw non-tail
   OCaml-under-jsoo dies at 10k. The deaths validate the passes.

## E36 — Background failure semantics: structured lifetime AND structured failure (2026-07-27)

`with_background` is now fail-fast: a dead protocol reader or heartbeat
cancels the body, runs its finalizers, and propagates its cause —
`par`-like, with races linearized by terminal-exit publication order
(the honest rule, because it's the only one `par` itself guarantees).
The old record-only behavior lives on, honestly named, as
`with_supervised_background`. The audit's §4.2 gap is closed: lifetime
AND failure are now both structured.

Durable lessons:

1. **"Unproven" is not "inexpressible" — but proving is the work.** The
   executor's BLOCKED correctly separated one spec over-reach
   (orchestrator's, amended) from two evidence gaps. Two were closed by
   tests; the priority rule was closed by discovering `par` never
   promised it either.
2. **Parity claims need shape-exact evidence.** The first
   "cleanup-parity proven" was false: the filter dropped the interrupt
   wrapper, the tests accepted both shapes, and the registry registered
   it anyway. The corrected rule is the design's own intent: filter
   only CLEAN internal cancellations; attach the complete loser cause
   otherwise. A probe comparing exact cause trees old-vs-new is the
   only acceptable evidence for such claims.
3. **The surprising semantics should carry the marked name.** Fail-fast
   is what `with_background` reads as; record-only is the marked
   variant. T2 applies to semantics, not just types.

## E37 — Parallel acquisition without Expert: `acquire_all_par` (2026-07-27)

The audit's §4.3 gap is closed: acquiring N resources in parallel with
correct cleanup no longer requires the runtime extension point.
`Effect.acquire_all_par` uses **transactional staging**: each
acquisition's release is armed in a staging scope before a cancellation
checkpoint; on success, a non-suspending batch commit moves the staged
finalizers into the owner scope. Any failure or interruption rolls back
completed acquisitions in reverse successful-acquisition order; late
completions are cleaned without transfer. The staging pattern (arm
rollback before the checkpoint; batch-commit on success) is now the
canonical answer for parallel acquisition.

Durable lessons:

1. **A correct mechanism and true evidence are different deliverables.**
   The review's concurrency audit found no leak, no double-release, a
   safe commit window, and correct ordering on the first pass — while
   the registry claimed branches the tests didn't exercise. The
   exact-span registry discipline, not the implementation, is what
   failed first.
2. **Correctness gaps outrank ergonomic verdicts.** E6 killed the
   parallel-acquire *syntax* (reviewers prefer the ladder); E37 shipped
   the parallel-acquire *ownership semantics*. Same task family,
   different question — the constraint held because the questions were
   never conflated.

## E38 — Finalizer diagnostics: the string dies, the value survives (2026-07-27)

`Cause.Finalizer.Fail` was the last place a typed error was flattened to
a string. Now it's `{ error; rendered }`: the value survives for whoever
holds its concrete type, and the rendered string — computed **once, at
conversion, inside the runtime capture path** — travels for display.
`Cause.Portable` keeps materializing strings, because that's its job.
E7-derived printers now render meaningfully in cleanup diagnostics
(`db:7`, not `<typed failure>`).

The deep lesson, and the reason the first shape died in review:

1. **Deferral is a semantics change, and the type won't tell you.**
   Moving the printer's invocation from capture-time to observation-time
   silently broke E25's contract ("a raising pp becomes a defect via the
   ordinary capture path") and gave stateful printers a reflexivity
   surface. The repaired design evaluates at the same moment as before
   and stores *more* — value AND rendered string. Evaluation timing is
   part of a contract even when it's invisible in the signature.
2. **Parity by construction beats parity by testing.** String equality
   on the stored `rendered` is the old world's semantics exactly — no
   new collision-limit paragraph, no new footgun, nothing for the
   equality tests to relearn.

## E39 — The audit-slim race: honesty deleted, the printable blueprint stays (2026-07-28)

The EOP audit called E12's introspection surface the library's strongest
removal candidate, and it was mostly right. What died: `Effect.audit`'s
capability flags (whose own docs admitted over/under-reporting), the
stored per-node footprints that fed them (`Custom` 4 → 2 fields), all
seven `Eta_test` audit assertions, `Expert.make`'s capability/names
metadata, `collect_names` with its 12 storage sites and an arbitrary
`all`-vs-`race` aggregation seam, and `all`'s introspection
special-casing. What survived: `describe` — the one honest, cost-free,
deterministically-printable view of a blueprint value, justified not by
consumer demand but by T5 ("the blueprint is a value: inspectable,
printable, auditable"). Its snapshot corpus is byte-identical before and
after.

The race built both endpoints (slim S, full-removal R) with measured
evidence, and the decision review synthesized a third endpoint better
than either: S′ = R + `describe`. Blueprint construction got 36.36%
cheaper in allocated words and 54.70% faster in median time on the
pre-registered workload — the footprint machinery had been taxing every
`preserve` wrap eight words. Dishonest capability declarations are now
unwritable by construction.

Lesson carried forward: when an API's own documentation apologizes for
its accuracy, the API is the problem. And when two things are bundled in
one proposal, check whether they share a cost and a justification —
`describe` and `collect_names` did not.

Provenance: `.scratch/research/dx/e39/`, V-DX-E39-001..003, branch
`research/dx-e39-audit-slim-race`, merge `203b8fbe`.

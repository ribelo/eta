# DX-E24b decision journal

## V-DX-E24B-001 — sealed predictions

**Recorded before reading `schedule.mli`, any driver implementation, E24/E13/E14
research, or hook tests in this worktree.** The assignment and repository rules
are the only design inputs at this point.

### Decision question

Should effectful schedule hooks remain values produced by schedule policy and
interpreted by drivers (candidate A), move to independent observer callbacks on
each driver (candidate B), or retain the suspended hook protocol while changing
the public seam/ergonomics (candidate C)?

### Proof obligations and expected matrix

| ID | Proof question | Predicted evidence | Risk |
| --- | --- | --- | --- |
| P1 | Does the full public protocol expose one coherent policy-value/driver-interpretation split? | `start`, `step_plan`, `step_with_hooks`, `step`, and `next` will show that hook values suspend advancement and drivers own execution/resumption. | High |
| P2 | Can a minimal driver-owned observer set preserve every semantic row? | B will express driver-local pre/post observation, but exact composition ordering and generic suspended interpretation will either require duplicating schedule semantics in each driver or retaining a generic hook protocol under another name. | High |
| P3 | Is A's third parameter justified outside tests? | Hook construction will be test-heavy, but at least retry, resource, stream, and public custom drivers will consume the same protocol; `no_hook` will keep ordinary construction simple while signatures remain visibly ternary. | Medium |
| P4 | Can C materially improve the 6+ threaded signatures without weakening the protocol? | A seam-centered helper may centralize interpretation or documentation, but OCaml's exposed hook type will still need to appear wherever a caller chooses/interprets hook values; ergonomic hiding will be partial rather than a true two-parameter schedule. | Medium |
| P5 | Is every law-bearing ownership/ordering claim registered to named executable coverage? | Existing tap tests will cover some pre/post/failure/ordering rows, but the E22 registry will reveal at least one missing registration or discriminating case. | High |

Expected semantics matrix:

- **A** should express pre-step, post-step including terminal `Done`, failure
  propagation/no-advance, composition ordering, and suspended resumption once in
  schedule policy plus the generic driver seam. Its cost is a third public type
  parameter threaded through tap-capable signatures and driver APIs.
- **B** should make simple driver-local observation pleasant and remove that
  type parameter from schedules, but it is expected to need different callback
  contracts for retry, resource, four stream operations, and public drivers.
  Unless observers reconstruct policy composition, it will not preserve exact
  ordering or reusable schedule-defined interception.
- **C** should preserve A's semantics and may reduce repeated interpretation or
  common no-hook annotations. It is expected not to eliminate the load-bearing
  hook type from genuinely hook-capable public boundaries.

### Steelmanned candidates before evidence

| Candidate | Strongest case | Evidence needed to win | Evidence that would falsify it | Initial status |
| --- | --- | --- | --- | --- |
| A — policy-owned hooks | One typed suspended protocol lets policy decide *which* effectful interception occurs while every driver decides *how* to run it. This can preserve composition semantics without callback APIs multiplying by driver. | Full inventory uses the common seam; executable tests establish all semantic rows; B/C do not match that coherence with a smaller complete surface. | Hooks are effectively test-only, public drivers do not need schedule-selected effects, or a smaller observer design preserves all rows without duplicated contracts/interpreters. | Favored, untested |
| B — driver-owned observers | Drivers already own effects, lifecycle, and domain vocabulary, so observers can be named at the point users understand (`on_retry`, `on_step`, stream-specific callbacks); schedules become simpler data/policy with two type parameters. | A minimal observer set demonstrates parity for pre/post/failure/order/suspension across every driver and public custom driving, with genuinely less public and implementation surface. | Any required semantic row becomes inexpressible, moves composition logic into every driver, or requires recreating the suspended hook seam. | Active, untested |
| C — seam-centered redesign | The ownership split may be right while the current type-level presentation is wrong; one interpreter combinator or a tap-free common surface could retain capability but remove most user-visible burden. | A concrete signature probe improves all or most threaded sites, keeps one semantics source, and preserves custom-driver use without unsafe erasure or a second protocol. | The third type remains at every meaningful boundary, generic interpretation already exists, or the redesign merely aliases/renames A without observable ergonomic gain. | Active, untested |

### Expected verdict

I predict **A will be accepted**, with ownership prose and E22 law registration
or focused test additions as the only production changes. I expect B to be
rejected or dominated because schedule composition determines interceptor
ordering before any particular driver exists. I expect C to be partial or
deferred: useful only if the inventory proves an unserved ergonomic seam rather
than a documentation problem.

This is a prediction, not a decision. Implementation cost or investigation
effort will not count against B or C; only user cost, maintained public surface,
semantic duplication, or failed behavior will.

### Evidence that would flip the prediction

- **Flip to B** if a fair minimal-observer probe preserves all six matrix rows,
  including tap failure/no advancement, composed ordering, terminal `Done`, and
  generic suspended custom driving, while deleting rather than renaming the
  common hook protocol and reducing total public contracts.
- **Flip to C** if a concrete seam design removes the hook parameter from the
  common signatures and at least the known six threaded call sites while still
  preserving typed hooks, one interpretation protocol, and complete custom
  driver guidance.
- **Reject A** if inventory shows no production need for schedule-selected hook
  values, if existing taps cannot enforce their claimed ordering/failure laws,
  or if their semantics intrinsically belong to a driver's lifecycle rather
  than schedule composition.

The favored A candidate must face a probe of B's strongest complete observer
set. B must get a fair parity probe, not a driver-specific toy. C must be judged
on a concrete signature delta, not on prose preference.

---

## Evidence record

### Question, obligations, and boundaries

The production decision is whether schedule policy continues to own typed hook
values and their structural placement, or whether each effectful driver owns
observer placement as well as execution. The success bar is complete parity for
pre-step, post-step including `Done`, failure/no-publication, composed ordering,
suspended custom interpretation, and the tap-free path.

Requirements: preserve every current semantic row; keep typed failure behavior;
cover the full public protocol and all drivers; obey E22 for changed mli laws.
External constraints: Nix-only verification, no compatibility layer, and no B/C
implementation in this experiment. Preference may break a tie in favor of a
smaller surface, but type behavior and runtime semantics decide first.

The main unknown was whether taps are merely top-level lifecycle observers. The
composition probe closes that question: they are structurally placed policy
interceptors. External adoption remains unknown because all in-repository tap
construction is test evidence, not production usage.

| ID | Proof question | Evidence | Risk | Result |
| --- | --- | --- | --- | --- |
| P1 | Is there one coherent policy-value/driver-interpretation protocol? | Full interface and implementation inventory | High | Proven |
| P2 | Can B's minimal pre/post observer pair preserve composition? | Executable `and_then` handoff trace | High | Contradicted |
| P3 | Does hook failure withhold state publication? | Direct `step_with_hooks` failure/retry probe and qcheck law | High | Proven |
| P4 | Can C hide the hook type while drivers retain interpretation? | Negative existential compile fixture plus positive bundled-interpreter fixture | Medium | Contradicted for the tested design |
| P5 | Is no-hook use mechanically pleasant and safe? | Positive inference and negative tapped-step compile fixtures | Medium | Proven |
| P6 | Is law-bearing ownership prose registered? | E22 census and focused `test/laws` gate | High | Proven; direct-interpreter debt closed |

### Complete inventory

#### Public protocol

| Entry | Source | Ownership and driving style |
| --- | --- | --- |
| `('input, 'output, 'hook) Schedule.t` | `lib/eta/schedule.mli:4-8` | Policy AST carries typed hook values and their placement. |
| `no_hook` | `schedule.mli:10-12` | Uninhabited marker proving that direct stepping cannot encounter a hook. |
| `tap_input` / `tap_output` | `schedule.mli:70-84`; `schedule.ml:32-37,76-77` | The only hook-producing constructors. `tap_input` wraps before the inner step; `tap_output` wraps after its output, including `Done`. |
| `start` / abstract `driver` | `schedule.mli:95-103`; `schedule.ml:608-619` | Converts policy to immutable driver state while retaining the hook type. |
| `step_plan` | `schedule.mli:112-116` (`step` is at 105-110); `schedule.ml:621-626` | Canonical general seam: returns `Complete` or one ordered `Hook (value, resume)` at a time. |
| `step_with_hooks` | `schedule.mli:118-125`; `schedule.ml:628-639` | Synchronously drains the plan with a caller-supplied interpreter. |
| `step` | `schedule.mli:127-133`; `schedule.ml:641-644` | Direct decision for statically `no_hook` drivers via the absurd interpreter. |
| `next` | `schedule.mli:135-142`; `schedule.ml:646-649` | `no_hook` convenience that keeps only `Continue` metadata. |

`schedule.ml:580-592` is the state boundary. Input taps expose a hook before
calling the inner step. Output taps compute a suspended inner result but expose
the new driver only after the output hook resumes. Drivers remain immutable, so
an interpreter failure returns no next driver; reuse of the original driver
repeats the same attempt.

#### Production consumers

| Driver family / public operations | Public signature | Interpreter style | Terminal behavior |
| --- | --- | --- | --- |
| Effect: `retry`, `retry_or_else`, `repeat` (3) | `lib/eta/effect.mli:413-450,490-501` | One `step_with_hooks` helper and current-frame `run_to_value` interpreter, `effect_schedule.ml:5-10`; used at lines 19-33, 45-60, 69-94 | Retry preserves/falls back from `Done`; repeat returns its output. Hook failure fails the driving effect. |
| `Resource.auto` (1) | `lib/eta/resource.mli:12-29` | Hand-drains `step_plan` with `Effect.bind`, `resource.ml:62-65,90-116` | `Done` ends the daemon. A hook failure fails the daemon rather than entering refresh-failure accounting. |
| Stream: `from_schedule`, `schedule`, `repeat`, `retry` (4) | `lib/stream/eta_stream.mli:40-45,114-137` | One shared hand-interpreter, `eta_stream.ml:268-278`, used by folds at lines 846-951 | Each operation deliberately handles `Done`: discard terminal output, stop before a value, stop repeating, or preserve the final stream error. Hook failure fails the stream effect. |
| HTTP retry entry points (2) | `lib/http/client/retry.mli:26,42` | `next` on explicit `no_hook`, `retry.ml:13,159-165` | Pure recurrence-delay consumer; no interpreter exists or is needed. |
| Public custom drivers | `schedule.mli:95-142` | May drain `step_plan`, call `step_with_hooks`, or use `step`/`next` when statically hook-free | Caller chooses effect system and lifecycle. |

There are **8 hook-accepting external operation signatures** (Effect 3 +
Resource 1 + Stream 4), **2 explicit no-hook HTTP signatures**, and **3
production interpretation helpers** serving 3 + 1 + 4 operations. No production
module constructs `tap_input` or `tap_output`. `lib/js/eta_js.ml/.mli:17`
re-export the complete Schedule module without adding another interpreter;
`runtime_core.ml:3` has an unused local alias only.

The reproducible pre-E24b call-site census is **12 tap constructor calls in 4
test files**, not the assignment's provisional “16 lines, 3 files”: E22 added
two qcheck call sites in a fourth file, and “lines” is not the same unit as
constructor calls. The baseline files are:

- `test/core_common/effect_retry_repeat_common_suites.ml`: 7 calls;
- `test/core_common/resource_common_suites.ml`: 1 call;
- `test/stream_common/stream_common_suites.ml`: 2 calls;
- `test/laws/law_properties.ml`: 2 calls.

The first file contains two taps on one schedule, hence 12 calls rather than 12
tests. The arithmetic is 7 + 1 + 2 + 2 = 12.

Post-E24b the new composition law deliberately adds six constructors in the
existing law file: **18 calls in the same 4 files**. `signature-census.sh` asserts
both pre- and post-change counts, preventing narrative drift.

#### Existing and added executable coverage

| Semantic claim | Named evidence |
| --- | --- |
| Pre-step and abandoned resumption preserve state | `Schedule.tap_input precedes each step and abandoned Hook retry preserves driver state` |
| Post-step includes terminal `Done` | `Schedule.tap_output runs after every produced output including terminal Done` |
| Effect runtime order/failure/defect/interruption | Effect suite registrations `schedule tap_*` at `effect_retry_repeat_common_suites.ml:1063-1074` |
| Resource current-runtime interpretation | `auto runs effectful schedule tap` |
| Stream input order and typed failure | `schedule throttles elements and taps inputs`; `schedule tap failure fails stream` |
| Structural order and direct interpreter publication | New `Schedule policy hook order survives and_then and step_with_hooks publishes only after interpreter success` |

`.scratch/research/dx/e22/review/LAWS.md` now has M95/M96, registers all named
driver evidence in R96, updates every shifted `schedule.mli` source span and
census total, and removes closed debt CD-E22-022.

### Semantics matrix

| Semantic row | A — policy-owned hooks | B — driver-owned observers | C — seam-centered redesign |
| --- | --- | --- | --- |
| Pre-step | `Tap_input` suspends before its inner policy; nested policies may produce multiple pre-hooks in one public step. | A top-level `before_step input` is easy, but one callback cannot observe branch/phase-local pre-steps during a handoff. | Preserved only if `step_plan` remains the canonical structural seam. |
| Post-step including `Done` | `Tap_output` observes every inner output, including hidden terminal branch outputs and outer `Done`. | A top-level `after_step output` can cover outer `Done` if all 8 drivers remember it, but cannot see an inner terminal output consumed by composition. | Preserved by draining the existing plan; no redesign evidence improves it. |
| Hook failure / no advancement | No next driver is exposed until all hooks return; failure through Effect/Resource/Stream follows the driver's typed/runtime channel. | Expressible if all 8 driver APIs promise delayed state publication around callbacks; a shared helper could centralize implementation, but every public contract must honor the rule. | Existing continuation seam preserves it. Existential hiding does not help. |
| Ordering under composition | Structural and deterministic. `both`/`either` drive left before right; `and_then` may expose left terminal and first right hooks in one step; wrapper nesting determines order. | **Cannot express full parity with top-level observers.** The probe sees 4 branch-local hooks versus 2 outer observations. A richer policy event stream recreates A. | The current design is already seam-centered and preserves the flattened order. |
| Suspended interpretation | `Hook (value, resume)` supports Eta and arbitrary custom interpreters; policy owns values, driver owns execution. | Removed from Schedule. Every custom driver needs another observer/effect contract; a generic replacement is a second suspended protocol. | A two-parameter existential cannot accept a driver-owned interpreter; bundling the interpreter compiles but moves interpretation into the package. |
| No-hook ergonomics | Ordinary constructors infer `no_hook` for `step`/`next`; tapped schedules are rejected statically. Explicit type annotations remain ternary. | Schedule annotations become binary, but 8 effectful operations acquire an observer label/contract (or 16 pre/post labels). | A hook-free alias could shorten 2 explicit HTTP signatures, but does not remove the independent hook/error type from the 8 effectful signatures. |

### Disconfirming probes

All artifacts are under `.scratch/research/dx/e24b/redteam/` and run with:

```text
.scratch/research/dx/e24b/redteam/run-all.sh
PASS
```

Results:

1. `policy_sequence.ml` gives B its strongest minimal generic observer — one
   callback before and one after the top-level step. One `and_then` phase handoff
   yields four policy hooks (left input/output, right input/output) but only two
   top-level observer events. This is semantic loss, not implementation cost.
2. The same probe fails `step_with_hooks` and retries the original driver at
   attempt one, disconfirming A's risk of premature state publication.
3. `signature-census.sh` quantifies A's visible cost and B's fair minimum: one
   shared pre/post observer type threaded through 8 APIs, or 16 callback labels.
4. `c_hide_hook_negative.ml` fails because the existential hook type escapes
   when the driver supplies an interpreter. `c_pack_interpreter_positive.ml`
   compiles only by packaging the interpreter with the schedule/driver, reversing
   the ownership split rather than improving it.
5. `no_hook_positive.ml` compiles and runs without annotations;
   `no_hook_negative.ml` is rejected as `unit` versus `Schedule.no_hook`.

The promoted qcheck law strengthens the scratch probe: every generated input
deterministically executes all six interpreter-failure positions while comparing
manually drained `step_plan`, successful `step_with_hooks`, and a retry from each
original driver. Its source comment states the one-step `and_then` observation
boundary and generated class.

### Hypothesis ledger and cross-tab

| Candidate | Strongest positive evidence | Strongest negative evidence | Proof rung | Final status |
| --- | --- | --- | --- | --- |
| A — retain policy-owned hooks | One protocol serves 8 operations, 3 implementation helpers, no-hook HTTP, and public custom drivers; exact composition/failure law passes. | No production tap construction; 3rd parameter is visible in every hook-capable annotation. | P3/P4 | **ACCEPTED** |
| B — per-driver observers | Binary schedule type; top-level lifecycle callbacks are locally obvious and fit driver-owned effects. | Cannot see branch/phase-local hooks; parity requires a policy event plan. Adds 8 observer contracts (or 16 callbacks). | P2/P3 | **REJECTED by failed semantic fixture** |
| C — redesign around seam | Correctly identifies the suspended seam as load-bearing; interpreter centralization is plausible. | That seam already exists. Existential hiding fails; bundling interpretation reverses ownership; no signature reduction across the 8 effectful operations was demonstrated. | P2 | **REJECTED as dominated by A** |

| Criterion | A | B | C |
| --- | --- | --- | --- |
| Static safety | Typed hook channel; `no_hook` proves absence | Simpler schedule arity, callback presence not reflected in schedule | Hidden hook blocks driver interpretation unless bundled |
| Structural composition | Full | Top-level only | Full only by retaining A's plan |
| Failure publication | One continuation protocol | Contract applies to all 8 APIs; implementation may be shared | Existing plan already solves it |
| Runtime ownership | Policy places values; driver executes | Driver places and executes observations | Bundled interpreter makes policy package execute |
| Public custom drivers | One documented protocol | Each defines callback contract | Existential cannot accept arbitrary interpreter |
| Public surface | 3-parameter `t` + 2 taps | 2-parameter `t` + at least 1 type and 8 labels | Alias/package/helper surface with no proven net reduction |
| Existing-boundary compatibility | Native | Rewrites all 8 operations and semantics | Current A is already compatible; tested redesign is not |
| Unresolved risk | Actual user adoption unknown | A deliberately narrowed top-level-only contract could be valid after breaking semantics | A materially different compiling prototype may exist |

### Independent red-team

The Oracle independently favored A at confidence 0.8. Its strongest objection is
the real YAGNI concern: all in-repository hook producers are tests, while users
pay a ternary type and public-driver protocol. It nevertheless found composition
decisive and characterized the original question as miscut: policy owns
placement/value construction; drivers already own execution and lifecycle. It
also noted that `tap_input`'s callback is evaluated while planning; only the
returned hook value is interpreted. The ownership prose deliberately speaks of
hook *values*, not callback execution.

Final review initially refused readiness because the qcheck generator sampled
one of six failure positions, the census baseline followed moving `HEAD`, M95/96
combined or overstated claims, registry headline totals were stale, and B's
contract burden was described as necessarily duplicated implementation. All
findings were fixed: each input now executes every position, the baseline is the
sealed-prediction commit, M95/M96 are one exact claim each, both totals read
101/64, and the matrix allows a shared B helper. The Oracle's final content
review reported no remaining test/design finding. Finder independently confirmed
the 8/3/2 consumer/interpreter/no-hook counts, 12→18 tap census, JS re-export,
and E22 registrations.

### Verdict diary

#### V-DX-E24B-002 — Retain policy-owned hooks

Status: **ACCEPT**.

Decision: keep the third `Schedule.t` parameter and both tap combinators
permanently. State the policy-value/driver-interpretation split in the mli.

Evidence: full driver inventory; exact composition trace; generated law across
all failure positions; `no_hook` positive/negative fixtures; three current
interpreter seams serving eight effectful operations.

Counterevidence considered: no production tap construction, ternary public
annotations, and B's simpler top-level callback story.

Remaining uncertainty: external usage is unknown and per-operation hook parity
is uneven, though every implementation routes through one of the three audited
seams.

Recommendation for production: retain current code; add only ownership prose,
law registration/test, and the permanent parking-lot decision.

Rationale: A is the only candidate that satisfies structural composition and
custom interpretation without creating a second protocol.

Confidence: **High** for ownership, because B fails an executable required row;
medium for long-term user value because adoption evidence is absent.

Would change if: Eta intentionally removes branch/phase-local interception from
the contract and an eight-driver B prototype proves full remaining parity with a
smaller measured surface.

#### V-DX-E24B-003 — Driver-owned observers

Status: **REJECT**.

Decision: do not slim schedules or add per-driver observer callbacks.

Evidence: one `and_then` public step emits hidden terminal-left and first-right
hooks. A top-level before/after pair cannot observe them; a policy-generated
event stream is the current hook protocol under another name.

Counterevidence considered: B makes ordinary schedule annotations binary and
names effects where their lifecycle is familiar.

Remaining uncertainty: B remains viable only for an explicitly weaker,
top-level-only observer feature, which is not semantic migration parity.

Recommendation for production: no B follow-up experiment; the failed criterion
is a requirement, not a migration-cost objection.

Rationale: B fails composition and otherwise duplicates contracts across eight
operations.

Confidence: **High**.

Would change if: structural tap placement is deliberately deleted as a contract
and the resulting narrower observer API is independently justified.

#### V-DX-E24B-004 — Seam-centered redesign

Status: **REJECT (dominated)**.

Decision: retain `step_plan` as the canonical seam and `step_with_hooks` as its
synchronous convenience; add no alias, existential package, or public effect
interpreter.

Evidence: current A is already seam-centered. The negative C fixture cannot hide
the hook while taking a driver interpreter; the positive fixture compiles only
by bundling interpretation. Signature census shows no improvement across the
eight independent effect/error signatures.

Counterevidence considered: Resource and Stream duplicate a four-line monadic
plan drain, and a private shared helper could reduce implementation repetition.

Remaining uncertainty: another concrete C design may exist.

Recommendation for production: do not add surface for two tiny helpers; revisit
only with a compiling prototype that improves measured signatures.

Rationale: the tested changes either rename A, reverse ownership, or fail the
type boundary.

Confidence: **Medium** because C is a broad design family.

Would change if: a concrete design hides the parameter from common signatures,
retains typed structural hooks and arbitrary interpreters, and reduces concepts
rather than adding wrappers.

#### V-DX-E24B-005 — E22 and implementation follow-up

Status: **ACCEPT**.

Decision: the accepted slice is implemented in `schedule.mli`, the law suite,
the E22 registry, and the DX parking lot. No runtime implementation changed.

Evidence: named qcheck property passes 50 generated cases and closes direct
`step_with_hooks` debt CD-E22-022; R96 now registers Effect, Resource, and Stream
driver tests.

Counterevidence considered: existing tests do not separately run every hook row
through every one of the eight public operations.

Remaining uncertainty: full per-operation parity would be useful if driver code
diverges in a future change, but all operations currently share three helpers.

Recommendation for production: keep the generic law plus existing focused
driver registrations; add operation-specific tests only when those paths change.

Rationale: this is the smallest test slice that directly discriminates the
ownership decision and satisfies the new prose.

Confidence: **High**.

Would change if: a driver stops using its shared interpreter seam or adds
different hook semantics.

### Prediction scoring

| Sealed prediction | Actual | Score |
| --- | --- | --- |
| A accepted | A accepted | Hit |
| B duplicates callbacks or loses composition | Exact `and_then` loss plus 8-contract minimum | Hit |
| C only partially improves signatures | Existing seam dominates tested redesigns | Hit |
| At least one E22 gap | Direct `step_with_hooks` was dated debt CD-E22-022 | Hit |
| Hook construction test-heavy but production consumers broad | No production producers; 8 production consumers | Hit with clarified producer/consumer distinction |
| Provisional 16-line/3-file census | 12 pipeline matches/4 files at baseline; E22 is the fourth file | Miss; measurement was not verified |

### Implementation agreement and deferred work

The shipped code and journal agree: runtime hook behavior is unchanged; the mli
states the proven ownership split; the named property and registry encode it;
the parking lot kills slimming with the same evidence. No B/C proposal is
registered because neither verdict lands. No runtime helper centralization,
driver callback API, or full per-operation parity expansion is in scope.

Verification is complete. `redteam/run-all.sh`, the final full OxCaml suite, the
native `@install` and shipped gates, mainline OCaml 5.4.1 `@install` and law gate,
and `@doc` all pass. The first docs attempt correctly failed because `odoc` was
absent; installing official `odoc` 3.2.1 inside `nix develop` and rerunning made
the gate pass, with only existing warnings in `capabilities.mli` and
`random.mli`. Exact commands are in `report.md`.

---

## Follow-up 1 — candidate D and the suspended-driver contract

### Trigger, question, and proof obligations

The decision review rated the original packet **SOUND-WITH-RESERVATIONS**. It
accepted A's ownership result only under the untested premise that structural
taps should exist. This entry admits the omitted boring baseline:

- **D — delete `tap_input`/`tap_output` and the hook channel; document ordinary
  process-observation recipes.**

This entry is additive and supersedes verdict strength below; it does not rewrite
the historical A/B/C evidence.

| Obligation | Evidence required | Result | Status |
| --- | --- | --- | --- |
| D1: exact deletion surface | Executable baseline/current census | 12 pre-E24b test constructions / 4 files; 2 vals; 1 Hook; 2 suspended entry points; 8 ternary operations; 2 no-hook HTTP signatures; 6 public promises; 3 interpreters | Proven by `redteam/d-surface.sh` |
| D2: ordinary recipe | Positive executable attempt-observation fixture | Custom retry logs all attempts around direct `Schedule.step` | Proven by `redteam/d_recipe.ml` |
| D3: recipe limit | Negative structural fixture | Same recipe sees only outer `Second_phase`; left terminal/right-entry events are absent | Proven by D fixture plus `policy_sequence.ml` |
| D4: resume lifecycle | Characterize success, abandonment, multiple use, hook/resume failure, partial effects, retry | Non-linear closure duplicates tentative evaluation; only `Complete` publishes; original driver retry replays prior effects | Proven by two fixed-shape laws and existing abandonment law |
| D5: wrapper/telemetry rows | Executable inside/outside wrapper order and named observations | All requested rows discriminated; no automatic telemetry | Proven by wrapper fixed-shape law |
| D6: demand | Find shipped/example producer or concrete structural adoption | None in repository; external adoption remains unknown | No current retention signal |

### Candidate D surface and capability delta

The executable census establishes that D is not B under another name. It removes
the entire channel rather than moving hooks:

| Surface | Current | D |
| --- | ---: | ---: |
| `Schedule.t` / driver parameters | 3 | 2 |
| Tap vals | 2 | 0 |
| Public Hook constructors | 1 | 0 |
| Suspended stepping entry points | 2 | 0 |
| Hook-accepting effectful operations | 8 | 0 |
| Production hook interpreters | 3 | 0 |
| Explicit no-hook HTTP annotations | 2 | 0 |
| Explicit tap-behavior prose promises | 6 | 0 |

At the sealed-prediction baseline, all 12 tap constructions are in four test
files: Effect 7, Resource 1, Stream 2, laws 2. The original ownership table added
6, this follow-up's suspension/wrapper tables add 6, and output-cancellation
integration adds 1, so the evidence tree now contains 25. Neither `lib/` nor
shipped examples construct a tap. `Eta_js` is a re-export, not a producer or
interpreter.

Capability after D is deliberately weaker. The named integration `retry attempts
can be observed without schedule taps` proves an application can instrument the
source Effect to log every retry attempt; users can wrap `Resource.auto`'s `load`;
put `Stream.tap_error` on the source before retry, instrument that source, or use
element `tap`; and wrap direct `Schedule.step` in a custom driver. Resource/Stream
recipes are partial guidance rather than parity fixtures. The quality is 4/5 for
Effect/custom
attempt-level observation and 2/5 for Resource/Stream because initial loads,
non-emitted terminal values, and empty repetition boundaries differ. No ordinary
recipe recovers branch/phase-local events from one composed step; exact parity is
0/5. D accepts that loss.

Demand evidence and behavior evidence are separated. The 8 consumers, 6 prose
promises, and tests prove a coherent extension point. They do not prove a user.
The retention signal would be one shipped non-test producer, a concrete external
use requiring schedule-local rather than operation-local placement, or an
observability integration whose telemetry cannot use process instrumentation.
No such signal is present. Under the project's “public only for demonstrated
behavior” bar, the absence encountered the original A falsifier; this follow-up
folds rather than reframing it again.

### Suspension and observability additions

“Inside” is `wrapper (tap base)`; “outside” is `tap (wrapper base)`.

| Row | Executable result | Contract consequence |
| --- | --- | --- |
| Successful resume | `step_with_hooks` interprets then resumes once | Custom driver must do the same in delivered order |
| Abandonment | Dropping a `Hook` leaves the original immutable driver at attempt one | Publish nothing; retain original |
| Multiple invocation | Calling one public resume closure twice returns two equivalent attempt-one `Complete` values and runs tentative modifier logic twice | Closure is not statically linear; multiple use violates driver contract |
| Hook failure | Every one of six fixed positions throws before a decision/next driver is returned | Abandon plan and retain original |
| Resume exception | A successful input hook followed by a raising `while_output` predicate leaves no result | Same abandonment rule applies to continuation exceptions |
| Partial effects | Successful hook prefix remains visible after later failure | No rollback |
| Retry | Original driver emits the full hook trace again; prior successful effects therefore repeat | Hooks must be idempotent if caller retries, or caller owns duplicate effects |
| Tap asymmetry | Failed `tap_input` leaves inner modifier count 0; failed `tap_output` leaves it 1. Successful retry ends at 1 vs 2 | Input precedes evaluation; output follows tentative computation but precedes publication |
| Cancellation | Existing Effect integrations preserve interruption for input and output taps and never reach a retry attempt | Generic contract treats cancellation as interpretation failure; Resource/Stream-specific cancellation is not separately tested |
| `modify_delay` inside/outside | On tested `Continue` paths when the modifier runs: input tap is always before it; output tap inside is before it and outside is after | Structural placement controls post-step order |
| `while_output` inside/outside | On tested `Continue` paths when the predicate runs: input tap is always before it; output tap inside is before it and outside is after | Structural position determines predicate-vs-hook order |
| `jittered` inside/outside | On tested `Continue` paths when a draw runs: input tap is before it in both positions; output tap inside is before it and outside is after | Random capability ordering is structural and executable |
| `named` | Named and plain traces/decisions match; only `pp` gains `Named(..., label)` | Name is display-only |
| Telemetry | Fresh Eta_test outcome has no logs, spans, or metrics from stepping/naming | Hooks may emit their own telemetry; Schedule does not |

The ownership law is now named honestly as a **fixed-shape ownership table** with
bounded payload variance. Every payload still executes all six failure positions;
it additionally retains the exact successful prefix before failure. The two new
properties also state their public observation boundary and generated class.

### Revised hypothesis ledger

| Candidate | Strongest case | Disconfirming evidence | Status |
| --- | --- | --- | --- |
| A — policy-owned hooks | Exact structural order and arbitrary typed interpreters through one plan | Zero production/example producers | **CONDITIONAL** — correct if taps exist |
| B — driver observers | Familiar top-level lifecycle and attempt callbacks | Top-level observers cannot represent branch/phase-local placement; structural observers can only by restoring policy-owned placement | **REJECTED AS TAP PARITY**; ordinary recipes survive |
| C — seam redesign | Correctly identifies interpretation as the seam | Tested existential fails; packaged interpreter and aliases add surface | **TESTED VARIANTS REJECTED**; broader family unproven |
| D — deletion | Removes actual protocol/signature surface; common attempt recipe works | Exact structural observation becomes inexpressible | **ACCEPTED AS FOLLOW-UP PROPOSAL** |

### Verdict diary

#### V-DX-E24B-006 — Delete structural taps and the hook channel

Status: **ACCEPT AS A FOLLOW-UP PROPOSAL**.

Decision: propose changing `Schedule.t`/driver to two parameters and removing the
two taps, `no_hook`, public/internal suspension machinery, `step_plan`,
`step_with_hooks`, three production interpreters, and hook threading from all
eight operations while generalizing direct `step` and `next`. All 25 current tap
constructions and E22 M65–M67/M95–M112/R96/R102 are in the deletion slice. The
exact slice and post-deletion recipes are in `review/DELETION_PROPOSAL.md`.

Evidence: executable D surface census; positive attempt recipe; negative
`and_then` structural control; zero shipped/example producers.

Counterevidence considered: structural taps are coherent, completely typed,
covered across all three production interpreter families, and strictly more
expressive than operation wrappers. External adoption is unknown.

Remaining uncertainty: this repository cannot observe downstream use. D gives up
a real capability, not dead implementation branches.

Recommendation for production: run the deletion as a separate cross-cutting
change with no shim. Until then, retain the exact current contract.

Rationale: behavior tests and public acceptance do not establish demand. The
common use case does not need schedule-local placement, while the unique use case
has no producer.

Confidence: **Medium**. Surface and in-repository demand are high-confidence;
external demand is unknown.

Would change if: a shipped producer, concrete external structural use, or
schedule-local observability integration appears before implementation.

#### V-DX-E24B-007 — Supersede permanent A and narrow B/C

Status: **ACCEPT**; supersedes the strength and scope of V-DX-E24B-002/003/004.

Decision: V-DX-E24B-002 remains correct only as “A is the ownership model if
structural taps are kept”; its permanent-retention conclusion is withdrawn.
V-DX-E24B-003 applies specifically to **top-level** driver observers; structural
observers are possible only by restoring policy-owned placement. V-DX-E24B-004
rejects only the tested C variants because they fail or add surface; it no longer
claims the broad C family is dominated.

Evidence: D's positive and negative controls distinguish feature necessity from
ownership correctness. The original A/B/C fixtures remain valid within their
actual scope.

Counterevidence considered: A still wins every row where structural parity is a
requirement.

Remaining uncertainty: an untested C design or new demand could make A the final
product choice again.

Recommendation for production: use the conditional/narrow wording everywhere in
the current review packet and parking lot.

Rationale: expanding the hypothesis space changes the product verdict without
invalidating the architecture evidence.

Confidence: **High** for the wording correction; **Medium** for D over A as the
product choice.

Would change if: executable evidence invalidates the D recipe/surface or supplies
the retention demand signal.

#### V-DX-E24B-008 — Current suspended-driver contract

Status: **ACCEPT**.

Decision: while hooks remain public, document deterministic delivery, success
then exactly-once resume, failure/cancellation abandonment, `Complete`-only
publication, no rollback/replay, input/output failure asymmetry, and `named`
telemetry transparency.

Evidence: renamed ownership table, new suspension table, new wrapper table,
existing abandonment property, and actual Effect input/output interruption
integrations. E22 registers M97–M112 and R102.

Counterevidence considered: the resume closure's OCaml type is non-linear, so the
exactly-once obligation is documented and tested by characterization rather than
mechanically enforced.

Remaining uncertainty: cancellation during Resource/Stream hook interpretation
is supported by their Effect.bind interpreter shape but lacks a driver-specific
cancellation test.

Recommendation for production: keep the prose and laws until D lands; delete
them with the protocol rather than carrying obsolete compatibility surface.

Rationale: a public custom-driver seam must state how to avoid duplicate effects
and premature state publication.

Confidence: **High** for core behavior and Effect cancellation; **Medium** for the
untested driver-specific cancellation paths.

Would change if: a production interpreter publishes a driver before plan
completion or resumes after failed/cancelled interpretation.

### Implementation and focused evidence

Runtime implementation remains unchanged. `schedule.mli` now states the current
contract; `law_properties.ml` registers 66 properties; E22 counts 117 direct
claims and 102 external clusters; the parking lot selects D rather than calling
two-parameter Schedule permanently killed. D probes are part of `run-all.sh`.

Focused laws (66 properties), `@doc`, and the complete red-team packet pass. The
required native/mainline final gates are recorded in an append-only verification
addendum after final review.

### Final verification addendum

Independent review first found missing output-tap cancellation, coarse E22 claim
clusters, an incomplete deletion slice, overbroad wrapper/telemetry wording, and
recipe evidence that covered only a custom loop. The final tree adds actual
input/output interruption integrations, the real no-tap Effect retry recipe,
one-claim M97–M112 rows, exact internal/`next` deletion work, Continue-only
wrapper qualifiers, and telemetry-silent rather than hook-telemetry-equivalence
wording. The final independent content verdict is **CONTENT READY**.

All required commands pass on the final code/test/interface tree:

```text
.scratch/research/dx/e24b/redteam/run-all.sh
nix develop -c dune runtest test/laws --force             # 66 properties
nix develop -c dune runtest test/core_eio --force         # 571 tests
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
nix develop -c dune build @doc
```

No runtime implementation changed. Current prose/tests agree on A's interim
driver contract, while the product verdict and parking lot agree on D as the
separate deletion proposal.

---

## Follow-up 2 — deletion-proposal execution corrections

### V-DX-E24B-009 — Correct the D implementation brief

Status: **ACCEPT**. D remains the selected deletion proposal; this entry corrects
what the implementation experiment must remove, preserve, and treat as evidence.

1. **Accepted loss:** deletion removes **all schedule-local effect boundaries**,
   not only branch/phase-local events. The loss includes top-level terminal
   `Done` observation, policy-generated outputs such as delay-series values,
   effects at policy evaluation/driver publication, hook failure/cancellation as
   an advancement veto, and arbitrary custom-effect-system interpretation through
   `step_plan`. Branch/phase-local observation is the strongest example. Every
   listed boundary has zero demonstrated production demand; that is why D still
   holds despite the broader 0/5 loss.
2. **Correct E22 slice:** delete M65–M67, M95–M105, M112, R96, and R102; split or
   rewrite tap-specific R80/R100. Preserve M68/R94/R95. `Schedule.named` survives:
   preserve M106/M107/M109–M111, remove M108's hook-order claim, and replace the
   tap-based combined property with a small no-hook `named` property.
3. **Wider reversal gate:** any demonstrated schedule-local effect requirement
   without an ordinary recipe can reverse D. This includes terminal-output
   handling, policy-output access, advancement veto, custom-effect-system
   interpretation, and observability; it is not limited to telemetry demand.
4. **Ancillary work:** update the non-tap ternary annotation at
   `test/core_common/properties_common_suites.ml:12`; rework/remove the old C and
   `no_hook` fixtures and runners so `redteam/run-all.sh` remains meaningful; and
   update `docs/research/dx.md` when deletion lands so the durable summary no
   longer presents E24b as a pending permanent-retention question.

Evidence: the re-audit upheld D as SOUND and reported these as proposal-document
corrections, not reasons to reopen the verdict. `review/DELETION_PROPOSAL.md` is
now the corrected execution brief; `report.md` carries the same loss, demand,
E22, and ancillary boundaries.

Counterevidence considered: losing advancement veto and custom interpretation is
more consequential than losing telemetry. No production requirement currently
uses either boundary.

Remaining uncertainty: downstream use remains unobservable from this repository;
the widened demand gate is intentionally capable of reversing D before
implementation.

Recommendation for production: execute only the corrected slice. In particular,
do not delete surviving `Schedule.named`, `next`, `Continue` delay, or jitter
random laws as collateral cleanup.

Confidence: **High** that the proposal now enumerates the known implementation
surface; **Medium** on product demand for the same external-adoption reason as
V-DX-E24B-006.

Would change if: any widened demand-gate condition is demonstrated before the
implementation experiment lands.

### Verification

Follow-up 2 changed research documents only. The required unchanged-tree gates
all pass:

```text
.scratch/research/dx/e24b/redteam/run-all.sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
```

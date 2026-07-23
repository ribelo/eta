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

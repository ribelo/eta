# DX-E19 journal — scoped capability override

## V-DX-E19-001 — sealed predictions

**Sealed before any DX-E19 code or API-documentation change.** The branch starts
from `359a2ede`; the root objective is intentionally untracked and is not part
of this experiment's commits.

### Question and constraints

Should Eta ship four dynamically scoped, fiber-local runtime-service overrides
(`with_clock`, `with_random`, `with_logger`, and `with_tracer`) while preserving
Eta's boundary that application dependencies remain ordinary OCaml values?

The selected candidate is a minimal public combinator layer over the existing
rank-2 `Runtime_contract.local_with_binding`. A universal environment, service
row, compatibility path, `intercept_*`, counter override, and `Schedule.t`
change are out of scope.

Baseline discrepancy: the assignment predicts that `Capabilities.clock` does
not exist, but this checkout already has a sleep-only class type, used by Eio,
jsoo, stream, and OTEL adapters. Prediction: the honest minimum change is to
extend it with `now_ms`, making the existing documented monotonic pair one
capability, and update all implementations.

### Provenance

Polysemy is prior art, not an Eta dependency. Its `reinterpret` re-encodes one
effect in another, while `Polysemy.Scoped.scoped` is described as a smart
constructor that uses an interpreter locally for a nested program. Eta's
analogue is deliberately narrower: swap only an Eta-owned runtime service for a
lexical subtree and preserve the existing two-parameter effect type.

- Polysemy 1.9.1.1 `reinterpret`:
  <https://hackage.haskell.org/package/polysemy-1.9.1.1/docs/Polysemy.html#v:reinterpret>
- Polysemy 1.9.1.3 `scoped`/local interpreter:
  <https://hackage.haskell.org/package/polysemy-1.9.1.3/docs/Polysemy-Scoped.html#v:scoped>

### Proof obligations

| ID | Proof question | Minimum evidence | Risk | Predicted result |
| --- | --- | --- | --- | --- |
| O1 | Can four contracts state the complete dynamic-scope semantics within a readable budget? | `.mli` caveat audit and line count | High | Pass; one shared semantic paragraph plus short service-specific notes should avoid repetition. |
| O2 | Do bindings restore on success, typed failure, defect, and interruption? | Executable native tests for all four exits | High | Pass; backend local binders already use protected dynamic bindings. |
| O3 | Are fork inheritance, no join-merge, nesting, and `par` sibling isolation exact? | Native fork/nesting/two-direction `par` tests | High | Pass; Eio copies fiber-local bindings at fork and jsoo copies its locals table. |
| O4 | Do all corresponding leaves consult at call time? | Clock sleep/timeout/retry; random draw; log; span tests | High | Initial implementation will miss indirect leaves unless access is centralized; tests will force schedule, observability, and instrumentation paths through lookups. |
| O5 | Are in-flight sleep/open-span and daemon semantics honest? | Three adversarial red-team fixtures | High | In-flight operations retain the capability selected when opened; a daemon retains its fork-time binding after lexical scope exit. |
| O6 | Does jsoo match for clock and logger? | Executable jsoo tests | Medium | Pass without backend changes because jsoo locals already fork-copy and restore. |
| O7 | Is W6 materially smaller than test-runtime assembly? | Compilable old/new review examples and LOC count | Medium | New form removes runtime construction and makes the override boundary visible at the assertion. |

### Hypothesis ledger

| Candidate | Strongest case | Falsifier | Sealed status |
| --- | --- | --- | --- |
| A. Four combinators over existing runtime locals | Owns exactly the runtime-service substitution invariant with one combinator | Any required edge cannot be expressed without new backend state or semantic fallback | Favored, pending evidence |
| B. Explicit runtime assembly | Already works and keeps configuration at interpreter creation | W6 remains equally clear/short and subtree composition needs no bespoke runtime | Baseline, pending comparison |
| C. Universal environment/service row | General substitution could cover future dependencies | Violates the explicit Eta boundary and widens `Effect.t` beyond runtime-owned services | Out of scope by project constraint |
| D. Documentation-only recipe | Zero public API and no local machinery | Cannot substitute one subtree without constructing/routing a separate runtime | Predicted dominated by A |

### Quantitative predictions (score later)

1. **Public census:** observability cluster `+4 val`; `Capabilities` `+1`
   effective type change (extend the existing `clock`, no second clock type).
2. **Implementation:** four local keys and one generic internal scoped-binding
   helper; no runtime-backend API change and no compatibility branch.
3. **Tests:** every required edge passes on the first semantics-preserving
   architecture after ordinary compile fixes; jsoo needs tests but no local
   implementation change.
4. **W6:** scoped form is at least 40% fewer nonblank code lines than explicit
   test-runtime assembly.
5. **Doc budget:** all shared scope caveats fit in at most 18 prose lines in
   `effect.mli`; service-specific interplay fits in at most 12 further prose
   lines. Total budget: 30 prose lines for the four combinators.
6. **Footguns:** `+0` undisclosed footguns. Three traps are expected and must be
   disarmed by docs: (T1) a `par` sibling does not see a branch-local override,
   (T2) replacing a capability does not alter an in-flight sleep/open span,
   (T3) a daemon keeps the binding inherited at fork after scope exit.

### Evidence that would kill or change the recommendation

- Kill if the complete contract cannot fit the sealed documentation budget
  without ambiguity.
- Kill if either backend cannot provide fork inheritance plus sibling isolation
  using the existing local-binding contract.
- Change the design if leaf-by-leaf lookup creates inconsistent service choice
  within one clock operation or span lifecycle; the pair/lifecycle must be
  captured once at the operation boundary.
- Keep B rather than A if W6 is not materially smaller or if A requires public
  environment machinery.

Status: **PREDICTIONS SEALED; implementation evidence pending.**

## V-DX-E19-002 — implementation verdict

Status: **ACCEPT**

Decision: promote the four scoped capability overrides. They remain a narrow
runtime-service seam over `Runtime_contract.local_with_binding`; they do not add
an application environment or dependency row.

### Implementation evidence

- `Capabilities.clock` was already present at the branch baseline, contrary to
  the assignment's baseline description. It now carries the complete monotonic
  `now_ms`/`sleep` pair, and every repository implementation was updated.
- Four typed runtime-local keys back one generic internal binding helper.
  Capability lookup is activated only inside an override frame. This preserves
  the existing ability to run a runtime's purely fiberless leaves on another
  domain without calling owner-domain-only runtime-local APIs.
- Runtime record copies share daemon drain waiters through a ref. The first
  implementation copied a mutable list field; the full suite exposed a lost
  wakeup when a daemon inherited an override-frame copy. The shared ref is the
  executable correction, not a fallback path.
- Active spans carry their captured tracer, integer handle, and propagation
  info. Cross-tracer nesting uses an external parent context instead of passing
  a foreign tracer's integer handle. Same-fiber tracer task contexts are
  reentrant; newly forked fibers get isolated mutable tracer state.
- Core clock leaves, retry/repeat drivers, timestamps, log sinks, span
  lifecycle, runtime trace-ID generation, and daemon diagnostics select the
  active capability at their operation boundary. Explicit random tokens and
  non-Effect schedule drivers remain explicit by contract.
- Eio and jsoo local-binding implementations required no semantic change.
  Jsoo clock/logger parity is executable in `test/js_jsoo/test_eta_jsoo.ml`.

### Disconfirming evidence and corrections

An attempted dynamic rewrite of `Runtime_contract.now_ms`/`sleep` made every
contract read perform an owner-domain local lookup. The full suite rejected it
in the existing “fiberless frame is domain local” regression. It was removed:
the public Effect clock leaves use scoped lookup, while direct low-level
contract consumers keep the contract's existing domain rules.

The first full gate also rejected calling `current_fiber_id` from manual tracer
use without an established identity. Tracer task-context entry now establishes
the identity through the runtime contract and reuses it when already present.

These failures changed the implementation but did not weaken or add fallback
branches to the public semantics.

### Edge matrix

| Obligation | Executable evidence | Result |
| --- | --- | --- |
| Restore on success / typed failure / defect / interruption | Scoped-capability case 0 | Proven |
| Restore after actual runtime cancellation | Case 8 | Proven |
| Fork inheritance across all four bindings | Case 1 | Proven |
| `par` sibling isolation, both directions | Case 2 | Proven |
| Innermost wins; restore outer | Case 3 | Proven |
| Clock controls sleep and timeout without wall time | Case 4 | Proven |
| Random override controls retry jitter replay | Case 5 | Proven |
| Logger replacement + attrs + minimum filter | Case 6 | Proven |
| Daemon retains fork-time bindings | Case 7 | Proven |
| Cross-tracer open-span ownership | Cases 9 and 10 | Proven |
| In-flight real sleep unchanged | Case 11 | Proven |
| Daemon failure diagnostics use inherited overrides | Case 12 | Proven |
| Jsoo clock + logger parity | `scoped clock and logger parity` | Proven |

### Prediction score

| # | Prediction | Score | Outcome |
| --- | --- | --- | --- |
| 1 | Public census +4 vals, +1 effective clock type change | 1 | Exact after accounting for the pre-existing sleep-only type. |
| 2 | Four keys, generic helper, no backend API change | 1 | Exact; additional active-span ownership work was required. |
| 3 | Edge tests pass after ordinary fixes; jsoo needs no local change | 0.5 | Jsoo prediction held; native full-gate failures exposed two non-ordinary runtime invariants before final pass. |
| 4 | W6 at least 40% fewer lines | 0 | 31 to 24 code lines (22.6%); the user-facing gain is one visible override instead of runtime clock assembly, but the sealed percentage missed. |
| 5 | Contract fits at most 30 lines | 1 | 29 caveat prose lines; 30 nonblank lines including the example. |
| 6 | +0 undisclosed footguns; three traps documented | 1 | All three traps are in every relevant contract and executable red-team evidence. |

Total: **4.5 / 6**.

### Hypothesis ledger final state

- **A — four combinators over runtime locals: ACCEPTED.** It satisfies the full
  matrix and preserves Eta's boundary.
- **B — explicit runtime assembly: DOMINATED for subtree substitution.** It
  remains valid interpreter configuration, but W6 shows the fake clock is no
  longer coupled to runtime construction.
- **C — universal environment/service row: OUT OF SCOPE.** No evidence or code
  widened `Effect.t`.
- **D — documentation-only recipe: DOMINATED.** It cannot provide lexical
  substitution, fork inheritance, and sibling isolation in one call.

Counterevidence considered: W6 missed the sealed 40% whole-fixture LOC target,
and low-level direct `Runtime_contract` clock consumers cannot be dynamically
rewritten without violating the existing owner-domain contract. Neither is a
public-semantics failure: W6 removes the bespoke runtime seam, and the scoped
contract names the corresponding Effect leaves.

Confidence: **High**, because both backends, all exit/lifecycle edges, the
adversarial traps, and every required repository gate are executable and pass.

Recommendation: **PROMOTE DX-E19**.

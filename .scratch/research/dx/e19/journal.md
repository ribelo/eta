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

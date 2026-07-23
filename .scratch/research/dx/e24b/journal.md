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

# DX-E24b review decision record

## Decision

**Retain policy-owned hooks (A).** `Schedule.t` remains ternary and
`tap_input`/`tap_output` remain public. Policy owns hook values and their
structural order; drivers own execution and resumption. Driver-owned observers
(B) fail composition parity. The tested seam redesigns (C) are dominated by the
existing `step_plan` seam.

## Complete inventory

| Surface | Count / location | Interpretation |
| --- | --- | --- |
| Hook producers | Only `Schedule.tap_input` and `tap_output`, `schedule.ml:76-77` | Policy nodes |
| Effect operations | 3: `retry`, `retry_or_else`, `repeat` | One `step_with_hooks` interpreter |
| Resource operations | 1: `Resource.auto` | One hand-drained `step_plan` interpreter |
| Stream operations | 4: `from_schedule`, `schedule`, `repeat`, `retry` | One shared hand-drained `step_plan` interpreter |
| No-hook production operations | 2 HTTP retry signatures | `next`, statically `no_hook` |
| Public custom protocol | `start`, `step_plan`, `step_with_hooks`, `step`, `next` | Arbitrary interpreter or statically direct path |
| Re-export | `lib/js/eta_js.ml/.mli:17` | JS users receive the same public Schedule protocol |
| Tap constructors before E24b | 12 calls / 4 test files; none in production | Behavior evidence, not adoption evidence |

The three production interpreter helpers serve 3 + 1 + 4 effectful operations.
`Eta_js` re-exports Schedule but does not add another interpreter. A runtime-core
module alias has no direct use.

## Semantics matrix

| Requirement | A — current ownership split | B — per-driver callbacks | C — seam redesign |
| --- | --- | --- | --- |
| Pre-step | Branch/phase-local `Tap_input`, possibly multiple per public step | Top-level pre-step only | Preserved only by retaining plan |
| Post-step including `Done` | Every local output, including hidden branch terminal outputs | Outer output only; all drivers must remember outer `Done` | Preserved by current plan |
| Failure/no advancement | Next driver withheld until all hooks succeed | All 8 APIs must honor it; a shared helper could centralize implementation | Current continuation already solves it |
| Composition order | Structural; exact nested order | Cannot see inner handoff events | Full only if C is A-shaped |
| Suspended interpretation | `Hook (value, resume)` for Eta or custom systems | Removed; custom drivers invent contracts | Existential hiding blocks driver interpreter |
| No-hook ergonomics | Inferred direct use; tapped direct use rejected | Binary schedule type, but observer contracts move to 8 APIs | Alias may shorten 2 HTTP annotations only |

## Cross-tab

| Criterion | A | B | C |
| --- | --- | --- | --- |
| Static hook safety | Typed hook + uninhabited no-hook marker | Callback contract only | Hidden type cannot be interpreted externally |
| Structural composition | Complete | Fails executable handoff trace | Existing A seam is required |
| Runtime ownership | Policy places, driver executes | Driver places and executes | Positive existential packages interpreter with policy |
| Custom drivers | One full public protocol | Per-driver guidance/protocol | Negative fixture fails |
| Surface | Ternary type + 2 taps | Binary type + at least 1 type/8 labels | More wrappers, no demonstrated signature reduction |
| Strongest positive | One mechanism serves all drivers | Locally obvious top-level lifecycle callbacks | Correct focus on suspended seam |
| Strongest negative | No production tap producers | Semantic loss under composition | Current design is already seam-centered |
| Status | **ACCEPT** | **REJECT** | **REJECT (dominated)** |

## Decisive evidence

`.scratch/research/dx/e24b/redteam/run-all.sh` proves:

- one `and_then` driver step yields 4 branch-local hooks versus B's 2 outer
  callbacks;
- direct interpreter failure publishes no advanced driver;
- a two-parameter existential cannot accept the driver's hook interpreter;
- the positive C control works only by bundling that interpreter;
- ordinary no-hook inference succeeds and tapped direct stepping fails.

The production law
`Schedule policy hook order survives and_then and step_with_hooks publishes only after interpreter success`
checks the six-event outer/left/right order and all six failure positions for 50
generated inputs. E22 rows M95/M96 and R96 register the law and driver evidence.

## Verdict diary pointers

- V-DX-E24B-002 — A accepted.
- V-DX-E24B-003 — B rejected by composition fixture.
- V-DX-E24B-004 — C rejected as dominated by the existing seam.
- V-DX-E24B-005 — ownership prose and law slice accepted.

Full fields, counterevidence, confidence, and “would change if” conditions are in
`../journal.md`.

## Strongest unresolved objection

All in-repository tap producers are tests. Retaining a sophisticated ternary
public protocol without demonstrated external adoption is a real YAGNI risk.
The current evidence answers semantic necessity *if structural taps remain a
feature*; it cannot prove user demand. The decision would change if Eta
deliberately removed branch/phase-local interception and a complete eight-driver
top-level observer prototype reduced total surface.

## Verification

The final native `@install`, full test, and shipped gates pass. Mainline OCaml
5.4.1 `@install` and `test/laws` pass. `@doc` passes after installing the missing
official `odoc` 3.2.1 tool inside the Nix development shell. The red-team packet
passes before handoff. See `../report.md` for exact commands.

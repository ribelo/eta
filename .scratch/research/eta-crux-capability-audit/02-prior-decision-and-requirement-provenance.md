# Prior decision and requirement provenance for Eta Crux

Date: 2026-08-10

Ticket: [Prior decision and requirement provenance](../../../docs/wayfinder/eta-crux-capability-audit/issues/02-prior-decision-and-requirement-provenance.md)

Baseline: [`01-current-eta-crux-capability-baseline.md`](01-current-eta-crux-capability-baseline.md)

## Question

What decision history exists for the nine reported gaps and related capability families?

The ticket asks for the provenance of each capability.

The five record classes are: explicit accepted decision, explicit exclusion, unresolved question, accidental omission, and superseded promise.

The old requirement bundle is evidence only. This report does not decide adopt, defer, or reject.

## Method

Primary sources only:

| Source | Role |
|---|---|
| `docs/requirements/eta-crux/` at commits `19c3687a` through `f9a3eedd^` | The removed requirement bundle with the named old requirements |
| `docs/wayfinder/eta-crux/issues/` at `f9a3eedd^` | The superseded predecessor ticket set |
| `docs/wayfinder/eta-crux-first-principles/` | The current first-principles map and resolved tickets |
| `docs/design/eta-crux-v1/` | The final design and its exclusions |
| `.scratch/research/eta-crux/reference-semantics.md` | Tracked research that audited the old bundle |
| `lib/crux/eta_crux.mli`, `lib/crux_test/eta_crux_test.mli` | Current public surfaces where needed |
| Git history | Commits that added, edited, and removed the old records |

Each claim carries a source path, a line span, or a commit hash.

## Decision timeline

| Date | Commit | Event |
|---|---|---|
| 2026-07-04 | `19c3687a` | Add `docs/requirements/eta-crux/` with 17 notes and 179 requirement IDs |
| 2026-07-31 | `59483115` | Reconcile the bundle to EARS note conventions. No obligation changed |
| 2026-07-31 | `942cabb9` | Chart the predecessor map with 17 tickets. Two reopen recorded decisions |
| 2026-07-31 | `0887fdbf` | Chart the current first-principles map |
| 2026-08-02 | `bb16d4ca` | Plan to keep `eng-6h8t` in the bundle |
| 2026-08-03 | `f31842ec` | Define canonical vocabulary in both maps |
| 2026-08-04 | `51038bc5` | Close State representation seam and plain-state V1. Mark the predecessor map inactive |
| 2026-08-04 | `f9a3eedd` | Delete the old bundle and the predecessor map. Add the final design |
| 2026-08-10 | `d977a970` | Chart this capability audit and its gap tickets |

## The removed requirement bundle

Commit `19c3687a` added 17 notes under `docs/requirements/eta-crux/`.

The bundle covered the core, tick order, dispatch, commands, subscriptions, fragments, lifecycle, adapter, errors, and testing.

Commit `f9a3eedd` deleted the complete bundle.

The design README records the reason. The old bundle described commands, subscriptions, fragments, and backend choices that are not part of the design (README lines 17-19).

[Final design and legacy reconciliation](../../../docs/wayfinder/eta-crux-first-principles/issues/22-final-design-reconciliation.md) records the same removal (lines 38-41).

The research report `.scratch/research/eta-crux/reference-semantics.md` audited the bundle first. Section 8 concludes that the bundle over-copied Crux shell ports, Elm subscriptions, and an invented fragment-address output system (lines 415-430).

## The superseded predecessor ticket set

Commit `942cabb9` charted `docs/wayfinder/eta-crux/` with 17 tickets.

Its message records that two tickets reopen recorded decisions. They are Request/resolve as a framework primitive, in both directions (`docs/wayfinder/eta-crux/issues/04-request-resolve-primitive.md` at `f9a3eedd^`). The other is Action admission classes: droppable and guaranteed (`docs/wayfinder/eta-crux/issues/10-action-admission-classes.md` at `f9a3eedd^`).

The predecessor map declared itself inactive before deletion. Its notes state that the first-principles map replaced it and that no open child ticket is takeable (`docs/wayfinder/eta-crux/map.md` lines 13-16 at `f9a3eedd^`).

Commit `51038bc5` closed State representation seam and plain-state V1 without a design decision (`docs/wayfinder/eta-crux/issues/01-state-representation-seam.md` at `f9a3eedd^`). The canonical map rejected its plain-state premise.

Commit `f9a3eedd` deleted the predecessor map and all 17 tickets.

Fifteen tickets stayed open at deletion. Only two carried answers. They are State representation seam and plain-state V1 (`docs/wayfinder/eta-crux/issues/01-state-representation-seam.md` at `f9a3eedd^`). The other is Vocabulary: Elm names and the Task framing (`docs/wayfinder/eta-crux/issues/03-vocabulary-elm-names.md` at `f9a3eedd^`).

## The current first-principles design record

Commit `0887fdbf` charted the current map with 22 tickets.

The first-principles map notes treat the old bundle and the predecessor map as provisional input, not settled direction (map.md Notes section).

All 22 tickets are resolved. Their answers form the accepted decision records for the final design.

The final design `docs/design/eta-crux-v1/` is the implementation authority. Its README lists the deliberate exclusions (lines 86-94).

## Named old requirement check

All seven named requirements exist in the removed bundle.

| ID | File and line at `f9a3eedd^` | Normative text, shortened | Found |
|---|---|---|---|
| `tick-k9r2` | `docs/requirements/eta-crux/tick.md:61` | A due timer deadline makes the application driver eligible to advance | Found |
| `eng-6h8t` | `docs/requirements/eta-crux/engine-strategy.md:45` | An engine time node at due time provides wake information for the driver | Found |
| `test-h5w3` | `docs/requirements/eta-crux/testing.md:35` | The synchronous harness exposes one opaque pending-command handle per scheduled command | Found |
| `test-r8k2` | `docs/requirements/eta-crux/testing.md:38` | Handle identity is owning cell, emission order, and slot | Found |
| `test-3h6t` | `docs/requirements/eta-crux/testing.md:41` | Resolving a handle feeds the action through dispatch without command work | Found |
| `test-b5r8` | `docs/requirements/eta-crux/testing.md:47` | Tests can assert handle cancellation on branch disposal or slot replacement | Found |
| `cmd-r5w9` | `docs/requirements/eta-crux/commands-and-effects.md:72` | Diagnostics use Eta effect names and annotations, not a scheduled-command payload | Found |

All seven appear in the initial commit `19c3687a` and in the final state before deletion.

`eng-6h8t` has one current-tree reference. The issue [Package and documentation boundary](../../../docs/wayfinder/eta-signal-keyed-map/issues/14-package-and-documentation-boundary.md) cites the ID at line 127 and planned to keep the requirement in the bundle.

The bundle deletion removed the requirement itself two days later. The current-tree mention is a stale reference to the removed bundle, not a normative requirement.

No named requirement remains normative in any current tracked file.

## Provenance per gap

### Gap 1 — Graph time and deterministic clock control

Ticket: [Graph time and deterministic clock control](../../../docs/wayfinder/eta-crux-capability-audit/issues/09-graph-time-and-deterministic-clock-control.md)

The old bundle required timers as graph-owned work. `tick-k9r2` (tick.md:61) and `conc-k9r2` (concurrency.md:45) made a due timer wake the driver.

`eng-6h8t` (engine-strategy.md:45) required the engine to provide the wake. `driver-r5c1` (lifecycle.md:47) listed advancing test time among driver operations. `test-e8k3` (testing.md:58) ran timers under test time.

The research report rejected the Bonsai UI-time source (line 124). It rejected Elm ports and flags as deployment boundary (line 230). It rejected `crux_time` as product packaging (line 285). It called timer eligibility over-specified (lines 370-371).

The final design owns no clock. [Deterministic advancement transaction](../../../docs/wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md) states that timers and external sources wake the driver by sending endpoint messages (line 218).

[Host capabilities and request-response](../../../docs/wayfinder/eta-crux-first-principles/issues/13-host-capabilities-and-requests.md) states that Eta Crux adds no default timeout (line 183). Applications express deadlines with Eta effects (line 184).

[Deterministic testing contract](../../../docs/wayfinder/eta-crux-first-principles/issues/12-testing-contract.md) states that clock movement does not advance Eta Crux (lines 450-451). The README excludes a default timeout (line 93). `eta_crux.mli` has no clock or deadline symbol. The test handle has no time control (`eta_crux_test.mli`).

**Classification: superseded promise.** The old bundle promised timer-driven wake and test-time advancement. The final design replaced that mechanism with application-owned deadline effects and endpoint messages. The replacement is deliberate and documented.

### Gap 2 — External graph input

Ticket: [External graph input](../../../docs/wayfinder/eta-crux-capability-audit/issues/10-external-graph-input.md)

`core-loop.md` carried an open question about a separate external input variable API (line 98). `tick.md` carried an unsettled input-freshness rule.

The final design decided the question. [Deterministic advancement transaction](../../../docs/wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md) states that external values enter application state only through typed endpoint messages (line 83). No separate mutable root-input path exists (line 84).

[Action injection and staged Eta effects](../../../docs/wayfinder/eta-crux-first-principles/issues/05-action-effect-protocol.md) defines state machines with a typed input computation (`input:'input t`).

**Classification: unresolved question in the old record, explicit decision in the final design.** Endpoint messages plus typed input computations replace the open question.

### Gap 3 — Startup facts and flags

Ticket: [Startup facts and flags](../../../docs/wayfinder/eta-crux-capability-audit/issues/11-startup-facts-and-flags.md)

The old concepts note reserved the name "startup input" for host-supplied startup data. Its type and lifecycle remained open (concepts.md lines 70-71 and 95).

Vocabulary: Elm names and the Task framing repeated the same openness in its answer (`docs/wayfinder/eta-crux/issues/03-vocabulary-elm-names.md` at `f9a3eedd^`). Startup flags (`docs/wayfinder/eta-crux/issues/06-startup-flags.md` at `f9a3eedd^`) asked whether an application instance accepts typed flags. It stayed open at deletion.

The research report classified ports and flags as deployment boundary (line 230).

No current ticket names flags or startup facts. [Public computation and construction API](../../../docs/wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md) records that ordinary closures can carry any OCaml value (line 133). Startup data enters as closure-captured values.

**Classification: unresolved question.** The final design settled the question implicitly through closure capture. No decision record names flags explicitly.

### Gap 4 — Staged-effect observability

Ticket: [Staged-effect observability](../../../docs/wayfinder/eta-crux-capability-audit/issues/12-staged-effect-observability.md)

The bundle required command work to be a bare force-total Eta effect (`cmd-4t7m`, `cmd-7h2q`). It required diagnostics through Eta effect names and annotations (`cmd-r5w9`).

The testing note required opaque pending-command handles with identity, resolution, and cancellation (`test-h5w3`, `test-r8k2`, `test-3h6t`, `test-b5r8`).

Item 1 of ADRs for the four settled architecture decisions recorded the accepted cost: no assert-the-command-value testing (`docs/wayfinder/eta-crux/issues/15-adrs.md` at `f9a3eedd^`). The research report marked the pending-command handle shape as undecided (line 356).

[Action injection and staged Eta effects](../../../docs/wayfinder/eta-crux-first-principles/issues/05-action-effect-protocol.md) rejects a command wrapper (line 26). [Deterministic testing contract](../../../docs/wayfinder/eta-crux-first-principles/issues/12-testing-contract.md) rejects a pending-command wrapper and a synchronous transition simulator (lines 537-538). Tests control real Eta effects through `Eta_test.Controlled`.

**Classification: explicit accepted decision.** The opaque-effect choice is accepted in both records. The pending-command handle promises are superseded by controlled dependencies.

### Gap 5 — Host-owned streaming operations

Ticket: [Host-owned streaming operations](../../../docs/wayfinder/eta-crux-capability-audit/issues/13-host-owned-streaming-operations.md)

The bundle carried an Elm-style subscription algebra and capability messages. Request/resolve as a framework primitive, in both directions (`docs/wayfinder/eta-crux/issues/04-request-resolve-primitive.md` at `f9a3eedd^`) proposed request/resolve with `Once` and `Many` semantics. It stayed open.

Item 4 of ADRs for the four settled architecture decisions recorded symmetric messaging without Crux request machinery (`docs/wayfinder/eta-crux/issues/15-adrs.md` at `f9a3eedd^`).

The research report rejected the subscription algebra as framework surface (lines 362-364). It rejected capability messages as core architecture (line 353).

[Host capabilities and request-response](../../../docs/wayfinder/eta-crux-first-principles/issues/13-host-capabilities-and-requests.md) states that the framework provides no streaming or `Many` request form (line 51). Repeated host events use the `Source` contract (lines 51-52). The README excludes a streaming request (line 93).

[Long-lived sources and subscriptions](../../../docs/wayfinder/eta-crux-first-principles/issues/08-subscriptions-and-sources.md) defines the thin `Source` computation (line 28).

**Classification: explicit exclusion.** No streaming or `Many` request form exists. The `Source` contract is the accepted replacement for repeated host events.

### Gap 6 — Ingress admission classes

Ticket: [Ingress admission classes](../../../docs/wayfinder/eta-crux-capability-audit/issues/14-ingress-admission-classes.md)

`dispatch.md` recorded the bounded-queue decision. Non-owner overflow reports admission failure. When the queue is full, owner-domain producers suspend (lines 17-21).

The note carried open questions on the admission-failure type and coalescing policies (lines 51-54). Action admission classes: droppable and guaranteed (`docs/wayfinder/eta-crux/issues/10-action-admission-classes.md` at `f9a3eedd^`) explicitly reopened the recorded decision. It asked for droppable and guaranteed classes. It stayed open.

[Action injection and staged Eta effects](../../../docs/wayfinder/eta-crux-first-principles/issues/05-action-effect-protocol.md) defines one admission error, `Ingress_closed`. [Exported endpoint and handle contract](../../../docs/wayfinder/eta-crux-first-principles/issues/16-exported-endpoint-contract.md) adds only a nonblocking capacity result, `Full`.

No current ticket or design document names admission classes, reserved capacity, priority classes, or coalescing.

**Classification: unresolved question.** The old reopening was never answered. The final design keeps single-class bounded admission without an explicit statement against classes.

### Gap 7 — Pull observation of root output

Ticket: [Pull observation of root output](../../../docs/wayfinder/eta-crux-capability-audit/issues/15-pull-observation-of-root-output.md)

`fragments.md` required pull observation. An observer pulls the current stabilized fragment tree without graph mutation (`vm-b3n8`, line 59).

The research report rejected fragment address trees as a public contract (lines 319 and 370). Observation reflects committed state, not durability (`docs/wayfinder/eta-crux/issues/11-observation-not-durability.md` at `f9a3eedd^`) asked whether observation implies durability. It stayed open.

[Typed observation plan for host delivery](../../../docs/wayfinder/eta-crux-first-principles/issues/09-typed-observation-plan.md) makes one committed root output the only application observation (lines 35-36). [Generic host adapter contract](../../../docs/wayfinder/eta-crux-first-principles/issues/10-generic-host-adapter.md) defines a pull-based driver for events with one-shot delivery tokens.

No production pull of committed output exists. The test handle exposes `last_output` of the latest successfully delivered output (`eta_crux_test.mli:71`).

**Classification: superseded promise.** The fragment-tree pull requirement was replaced by the root-snapshot contract. Driver events are pullable. Committed output pull exists only in the test package.

### Gap 8 — Host-operation layers

Ticket: [Host-operation layers](../../../docs/wayfinder/eta-crux-capability-audit/issues/16-host-operation-layers.md)

Middleware layer for capability messages (`docs/wayfinder/eta-crux/issues/13-middleware-layer.md` at `f9a3eedd^`) asked for a middleware layer over capability messages. It stayed open at deletion.

The README excludes a middleware chain (line 89). `Request.Driver_event.handle` returns `Handled` or `Different_operation` (`eta_crux.mli` lines 273-289). Hosts can write sequential handle chains.

**Classification: explicit exclusion.** The middleware chain is out of V1 by name. The handle chain is the accepted primitive.

### Gap 9 — Action history and diagnostics

Ticket: [Action history and diagnostics](../../../docs/wayfinder/eta-crux-capability-audit/issues/17-action-history-and-diagnostics.md)

Action log exposed to hosts (`docs/wayfinder/eta-crux/issues/14-action-log.md` at `f9a3eedd^`) asked for a bounded action log for hosts. It stayed open at deletion.

It also noted that the test harnesses record actions and pending-command handles. `errors.md` required crash reports with optional model snapshots.

[Operational introspection boundary](../../../docs/wayfinder/eta-crux-first-principles/issues/20-operational-introspection.md) states that Eta Crux retains no action history (line 39). It exposes no graph snapshot, node registry, scope registry, model inspector, time travel, or replay (line 39).

The README excludes action history, replay, and graph inspection (lines 89-90). Telemetry is a fixed set of logs, metrics, and spans with no payload history.

**Classification: explicit exclusion.** Action history, replay, and graph inspection are out of V1 by name. Fatal snapshots and fixed telemetry remain.

## Coverage table

| Ticket | Historical record class |
|---|---|
| [Graph time and deterministic clock control](../../../docs/wayfinder/eta-crux-capability-audit/issues/09-graph-time-and-deterministic-clock-control.md) | Superseded promise |
| [External graph input](../../../docs/wayfinder/eta-crux-capability-audit/issues/10-external-graph-input.md) | Unresolved question, then explicit decision |
| [Startup facts and flags](../../../docs/wayfinder/eta-crux-capability-audit/issues/11-startup-facts-and-flags.md) | Unresolved question |
| [Staged-effect observability](../../../docs/wayfinder/eta-crux-capability-audit/issues/12-staged-effect-observability.md) | Explicit accepted decision |
| [Host-owned streaming operations](../../../docs/wayfinder/eta-crux-capability-audit/issues/13-host-owned-streaming-operations.md) | Explicit exclusion |
| [Ingress admission classes](../../../docs/wayfinder/eta-crux-capability-audit/issues/14-ingress-admission-classes.md) | Unresolved question |
| [Pull observation of root output](../../../docs/wayfinder/eta-crux-capability-audit/issues/15-pull-observation-of-root-output.md) | Superseded promise |
| [Host-operation layers](../../../docs/wayfinder/eta-crux-capability-audit/issues/16-host-operation-layers.md) | Explicit exclusion |
| [Action history and diagnostics](../../../docs/wayfinder/eta-crux-capability-audit/issues/17-action-history-and-diagnostics.md) | Explicit exclusion |

No gap classifies as accidental omission. Every capability has at least one record trace.

## Contradictions and tensions

1. The issue [Package and documentation boundary](../../../docs/wayfinder/eta-signal-keyed-map/issues/14-package-and-documentation-boundary.md) planned to keep `eng-6h8t` in the bundle on 2026-08-02. The finalization commit deleted the bundle on 2026-08-04 with no timer contract.

2. The bundle promised advancing test time as a driver operation. The final design has no such operation. Tests adjust the Eta runtime clock, which does not advance Eta Crux.

3. The bundle promised opaque pending-command handles. The final design replaced them with controlled dependencies over real Eta effects.

4. Request/resolve as a framework primitive, in both directions (`docs/wayfinder/eta-crux/issues/04-request-resolve-primitive.md` at `f9a3eedd^`) and Action admission classes: droppable and guaranteed (`docs/wayfinder/eta-crux/issues/10-action-admission-classes.md` at `f9a3eedd^`) reopened recorded decisions. The first received an answer in the new request contract. The second received none.

5. ADRs for the four settled architecture decisions asked for four ADRs (`docs/wayfinder/eta-crux/issues/15-adrs.md` at `f9a3eedd^`). Only ADR 0004 matches one of the four requested items (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md`). The other three decisions became first-principles tickets.

6. The supersession was explicit. The predecessor map declared itself inactive. The design README and [Final design and legacy reconciliation](../../../docs/wayfinder/eta-crux-first-principles/issues/22-final-design-reconciliation.md) both record the removal.

## Missing evidence

1. No ADR or ticket records an explicit decision about admission classes.
2. No ADR or ticket records an explicit decision about startup flags.
3. The open questions of the old bundle are the only record for input variables, admission classes, and flags.
4. The fifteen open predecessor tickets carry no answers. Their absence is the record.
5. `eta_signal` still exposes timer support (`lib/signal/eta_signal.mli` lines 242-243 and 455-460). The Crux design never integrated it. This substrate is outside this ticket.
6. This report did not re-run the test suite.

## Summary

Every named old requirement exists in the removed bundle. The bundle and the predecessor map were superseded by the first-principles map and the final design.

Three gaps carry explicit exclusions: streaming requests, middleware chain, and action history.

Two gaps carry superseded promises: graph time and fragment-tree pull observation.

Two gaps carry unresolved questions: startup flags and admission classes.

Two gaps carry explicit decisions in the final design: opaque staged effects and endpoint-only external input.

The old bundle is evidence only. This report records facts and rationale. It does not decide the new disposition.

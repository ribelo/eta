# Current Eta Crux capability baseline

Date: 2026-08-10
Ticket: [`docs/wayfinder/eta-crux-capability-audit/issues/01-current-eta-crux-capability-baseline.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/01-current-eta-crux-capability-baseline.md)

## Question

What capabilities and exclusions does the current Eta Crux implementation expose?

## Method

Primary sources only:

| Source | Role |
|---|---|
| `lib/crux/eta_crux.mli`, `lib/crux/eta_crux.ml` | Public production surface and module wiring |
| Private `lib/crux/crux_*.ml` | Implementation path for public modules |
| `lib/crux_test/eta_crux_test.mli` and private test modules | Public test surface |
| `docs/design/eta-crux-v1/{README,public-api,semantic-laws,verification}.md` | Design authority, laws, gates |
| `test/crux/**` | Executable gates |
| Gap tickets `issues/09` through `issues/17` | The nine reported claims |

This report records facts. It does not decide adopt, defer, or reject.

Classification vocabulary:

| Class | Meaning |
|---|---|
| `missing` | No public API and no design ownership for the capability |
| `partial` | Some related surface exists. The full reported capability does not |
| `application-composable` | Callers can build the behavior from public primitives without a first-class Crux concept |
| `deliberately excluded` | Design or public exclusion text forbids the capability in V1 |
| `incorrect` | The factual claim does not match the current sources |

## Public capability families in current code

### Package graph

| Package / library | Path evidence | Public role |
|---|---|---|
| `eta_crux` | `lib/crux/dune` public_name `eta_crux` | Core computation, root, driver, host, wire types |
| `eta_crux_test` | `lib/crux_test/dune` public_name `eta_crux_test` | Test handle and controlled dependencies |
| `eta_crux_json` | `lib/crux_json/eta_crux_json.ml` | JSON `Wire.FORMAT` implementation |
| `eta_crux_sexp` | `lib/crux_sexp/eta_crux_sexp.ml` | S-expression `Wire.FORMAT` implementation |
| private `crux_wire_common` | `lib/crux_wire_common/` | Shared wire protocol model helpers |

Design package graph: `docs/design/eta-crux-v1/README.md` lines 50-56.

### `Eta_crux` public families

Source: `lib/crux/eta_crux.mli` full file. Re-export map: `lib/crux/eta_crux.ml` lines 1-39.

| Family | Symbols / modules | Implementation path |
|---|---|---|
| Computation core | `type 'a t`, `return`, `map`, `both`, `cutoff`, `bind`, `Syntax` | `crux_engine.ml` |
| Cutoff | `Cutoff.{always,never,phys_equal,of_equal,of_compare}` | `crux_engine.ml` |
| Endpoint ingress | `Endpoint.send`, `Endpoint.contramap`, `admission_error = Ingress_closed` | `crux_engine.ml` |
| Diagnostics | `Diagnostic.snapshot`, `Diagnostic.state_machine` | `crux_failure.ml` |
| State machine | `State_machine.create` with staged `(unit, never) Eta.Effect.t` | `crux_engine.ml` |
| Lifecycle | `lifecycle` | `crux_engine.ml` |
| Keyed children | `Assoc(Order).assoc` | `crux_engine.ml` via `Eta_signal_map` |
| Sources | `Source.create`, producer/emit/terminal types | `crux_source.ml` |
| Codecs | `Codec.make/encode/decode` | `crux_boundary.ml` |
| Exported endpoints | `Exported_endpoint.create/try_invoke/remote_handle` | `crux_boundary.ml` |
| Request path | `Host_operation`, `Request`, `Requester`, `Responder`, `Request_export` | `crux_boundary.ml` |
| Failure boundary | `Failure` records, portable encode/decode | `crux_failure.ml`, `crux_portable_failure.ml` |
| Root advancement | `Root.create/advance/request_stop`, `Post_commit.start` | `crux_root.ml` |
| Driver shell | `Driver` identity and serialized bindings, poll/await, delivery tokens | `crux_driver.ml`, `crux_driver_base.ml`, `crux_driver_serialized.ml` |
| Host adapter | `Adapter.resource`, `Hosted.run`, `Hosted.Control` | `crux_host.ml` |
| Wire protocol types | `Wire.Frame`, `Wire.FORMAT`, `Serialized_session` | `crux_wire.ml` |
| Telemetry | fixed logs/metrics/spans | `crux_telemetry.ml` and `verification.md` lines 215-250 |

### `Eta_crux_test` public families

Source: `lib/crux_test/eta_crux_test.mli`.

| Family | Modules | Implementation path |
|---|---|---|
| Incoming injection map | `Incoming.create`, `Incoming.none` | `crux_test_handle.ml` |
| Test shell callbacks | `Test_shell.t` | `crux_test_handle.ml` |
| Production-driver handle | `Handle.create/use/frame/drain/inject/poll/await/stop/...` | `crux_test_handle.ml` |
| Controlled source producer | `Controlled_source` | `crux_controlled_source.ml` |
| Recording adapter | `Recording_adapter` | `crux_recording_adapter.ml` |

### Explicit V1 exclusions

Source: `docs/design/eta-crux-v1/README.md` lines 86-94.

Excluded:

- renderer, widget model
- command algebra, subscription algebra
- fragment tree
- typed observation plan
- middleware chain
- graph inspection
- action history, replay
- compatibility protocol
- detached work, retained inactive child
- unbounded capacity, default timeout
- streaming request
- protocol negotiation
- transport selected by application code

Also: no PPX package and no concrete host-adapter package (`README.md` lines 58-60).

## Verification surface

Law registry: `docs/design/eta-crux-v1/semantic-laws.md`.

Executable groups from `docs/design/eta-crux-v1/verification.md` lines 10-17 and present tests:

| Group | Path | Named examples present in tree |
|---|---|---|
| unit | `test/crux/unit/test_eta_crux_core.ml`, `test_eta_crux_test_surface.ml` | `test_description_is_inert`, `test_transition_effect_is_staged`, `test_snapshot_only_observation`, many others |
| laws | `test/crux/laws/test_eta_crux_laws.ml` | `qcheck_ingress_fifo_admission`, `qcheck_request_first_resolution`, `qcheck_bounded_drain`, wire qchecks |
| races | `test/crux/races/test_eta_crux_races.ml` | `race_ingress_close_vs_send_both_winners`, `race_session_replacement`, others |
| conformance | `test/crux/conformance/test_eta_crux_conformance.ml` | `conformance_identity_zero_wire`, `conformance_identity_serialized_equivalence` |
| wire | `test/crux/wire/` | JSON/S-exp round trip and crypto helpers |
| telemetry | `test/crux/telemetry/test_eta_crux_telemetry.ml` | `test_telemetry_contract`, `conformance_disabled_telemetry` |
| negative compile | `test/crux/negative/` via `test/crux/dune` alias `runtest` | `staged_effect_rejects_typed_error`, `admission_must_be_handled`, `root_is_not_description` |
| bench | `lib/crux/bench/bench_eta_crux.ml` | performance rows in `verification.md` lines 282-293 |

## The nine reported gaps

The nine reported claims are the open decision tickets
`docs/wayfinder/eta-crux-capability-audit/issues/09` through `17`.

### Gap 1 — Graph time and deterministic clock control

**Ticket:** `issues/09-graph-time-and-deterministic-clock-control.md`
**Claim:** The graph has no clock. Deadlines cannot wake the driver. The test handle cannot advance time.

| Check | Evidence | Result |
|---|---|---|
| Public clock API | No clock, time, or deadline symbol in `lib/crux/eta_crux.mli` | Absent |
| Driver wake sources | `Driver.poll` / `await` in `eta_crux.mli` lines 648-649. Wake paths are ingress, request, and terminal queues in `crux_root.ml` and `crux_driver.ml` | No deadline wake |
| Test time control on Crux handle | `eta_crux_test.mli` `Handle` has no `advance_time` or clock API | Absent |
| Eta test clock usage | Many tests call `Eta_test.with_test_clock` in `test/crux/**` | Eta runtime clock only |

**Claim correctness:** Correct.
**Classification:** `missing`.
No graph-owned clock exists. This also matches the no-default-timeout exclusion (`README.md` lines 92-93).
**Notes:** Tests can control Eta fiber time through `Eta_test`. That control is not an Eta Crux graph input and does not schedule Crux advancement by deadline.

### Gap 2 — External graph input

**Ticket:** `issues/10-external-graph-input.md`
**Claim:** Changing host state must become an action or a closure-captured construction argument.

| Check | Evidence | Result |
|---|---|---|
| Root construction | `Root.create ~ingress_capacity ~request_capacity description` (`eta_crux.mli` lines 577-581, `public-api.md` lines 437-441) | No external input parameter |
| Live input update API | No `set_input`, Var, or host-input module in public mli | Absent |
| Existing update path | `Endpoint.send` and state-machine actions. Description values are closed over at construction | Actions and closures only |
| Law | O-01: complete committed root output is the only application observation | Observation is output, not external input |

**Claim correctness:** Correct.
**Classification:** `application-composable`.
Host state enters through actions or construction closures. There is no first-class external graph-input API.

### Gap 3 — Startup facts and flags

**Ticket:** `issues/11-startup-facts-and-flags.md`
**Claim:** There is no distinct startup-facts or flags concept.

| Check | Evidence | Result |
|---|---|---|
| Flags/startup API | No `Flags`, `Startup`, or init-facts module in `eta_crux.mli` | Absent |
| Construction inputs | Ordinary OCaml values closed into `'a Eta_crux.t` before `Root.create` | Ordinary construction |
| Exclusion text | No separate exclusion name for flags. Closest related exclusion is absence of typed observation and renderer packages | Not named as flags |

**Claim correctness:** Correct.
**Classification:** `application-composable`. Startup data is ordinary construction input, not a first-class Crux contract.

### Gap 4 — Staged-effect observability

**Ticket:** `issues/12-staged-effect-observability.md`
**Claim:** Direct observation of staged transition effects is limited. Opaque Eta effects are the default. Command algebra is absent.

| Check | Evidence | Result |
|---|---|---|
| Staged effect type | `State_machine.create` returns `'model * (unit, never) Eta.Effect.t` (`eta_crux.mli` lines 56-61) | Opaque effect |
| No command algebra | README exclusion lines 88-90. Map note that effects stay opaque by default | Excluded |
| Staging laws | A-06, A-07, A-08, T-05, T-07, T-09 in `semantic-laws.md` | Behavioral laws exist |
| Staging test without inspection | `test_transition_effect_is_staged` in `test/crux/unit/test_eta_crux_core.ml` lines 102-120 | Side-effect counters around `Post_commit.start` |
| Controlled deps | `Controlled_source`, `Recording_adapter`, `Eta_test.Controlled` via verification.md lines 212-213 and law H-05 | Dependency control, not staged-effect inventory |

**Claim correctness:** Correct.
**Classification:** `partial`.
Callers can assert some staging facts through opaque effects, post-commit fences, and controlled dependencies.
There is no public inventory of staged effects, ordered start events, or command algebra.

### Gap 5 — Host-owned streaming operations

**Ticket:** `issues/13-host-owned-streaming-operations.md`
**Claim:** Host operations do not resolve many times. Streaming requests are out of V1.

| Check | Evidence | Result |
|---|---|---|
| Request cardinality | Law R-01: at most one resolution. Later resolve returns `Not_pending` | One-shot |
| Public resolve API | `Responder.resolve` (`eta_crux.mli` lines 320-323) | One response |
| Streaming exclusion | README lines 92-94: no streaming request | Explicit exclusion |
| Multi-item path | `Source` emits many items as ordinary actions (S-04, S-05) | Source, not host-op stream |
| Composition | Host adapter can feed a `Source` producer or inject actions | Application composition |

**Claim correctness:** Correct.
**Classification:** `deliberately excluded`.
Multi-item flows remain possible through `Source` plus adapter-owned producers. That path is not a streaming host-operation API.

### Gap 6 — Ingress admission classes

**Ticket:** `issues/14-ingress-admission-classes.md`
**Claim:** Ingress is root-wide bounded FIFO without admission classes or isolation policies.

| Check | Evidence | Result |
|---|---|---|
| Capacity shape | `Root.create ~ingress_capacity ~request_capacity` only. Law A-09 | Two positive capacities |
| FIFO law | A-02 `qcheck_ingress_fifo_admission` | Root-wide FIFO for waiting sends |
| Admission error | `Endpoint.admission_error = Ingress_closed` only | No drop/slide/coalesce result |
| Export nonblocking | `Exported_endpoint.try_result` can be `Full` (`eta_crux.mli` lines 120-122) | Capacity full, not a class policy |
| No class API | No reserved capacity, priority, coalesce, or per-endpoint public capacity API | Absent |
| Internal dropping wakes | `crux_root.ml` uses dropping capacity-1 wake queues | Internal scheduling, not application ingress policy |

**Claim correctness:** Correct for application ingress.
**Classification:** `partial`.
Root-wide FIFO and explicit capacities exist. Explicit admission classes, guaranteed reserved capacity, sliding/dropping application ingress, and coalesce policies do not.

### Gap 7 — Pull observation of root output

**Ticket:** `issues/15-pull-observation-of-root-output.md`
**Claim:** Hosts receive pushed delivery. Safe pull of latest committed output is not a public production API.

| Check | Evidence | Result |
|---|---|---|
| Production observation law | O-01, O-02: complete output delivered after commit through driver/adapter | Push delivery |
| Production pull API | No public `Driver.last_output` or `Root.current_output` in `eta_crux.mli` | Absent |
| Private driver cache | `crux_driver_base.ml` field `last_output`, set on commit in `crux_driver.ml` line 515 | Private only |
| Test pull | `Handle.last_output` (`eta_crux_test.mli` line 71) | Present in test package |
| Test pull semantics | `crux_test_handle.ml` lines 139-142 set output only after successful shell `deliver` and `Delivery.delivered` Ok | Latest successfully delivered output, not raw commit |

**Claim correctness:** Correct for production pull of committed output.
**Classification:** `partial`.
Test handle exposes latest delivered output. Production surface is push delivery. Private driver state is not a public pull contract.

**Contradiction:** Internal driver stores committed output before delivery completion (`crux_driver.ml` line 515). Test `last_output` stores output only after delivery success. These are different pull points. Public docs do not expose either as a production pull API.

### Gap 8 — Host-operation layers

**Ticket:** `issues/16-host-operation-layers.md`
**Claim:** `Request.Driver_event.handle` and `Different_operation` form a chain primitive. There is no separate middleware-layer abstraction.

| Check | Evidence | Result |
|---|---|---|
| Handle primitive | `Request.Driver_event.handle` returns `Handled \| Different_operation` (`eta_crux.mli` lines 273-289) | Present |
| Dispatch helper | `Driver_event.dispatch` with polymorphic handler (`eta_crux.mli` lines 261-277) | Present |
| Middleware module | No `Middleware`, `Layer`, or interceptor module in public mli | Absent |
| Exclusion | README line 89: no middleware chain | Explicit exclusion |

**Claim correctness:** Correct.
**Classification:** `application-composable`.
Hosts can write sequential `handle` chains. A first-class middleware-chain product feature is deliberately excluded.

### Gap 9 — Action history and diagnostics

**Ticket:** `issues/17-action-history-and-diagnostics.md`
**Claim:** No bounded action history or replay. Diagnostics are limited to failure snapshots and fixed telemetry.

| Check | Evidence | Result |
|---|---|---|
| History exclusion | README lines 88-90 and first-principles ticket 20 answer lines 39-41 | No action history, replay, graph inspection, time travel |
| Optional crash diagnostics | `State_machine.create ?diagnostics` and `Failure.record` snapshot fields (`eta_crux.mli` lines 50-62, 194-202) | Failure-time snapshots only |
| Telemetry | Fixed logs/metrics/spans in `verification.md` lines 215-250 and laws O-03, O-04 | No payload history |
| Test history API | No action-log module in `eta_crux_test.mli` | Absent |

**Claim correctness:** Correct.
**Classification:** `deliberately excluded`.
Action history, replay, graph inspection, and time travel are out of V1.
Optional fatal snapshots and fixed telemetry give partial diagnostics only.

## Contradictions and tensions

1. **Committed vs delivered pull**
   Driver private `last_output` updates on commit (`crux_driver.ml:515`).
   Test `Handle.last_output` updates after successful delivery ack (`crux_test_handle.ml:139-142`).
   Law O-01 names committed output as the application observation boundary, while production delivery is still push-only.

2. **First-principles ticket 20 vs public Driver API**
   Ticket 20 text mentions `Driver.replace_serialized_session` as a driver operation.
   Public `eta_crux.mli` exposes session replacement through `Serialized_session.replace` with an admin handle from `Driver.Binding.serialized`, not a `Driver.replace_serialized_session` value.
   Implementation uses `Serialized_session.replace` from driver internals (`crux_driver.ml` around line 276).
   The design ticket prose is stale relative to the public API.

3. **Exclusion list vs present multi-item sources**
   README excludes "subscription algebra" and "streaming request".
   `Source` still provides long-lived multi-item emission into actions.
   These are different concepts. The exclusion is not a claim that multi-item input is impossible.

4. **Ingress dropping language in implementation**
   Application ingress is a bounded queue with close/full semantics.
   Internal wake queues are dropping (`crux_root.ml`).
   Export paths treat unexpected `Dropped` as a defect/invalid state in `crux_boundary.ml`.
   Design laws describe FIFO admission and capacity bounds, not application-level drop policies.

5. **Public API docs vs wrapped library modules**
   `public-api.md` and `eta_crux.mli` match the exported module set closely.
   Optional packages `eta_crux_json` and `eta_crux_sexp` implement `Wire.FORMAT` without separate `.mli` files in tree.
   That is a packaging style fact, not a behavior contradiction.

6. **Eta test clock vs Crux graph time**
   Tests often use `Eta_test.with_test_clock`.
   That clock serves the Eta runtime used under Crux.
   It is not evidence of a Crux graph clock API.

## Capability inventory not named by the nine gaps

These current families are outside the nine reported gap tickets:

### Production (`eta_crux`)

1. Computation graph: `return`, `map`, `both`, `bind`, `cutoff`, `Syntax`
2. Local state machines with staged infallible effects
3. Endpoint send, contramap, stale rejection
4. Lifecycle programs
5. Keyed `Assoc` children and data cutoffs
6. Source producers with spec cutoff and terminal actions
7. Codec values
8. Exported endpoints and remote handles
9. Host operations, requesters, responders, request exports
10. Failure packing, portable failure codec, diagnostic snapshots on crash
11. Root create/advance/stop and post-commit fence
12. Driver identity binding and serialized binding
13. Delivery tokens and request driver events
14. Adapter resource and hosted run loop
15. Wire frames, protocol errors, serialized session replace/close
16. Fixed observability telemetry

### Test (`eta_crux_test`)

1. Incoming endpoint injection helper
2. Test shell callback bundle
3. Handle frame/drain/inject/poll/await/stop and delivery answers
4. `last_output` of latest successfully delivered output
5. Controlled source incarnation control
6. Recording adapter with acquire/release/delivery/request/crash controls

### Adjacent packages

1. `eta_crux_json` exact JSON envelope format
2. `eta_crux_sexp` exact S-expression envelope format
3. Bench executable rows under `lib/crux/bench/`

## Baseline summary

| Gap ticket | Claim correct? | Classification |
|---|---|---|
| 09 Graph time | Yes | `missing` |
| 10 External graph input | Yes | `application-composable` |
| 11 Startup facts and flags | Yes | `application-composable` |
| 12 Staged-effect observability | Yes | `partial` |
| 13 Host-owned streaming ops | Yes | `deliberately excluded` |
| 14 Ingress admission classes | Yes | `partial` |
| 15 Pull observation | Yes | `partial` |
| 16 Host-operation layers | Yes | `application-composable` |
| 17 Action history and diagnostics | Yes | `deliberately excluded` |

No gap claim is `incorrect`.

Current Eta Crux is a graph-neutral computation and shell-protocol library.
It owns structure, advancement, typed output, requests, exports, failure, and wire equivalence.
It does not own clocks, flags, command algebras, middleware products, action history, or streaming host operations.

## Uncertainty

1. No separate consumer or historical census was required for this ticket. Consumer pressure can change the importance of a gap. It does not change the present-state classifications above.
2. Private driver fields and internal wake queues are implementation detail. If they become public, Gap 7 or Gap 6 changes. Current public contracts do not expose them.
3. Optional JSON/S-exp packages have no `.mli` in tree. Their public OCaml surface is the compiled module interface from the `.ml` files.
4. This report did not run the full test suite. Named tests and files were inspected as present source. Pass/fail status of each gate was not re-executed.

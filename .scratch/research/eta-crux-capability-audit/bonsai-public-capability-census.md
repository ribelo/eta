# Bonsai public capability census

## Scope and method

This report inventories public architectural capabilities, not every public function.
It reviews all public libraries in the Bonsai and Bonsai test repositories.

The source snapshot uses these immutable commits:

- Bonsai commit [`f31661450eb133fe89564219d97669c2735c6622`](https://github.com/janestreet/bonsai/commit/f31661450eb133fe89564219d97669c2735c6622).
- Bonsai test commit [`6aac39071101dcd32c96564163cfcf66cc3b95bb`](https://github.com/janestreet/bonsai_test/commit/6aac39071101dcd32c96564163cfcf66cc3b95bb).

The census treats `Bonsai.Cont` as the supported core API.
The public entry point identifies `Cont` as the recommended API.
It describes `Proc` and `Bonsai_arrow_deprecated` as older iterations.
Therefore, those interfaces do not create duplicate capability families.
See [`bonsai.mli`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/bonsai.mli#L1-L12).

The official overview calls Bonsai a general-purpose library for incremental, composable state machines.
It identifies `bonsai_test` as the matching test library.
See the [Bonsai overview](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/README.md#L145-L162).

The overview also documents functional state, incremental recomputation, lifecycle scope, and whole-application tests.
See the [architecture summary](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/README.md#L52-L87).

The classifications are research evidence only.
They do not decide adoption, deferral, or rejection.

## Classification key

- **plausible generic Eta Crux role**: The family can support a framework-neutral application capability.
- **design evidence only**: The family gives useful laws or test patterns, but does not clearly belong in Eta Crux.
- **Bonsai-specific**: The contract depends on Bonsai graph identity, frames, tooling, or compatibility surfaces.

## Census summary

The census contains 21 capability families.

| Number | Capability family | Research classification |
|---:|---|---|
| 1 | Reactive graph values and composition | plausible generic Eta Crux role |
| 2 | External inputs and host variables | plausible generic Eta Crux role |
| 3 | State, state machines, and actors | plausible generic Eta Crux role |
| 4 | Model scope, reset, and value history | plausible generic Eta Crux role |
| 5 | Dynamic, lazy, and recursive structure | plausible generic Eta Crux role |
| 6 | Dynamic context | plausible generic Eta Crux role |
| 7 | Time | plausible generic Eta Crux role |
| 8 | Lifecycle hooks | plausible generic Eta Crux role |
| 9 | Edge-triggered operations and polling | plausible generic Eta Crux role |
| 10 | Effects, graph sampling, and scheduling | plausible generic Eta Crux role |
| 11 | Effect concurrency and coordination | plausible generic Eta Crux role |
| 12 | Shared keyed computations | design evidence only |
| 13 | Incremental integration | design evidence only |
| 14 | Graph paths and stable identity | Bonsai-specific |
| 15 | Host runtime integration | plausible generic Eta Crux role |
| 16 | Debugging and introspection protocols | design evidence only |
| 17 | Bidirectional state synchronization and stability | plausible generic Eta Crux role |
| 18 | Deterministic test driving | plausible generic Eta Crux role |
| 19 | Test observation and snapshots | plausible generic Eta Crux role |
| 20 | Test effects and input isolation | plausible generic Eta Crux role |
| 21 | Computation and performance reports | design evidence only |

## Public support package disposition

Some public libraries refine these 21 families.
They do not add independent architectural capability families.

- `bonsai.ppx_bonsai`, `bonsai.proc`, and `bonsai.arrow_deprecated` supply syntax or older graph APIs.
  Their semantics belong to reactive composition and dynamic structure.
- `bonsai.kernel_components.*` supplies state, selection, effect, identifier, mirror, pipe, throttle, and stability helpers.
  These helpers refine families 3, 4, 9, 11, and 17.
- `bonsai.balance_list_tree` balances a list into bounded child lists.
  This data-structure utility does not define a runtime capability.
- `bonsai.trampoline` prevents JavaScript stack overflow without tail-call optimization.
  This portability utility does not define an application capability.
- `bonsai.bench_scenario` defines controlled input, action, clock, reset, and profile interactions.
  These operations belong to families 18 and 21.
- `bonsai_test.computation_report` is family 21.
  `bonsai_test.dot` exposes a command, not a test capability.
- `bonsai_test.of_bonsai_itself` and `bonsai_test.shared_for_testing_bonsai` support Bonsai's own tests.
  They do not extend the `bonsai_test` user contract.
- Libraries named `private_base` and `private_gather` expose implementation support.
  The public entry point places their modules under `Bonsai.Private`.

The selection helper preserves a valid selected item or applies a caller policy.
This contract is a domain specialization of state machines, not a new architectural family.

Sources include the [`ppx_bonsai` entry point](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/ppx_bonsai/src/ppx_bonsai.mli#L1),
[`Selection_state`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bonsai_kernel_components/selection_list/bonsai_kernel_selection_state.mli#L3-L133),
and [`Balance_list_tree`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/balance_list_tree/src/balance_list_tree.mli#L3-L15).
See also [`Trampoline`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/trampoline/src/trampoline.mli#L1-L56)
and [`Bonsai_bench_scenario`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bench_scenario/bonsai_bench_scenario.mli#L3-L96).

## Core and host capability details

### 1. Reactive graph values and composition

- **Purpose:** A `'a Bonsai.t` presents a value that can change over time.
- **Contract:** Applicative dependencies recompute incrementally.
  `cutoff` suppresses propagation when its equality function reports no change.
- **Test control:** A test handle stabilizes the graph and exposes its latest result.
- **Ownership:** Bonsai owns dependency tracking and recomputation.
  User functions remain pure unless they return an effect.
- **Classification:** **plausible generic Eta Crux role**.
  Reactive derived values can support framework-neutral application logic.
- **Sources:** [`Cont.t`, applicative composition, and `cutoff`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L6-L114).

### 2. External inputs and host variables

- **Purpose:** `Expert.Var` lets code outside a Bonsai graph create, read, and change a graph input.
- **Contract:** `value` gives read-only graph access.
  `set` and `update` change the source value.
- **Test control:** Tests can change variables directly.
  The test library also supplies opaque constants that prevent constant folding.
- **Ownership:** The host owns writes.
  Bonsai owns propagation after each write.
- **Classification:** **plausible generic Eta Crux role**.
  An explicit host-to-graph input has a generic boundary role.
- **Sources:** [`Expert.Var`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1302-L1330) and [`opaque_const`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/import.mli#L15-L18).

### 3. State, state machines, and actors

- **Purpose:** State helpers store models.
  State machines apply typed actions.
  Actors also return typed responses.
- **Contract:** Actions enter through returned effects.
  `Apply_action_context` can inject actions, schedule effects, and access application time.
  Input-aware machines receive `Active` or `Inactive` input status.
- **Test control:** Handles submit incoming actions and process queued actions during recomputation.
- **Ownership:** Bonsai owns model storage and the action queue.
  User transition functions own model semantics.
  Scheduled effects own external work.
- **Classification:** **plausible generic Eta Crux role**.
  Typed transitions and responses are framework-neutral.
- **Sources:** [`state` and toggles](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L116-L182), [`Apply_action_context` and state machines](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L184-L260), and [`actor`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L262-L373).

### 4. Model scope, reset, and value history

- **Purpose:** These operations bind state to keys, reset nested models, freeze values, or retain prior values.
- **Contract:** `scope_model` selects model state with a key.
  A model resetter resets all nested stateful components.
  `previous_value` reports the prior frame.
- **Test control:** A driver can reset the whole model.
  Frame recomputation exposes history changes deterministically.
- **Ownership:** Bonsai owns scoped model storage and reset traversal.
  The caller chooses keys, equality, and reset behavior.
- **Classification:** **plausible generic Eta Crux role**.
  Scoped state and explicit reset can support generic state ownership.
- **Sources:** [`freeze`, `scope_model`, and value history](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L376-L462) and [`with_model_resetter`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L529-L564).

### 5. Dynamic, lazy, and recursive structure

- **Purpose:** Applications can select branches, create keyed component instances, defer graph construction, and define recursive components.
- **Contract:** `assoc` retains one state machine per key.
  `delay` calls its constructor at most once when needed.
  `fix` supplies controlled recursion.
- **Test control:** Input changes select branches and key sets.
  A handle then stabilizes the resulting graph.
- **Ownership:** Bonsai owns activation, deactivation, and keyed model retention.
  The application owns keys and branch selection.
- **Classification:** **plausible generic Eta Crux role**.
  Dynamic keyed state can support generic application collections.
- **Sources:** [`fix` and `enum`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L386-L406), [`assoc` families](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1010-L1087), and [`delay`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1261-L1278).

### 6. Dynamic context

- **Purpose:** `Dynamic_scope` supplies implicit values to descendants without threading each value through every function.
- **Contract:** Lookup selects the nearest active setter.
  It uses the declared fallback when no setter exists.
  Revert restores the outer scope.
- **Test control:** Tests select graph branches and inspect values from each scope.
- **Ownership:** Bonsai owns lexical activation and restoration.
  The application owns variable identity and values.
- **Classification:** **plausible generic Eta Crux role**.
  Scoped environment values can support generic dependency context.
- **Sources:** [`Dynamic_scope`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L872-L982).

### 7. Time

- **Purpose:** Clock operations expose approximate time, deadline state, intervals, current-time effects, sleep, and sleep-until.
- **Contract:** `every` defines four overlap and interval policies.
  Time reads use the application time source.
- **Test control:** Handles expose the time source.
  They can advance it by a span or to a timestamp.
- **Ownership:** The driver owns the time source.
  Bonsai owns timer registration and interval scheduling.
  The caller owns each scheduled effect.
- **Classification:** **plausible generic Eta Crux role**.
  Controlled application time has a generic deterministic role.
- **Sources:** [`Clock`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L580-L640) and [test clock controls](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L114-L126).

### 8. Lifecycle hooks

- **Purpose:** Lifecycle hooks observe activation, deactivation, and frame boundaries.
- **Contract:** Hooks run in this order: before display, deactivation, activation, and after display.
  Each before-display effect runs at most once per frame.
- **Test control:** Recomputing a handle triggers lifecycle events.
  Tests can inspect pending after-display events.
- **Ownership:** Bonsai owns hook registration and order.
  Application effects own acquisition or cleanup behavior.
- **Classification:** **plausible generic Eta Crux role**.
  Activation and cleanup boundaries can support generic scoped behavior.
- **Sources:** [`Edge.lifecycle`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L677-L740) and [driver lifecycle order](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L17-L48).

### 9. Edge-triggered operations and polling

- **Purpose:** Edge operations run effects after value changes or manual refresh requests.
- **Contract:** `on_change` runs on activation and at most once per frame.
  It uses the latest value.
  Poll results from later requests win after out-of-order completion.
- **Test control:** Tests change inputs, recompute frames, and inspect pending lifecycle work.
- **Ownership:** Bonsai owns change detection, coalescing, and stale-result suppression.
  The application owns effect bodies.
- **Classification:** **plausible generic Eta Crux role**.
  Latest-request-wins and change-triggered work are generic operation policies.
- **Sources:** [`Edge.on_change`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L642-L675) and [`Edge.Poll`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L742-L780).

### 10. Effects, graph sampling, and scheduling

- **Purpose:** `Ui_effect` values describe work.
  Graph APIs inject actions, schedule events, sample current values, and wait for frame boundaries.
- **Contract:** `peek` reports inactive computations explicitly.
  Action-context scheduling adds effects to Bonsai processing.
- **Test control:** Drivers schedule effects and flush their pending actions.
- **Ownership:** The runtime owns effect dispatch and action scheduling.
  The application owns effect definitions and external side effects.
- **Classification:** **plausible generic Eta Crux role**.
  Opaque effects and controlled graph sampling can support generic commands.
- **Sources:** [`peek`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L566-L578), [`Effect` and frame waits](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L714-L740), and [`Driver.schedule_event`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L39-L40).

### 11. Effect concurrency and coordination

- **Purpose:** Bonsai supplies queued pipes, exactly-once startup, throttling, serialization, and one-at-a-time guards.
- **Contract:** Core throttling retains at most one running request and one queued request.
  `One_at_a_time` returns `Busy` instead of starting concurrent work.
- **Test control:** Test effects and handles can start work, flush actions, and inspect returned status.
- **Ownership:** Bonsai owns admission and queue state.
  Effect implementations own completion.
  Some coordinators stop after an effect raises.
- **Classification:** **plausible generic Eta Crux role**.
  Admission and ordering policies can support generic host operations.
- **Sources:** [`Effect_throttling`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L829-L870) and [`pipe`, exactly-once, and `One_at_a_time`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bonsai_kernel_components/proc/bonsai_extra_proc.mli#L33-L52).
  See also [`One_at_a_time` and chained effects](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bonsai_kernel_components/proc/bonsai_extra_proc.mli#L225-L265).

### 12. Shared keyed computations

- **Purpose:** `Memo` shares a stateful computation among callers for each query key.
- **Contract:** Instances activate on first lookup.
  Reference counts deactivate an instance after its last caller deactivates.
  A first lookup briefly returns `None`.
- **Test control:** Tests create and remove callers, then inspect results or subscriber paths.
- **Ownership:** Bonsai owns instance creation, reference counts, and deactivation.
  The application owns the keyed computation.
- **Classification:** **design evidence only**.
  The family depends on Bonsai dynamic graph activation.
  Its reference-count law remains useful evidence.
- **Sources:** [`Memo`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L783-L827) and [`Debug.memo_subscribers`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1175-L1176).

### 13. Incremental integration

- **Purpose:** `Bonsai.Incr` imports lower-level Incremental computations and clock-derived incremental values.
- **Contract:** `compute` maps an Incremental node inside the Bonsai graph.
  `value_cutoff` controls lower-level propagation.
- **Test control:** Test handles expose result and lifecycle Incremental nodes for advanced inspection.
- **Ownership:** Incremental owns node stabilization.
  Bonsai owns graph activation and the public value wrapper.
- **Classification:** **design evidence only**.
  Incremental is Bonsai substrate support, not a separate Eta Crux application capability.
- **Sources:** [`Bonsai.Incr`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L984-L1008) and [advanced test Incremental access](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L133-L139).

### 14. Graph paths and stable identity

- **Purpose:** `Path` records a route through the Bonsai graph and produces reproducible identifiers.
- **Contract:** Each `Bonsai.path` call gives a distinct path.
  String uniqueness requires distinct serialized association keys.
- **Test control:** Tests can observe identifiers after branch and key changes.
- **Ownership:** Bonsai owns path construction.
  Applications own key serializers and any external identifier use.
- **Classification:** **Bonsai-specific**.
  The identity contract encodes Bonsai graph topology and association keys.
- **Sources:** [`Path`, `path`, and `path_id`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1179-L1205).

### 15. Host runtime integration

- **Purpose:** `Bonsai_driver` embeds a graph in a host loop.
  It exposes flush, result, lifecycle, event, time, and shutdown controls.
- **Contract:** The documented loop flushes actions, reads the result, then triggers lifecycles.
  Flush stabilizes between actions.
- **Test control:** `bonsai_test` wraps the same controls with inputs and view helpers.
- **Ownership:** The host owns loop cadence and the time source.
  The driver owns observers, action queues, and lifecycle execution.
- **Classification:** **plausible generic Eta Crux role**.
  Explicit push, pull, time, and shutdown boundaries are generic host concerns.
- **Sources:** [`Bonsai_driver`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L5-L90) and [`bonsai_test.Driver`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/driver.mli#L4-L38).

### 16. Debugging and introspection protocols

- **Purpose:** Debug APIs log changes, watch dependencies, export graph structure, count nodes, and describe profiler events.
- **Contract:** Computation watchers are inert until external tools enable them.
  Stable protocol versions convert older messages to the latest form.
- **Test control:** Handles print actions, stabilizations, tracker statistics, and computation structure.
- **Ownership:** Bonsai owns graph metadata and instrumentation.
  External developer tools own transport and display.
- **Classification:** **design evidence only**.
  The observation points are useful.
  Their graph schema, browser storage event, and RPC protocol are tooling-specific.
- **Sources:** [`Debug`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1091-L1177), [`Bonsai_bug_protocol`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/introspection_protocol/bonsai_bug_protocol.mli#L1-L92), and [`bonsai.introspection_protocol`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/introspection_protocol/bonsai_introspection_protocol.mli#L1-L10).

### 17. Bidirectional state synchronization and stability

- **Purpose:** `bonsai.extra` mirrors two stores and reports recent value stability.
- **Contract:** The store wins the initial mirror conflict.
  The interactive value wins later simultaneous changes.
  Stability uses a caller-supplied duration and equality.
- **Test control:** Tests change either side, advance the clock, and recompute.
- **Ownership:** Bonsai owns conflict order and stability state.
  Applications own setters, persistence, equality, and duration.
- **Classification:** **plausible generic Eta Crux role**.
  Synchronization and conflict policy can support generic host-backed state.
- **Sources:** [`mirror`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bonsai_kernel_components/proc/bonsai_extra_proc.mli#L153-L191) and [stability operations](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/bonsai_kernel_components/proc/bonsai_extra_proc.mli#L193-L223).

## Bonsai test capability details

### 18. Deterministic test driving

- **Purpose:** `Handle` runs Bonsai computations without an application host.
  Tests send actions, advance time, and request frames.
- **Contract:** `recompute_view` flushes time, processes each action with stabilization, stabilizes again, then triggers lifecycles.
  Stable recomputation stops after no pending after-display event.
- **Test control:** `create`, `do_actions`, `advance_clock`, `recompute_view`, and `recompute_view_until_stable` are direct controls.
- **Ownership:** The handle owns the test driver, action queue, frame loop, and test clock.
  The test owns each stimulus.
- **Classification:** **plausible generic Eta Crux role**.
  Deterministic action, frame, and clock control are generic test needs.
- **Sources:** [`Handle.recompute_view` and stable recomputation](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L50-L112) and [`Handle` controls](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L114-L140).

### 19. Test observation and snapshots

- **Purpose:** `Result_spec` maps outputs to printable views and typed incoming actions.
  Handles show full views, diffs, models, and raw results.
- **Contract:** `show_diff` compares against the last stored or shown view.
  A simulated patch runs before lifecycle triggers.
- **Test control:** Tests choose the renderer, call `show`, store views, inspect results, or print diagnostics.
- **Ownership:** The test owns rendering and assertions.
  The handle owns snapshot history and frame placement.
- **Classification:** **plausible generic Eta Crux role**.
  Typed input and pull observation can support generic model tests.
- **Sources:** [`Result_spec`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L5-L48) and [`show`, `show_diff`, and results](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L50-L115).

### 20. Test effects and input isolation

- **Purpose:** Test helpers sequence effects, provide no-op effects, label external effects, and hide constants from optimization.
- **Contract:** `Effect.external_` records a named external effect.
  Opaque helpers preserve an input boundary during tests.
- **Test control:** Tests replace real work with these effects and set variables outside the graph.
- **Ownership:** The test owns effect interpretation and external input mutation.
  Bonsai still owns scheduling.
- **Classification:** **plausible generic Eta Crux role**.
  Named effect stubs and non-folded inputs support deterministic boundary tests.
- **Sources:** [`Bonsai_test.Effect` and opaque helpers](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/import.mli#L1-L18) and [`Bonsai_test.Var`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/bonsai_test.ml#L1-L9).

### 21. Computation and performance reports

- **Purpose:** Reports count graph nodes and Incremental work during startup or scripted interactions.
- **Contract:** Measurements report creation, recomputation, invalidation, height, identifiers, and annotation differences.
- **Test control:** Tests run computations or interaction scenarios and compare named reports.
- **Ownership:** The test runner owns measurement boundaries.
  Bonsai and Incremental own counters and graph annotations.
- **Classification:** **design evidence only**.
  These metrics reveal test patterns, but their exact counters depend on Bonsai and Incremental internals.
- **Sources:** [`Incr_report`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/computation_report.mli#L4-L31), [`Startup`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/computation_report.mli#L33-L59), and [`Interaction`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/computation_report.mli#L61-L100).

## Resource boundary finding

The reviewed public core has no separate scoped-resource acquisition family.
Lifecycle hooks can start and stop application effects.
However, their contract does not specify acquisition, finalizer guarantees, or cancellation safety.

`Memo` owns reference-counted activation for shared graph computations.
It does not expose a general external-resource bracket.
Therefore, Bonsai supplies resource-lifecycle evidence, not a complete generic resource contract.

## Coverage and residual uncertainty

The census covers each supported `Bonsai.Cont` section and each public `bonsai.extra` architectural group.
It also covers the public driver, introspection protocol, and `bonsai_test` interfaces.

The census excludes web widgets, DOM rendering, RPC implementations, and terminal components.
Those packages specialize Bonsai for a host or product domain.
This ticket asks for Bonsai and Bonsai test tools, not the full Bonsai ecosystem.

The public source uses `Ui_effect`, `Ui_incr`, and `Time_source` from companion packages.
This report records their semantics only when a Bonsai API gives them a public capability contract.

Some effect failure rules remain implicit in `Ui_effect`.
For example, core comments state that effects do not generally support cancellation.
This report does not infer broader failure or cancellation laws from that statement.

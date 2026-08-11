# Reference evidence: action history and diagnostics

Date: 2026-08-11
Ticket:
[`docs/wayfinder/eta-crux-capability-audit/issues/17-action-history-and-diagnostics.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/17-action-history-and-diagnostics.md)
Orientation: the broad censuses in this directory
([bonsai](bonsai-public-capability-census.md),
[rust-crux](rust-crux-public-capability-census.md),
[elm](elm-public-capability-census.md)) inventory whole capability families.
This report supplies focused evidence on one question: does any reference
retain actions, messages, models, effects, or graph events for diagnosis?

## Scope and method

I reviewed four references with current primary sources.

| Reference | Role | Pin |
|---|---|---|
| Bonsai | Production and development library | `f31661450eb133fe89564219d97669c2735c6622` |
| `bonsai_test` | Test library | `6aac39071101dcd32c96564163cfcf66cc3b95bb` |
| Rust Crux | Production and development library | `9ca03f3545c7b695be0d1e49d1bda925c43f04e2` |
| elm/core | Production runtime and debug module | `84f38891468e8e153fc85a9b63bdafd81b24664e` |
| elm/browser 1.0.2 | Production runtime and the Elm 0.19 debugger | `53e3caa265fd9da3ec9880d47bb95eed6fe24ee6` |
| elm/compiler (master docs) | Official 0.19 documents | `1bd5b36915a38335195ca7792fe3995f53d84d5e` |
| elm/compiler 0.19.0 tag | Current compiler and CLI source | `32059a289d27e303fa1665e9ada0a52eb688f302` |
| elm/compiler 0.18.0 tag | Prior compiler source | `eb97f2a5dd5421c708a91b71442e69d02453cc80` |
| elm-lang/elm-make 0.18.0 | Prior build tool source | `1a554833a70694ab142b9179bfac996143f68d9e` |
| elm-lang/virtual-dom 2.0.4 | Elm 0.18 debugger source | `68333d3a9b17b6e60bfba7ff064b6802d1dd2c64` |
| elm-lang.org | Official announcements | live site pages |
| avh4/elm-program-test 4.0.1 | Test library | `195131b038cab24fd3b7806930c19e40809cdd35` |

Each claim carries one of four evidence labels.

- **Documented contract** quotes or restates public documentation.
- **Source inference** reports behavior visible in the implementation.
- **Confirmed absence** reports a named capability that the source lacks.
- **Official announcement** cites elm-lang.org or the release notes.

I did not use secondary articles as evidence.
I did not run any of the reference test suites.
I did not decide whether Eta Crux adopts, defers, or rejects any capability.

## Reading the evidence

The table summarizes the answers for the decision dimensions in the ticket.

| Dimension | Bonsai | Rust Crux | Elm plain runtime | Elm debugger | elm-program-test |
|---|---|---|---|---|---|
| Retains actions or messages | no | no | no | yes, dev builds only | no |
| Retains models | one model | one model | one model | full model history | one model |
| Retains effects | no | in-flight requests only | no | no | last effect + pending effects |
| Retention bound | n/a | n/a | n/a | unbounded total, chunked at 31 (0.19) or 64 (0.18) | per-test, pending-until-resolved |
| Default or optional | optional, test-only hooks | optional, test drivers | n/a | only with `elm make --debug` | default in test |
| Crash output | test prints | assertion panics | error overlay, no history | debugger UI | failure messages with pending lists |
| Replay or time travel | no | no | no | yes | no |
| Graph inspection separate | yes | no graph | n/a | n/a | n/a |

The details follow.

## 1. Bonsai and bonsai_test

### 1.1 What code retains actions, messages, models, and graph events

Bonsai keeps one model per stateful component.
`state_machine_with_input` stores a `default_model` and applies actions to it.
The public contract does not promise any action history.
See
[`state_machine_with_input` in cont.mli](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L244-L260).

The driver keeps a queue of pending actions.
`Bonsai_driver` stores `'action Action.t Queue.t`.
`flush` dequeues one action, applies it, and discards it.
Applied actions do not remain in the driver.
See the
[driver state](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L27)
and
[action application](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L300-L337).

The stabilization tracker records which graph nodes received actions since
the last stabilization.
It stores generation timestamps, not action values.
It prunes inactive branches after 2700 generations.
This is optimization bookkeeping, not action history.
See
[`stabilization_tracker.ml`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/stabilization_tracker.ml#L62-L74)
and
[`prune_trie`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/stabilization_tracker.ml#L500-L511).

Bonsai offers single-value lookback, not history.
`previous_value` returns the value from the previous frame.
`most_recent_some` and `most_recent_value_satisfying` store one value.
These keep one past value per component.
See
[value history helpers in cont.mli](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L430-L462).

`bonsai_test` keeps one stored view for diffs.
`Handle.store_view` overwrites the stored view.
`show_diff` compares the new view with that single stored view.
There is no view history.
See
[`store_view` and `show_diff` in proc.mli](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L68-L80)
and the
[implementation](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.ml#L269-L299).

### 1.2 Default, optional, bounded, or unbounded

`Debug.watch_computation` is a no-op by default.
It must be enabled manually with external tools.
This lets production builds keep the call sites at no cost.
`log_action`, `log_model_before`, and `log_model_after` default to `false`.
See
[`watch_computation` in cont.mli](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1113-L1148)
and the
[defaults in cont.ml](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.ml#L1464-L1490).

`Driver.flush` accepts optional logging callbacks.
The callbacks run before each action application.
They run also when a stabilization is skipped.
The callbacks receive the action sexp as a lazy value.
See
[`flush` in bonsai_driver.mli](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L22-L27).

The driver prints actions only when the test enables printing.
`print_actions` and `print_stabilizations` are opt-in.
They print to standard output during the test.
See
[Expert controls in bonsai_driver.mli](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L75-L82)
and
[the print in bonsai_driver.ml](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L324).

Bonsai itself sets no bound on the pending action queue.
The queue drains during each flush.
Production code never accumulates applied actions.

### 1.3 Identity, ordering, and lifecycle

The driver applies actions in FIFO order.
Actions scheduled during application join the same queue.
Lifecycle events run after the actions in a fixed order.
The order is documented in
[`trigger_lifecycles`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L32-L37).

Bonsai does not name lifecycle stages for actions.
The sources do not define admitted, processed, or committed actions.
An action is pending in the queue, then applied, then gone.
This matches the census family 18 description.

### 1.4 Crash reports and failure output

Bonsai has no crash-report channel that carries action history.
Unhandled exceptions in effects are re-raised with a message.
See
[`on_exn` in bonsai_driver.ml](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.ml#L316-L318).

Test diagnostics are printed, not retained.
`show`, `show_diff`, and `show_model` print current state.
`print_stabilization_tracker_stats` prints counters.
None of these write to a failure archive.
See
[Handle controls in proc.mli](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/proc.mli#L128-L140).

### 1.5 Replay and time travel

Bonsai offers no replay or time travel.
The driver can re-run from a fresh handle.
`reset_model_to_default` resets the model for benchmarking.
This is not action replay.
See
[`reset_model_to_default`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/driver/bonsai_driver.mli#L70-L73).

### 1.6 Graph inspection and performance instrumentation

Graph inspection is separate from action history.
`Debug.to_dot` builds a graphviz string.
`bonsai_node_counts` counts static graph nodes.
`memo_subscribers` prints memo state.
See
[Debug module in cont.mli](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1091-L1177).

Performance instrumentation is also separate.
`bonsai_test` reports node counts and Incremental work.
`Incr_report` measures creation, recomputation, and invalidation.
`Startup` and `Interaction` run scripted scenarios.
See
[`computation_report.mli`](https://github.com/janestreet/bonsai_test/blob/6aac39071101dcd32c96564163cfcf66cc3b95bb/computation_report.mli#L4-L100).

The introspection protocol carries graph info and performance entries.
It never carries actions.
Messages are `Graph_info` or `Performance_measure`.
See
[`bonsai_bug_protocol.mli`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/introspection_protocol/bonsai_bug_protocol.mli#L4-L24).

### 1.7 Redaction, build mode, transport, and disabling

Bonsai applies no redaction to actions.
The caller supplies the sexp functions.
`sexp_of_action` and `sexp_of_model` are optional parameters.
Opaque fallbacks print opaque values.
See
[`state_machine_with_input` options](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L245-L260).

Transport is tooling policy.
The watch hooks print through the caller functions.
`debug_node` prints to stderr by default.
The external debugger owns display.
See
[`debug_node`](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1162-L1173).

Disabling is explicit.
`watch_computation` is off by default.
`enable_incremental_annotations` and `disable_incremental_annotations`
control annotation cost.
There is no build-mode switch in the core.
See
[annotation controls](https://github.com/janestreet/bonsai/blob/f31661450eb133fe89564219d97669c2735c6622/src/cont.mli#L1110-L1111).

### 1.8 Ownership: framework versus application versus tooling

Bonsai owns graph metadata and instrumentation.
External developer tools own transport and display.
Applications own sexp functions and action meaning.
This matches the census family 16 and 21 findings.

## 2. Rust Crux and its test support

### 2.1 What code retains events, models, and effects

`Core` retains one model, one app, and one root command.
The struct has three fields.
There is no event or action history field.
See
[`Core` in core/mod.rs](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/mod.rs#L24-L40).

`process_event` consumes the event.
The update function runs and returns a command.
The event value does not survive the call.
`process` drains events from commands and discards them.
See
[`process_event`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/mod.rs#L94-L112)
and
[`process`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/mod.rs#L144-L164).

Commands stream effects and events through channels.
The receiver drains with `try_iter`.
Completed work does not accumulate.
See
[command state](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L267-L268)
and
[`effects` and `events`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L459-L470).

The bridge retains unresolved effects only.
`ResolveRegistry` keys requests by `EffectId`.
Ids ascend and are never reused.
A resolved id stays unusable.
See
[`EffectId` in registry.rs](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/registry.rs#L20-L29)
and
[the registry](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/registry.rs#L33-L58).

### 2.2 Default, optional, bounded, or unbounded

Retention is optional and test-only.
`AppTester` keeps a root command across steps.
The command holds pending effects and events.
The test drains them on each update.
See
[`AppTester`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L7-L37)
and
[`collect_update`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L127-L138).

Upstream deprecates `AppTester`.
Direct command tests replace it.
Tests call `update` on the app and inspect the returned command.
See the
[deprecation note](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L27-L30).

The bridge registry grows with in-flight requests.
It shrinks when requests resolve.
Its lifetime is per application session.
No bound is documented.
This is confirmed as in-flight retention, not history.

### 2.3 Identity, ordering, and lifecycle

Crux gives requests an identity.
`EffectId(u32)` identifies one request across the FFI boundary.
The id stays valid only while the request is outstanding.
See
[registry docs](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/registry.rs#L20-L26).

Events have no recorded identity.
The `App::update` signature consumes the event.
No source assigns events an id or sequence number.

Crux defines no admitted, processed, or committed event stages.
The test `Update` type groups ready effects and events.
That grouping is per call, not a history.
See
[`Update`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L155-L164).

### 2.4 Crash reports and failure output

Crux has no crash-report channel.
There is no event log to include in a report.
Test assertions panic with descriptive messages.
`expect_one_effect` and `expect_one_event` print counts.
See
[assertion helpers](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L184-L231).

### 2.5 Replay and time travel

Crux offers no replay or time travel.
The core is deterministic by design.
Tests drive events and resolve effects directly.
No host simulator is shipped.
The official guide discusses application-built simulators.
See
[the simulation discussion](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-2/testing-effects.md#L64-L110).

The official docs state that Crux can ship test-harness blocks in the future.
This confirms the absence is deliberate, not accidental.
See
[the closing note](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-2/testing-effects.md#L108-L110).

### 2.6 Graph inspection and performance instrumentation

Crux has no graph inspection.
There is no node registry or graph snapshot.
Performance instrumentation is not part of the reviewed surface.
The middleware layer changes behavior. It does not log events.
See
[`middleware/mod.rs`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/middleware/mod.rs#L1-L22).

### 2.7 Redaction, build mode, transport, and disabling

Crux defines no redaction rules.
Effects cross the bridge through serialized formats.
The shell owns any redaction at the boundary.
No documented build-mode switch disables instrumentation.
The README marks the project as pre-1.0.
See
[the project status note](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L40-L43).

### 2.8 Ownership: framework versus application versus tooling

The core owns model storage and command execution.
The application owns event meaning and transitions.
Tests own stimuli and assertions.
The README describes tests as another shell.
See
[the testing section](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L115-L120).

## 3. Elm runtime and debug facilities

Elm 0.19 has two runtime paths.
The plain runtime keeps one model and no message history.
The debugger wraps browser programs in `elm make --debug` mode.
The debugger retains full message history and supports time travel.
The debugger lives in `elm/browser`, not in the compiler.

### 3.1 Plain runtime: one model, no message retention

The plain Elm 0.19 kernel keeps exactly one model.
`_Platform_initialize` creates `model` once.
Each message updates the model and is discarded.
See
[`_Platform_initialize` in Platform.js](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Platform.js#L15-L39).

The plain kernel keeps no message or action history.
Runtime errors call `__Debug_crash`.
The debug variant throws a detailed `Error`.
The production variant throws a hint link only.
See
[`_Debug_crash` in Debug.js](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Debug.js#L233-L293).

`Platform.worker` programs use a separate kernel path.
That path has no debugger reference.
Workers are headless programs.
See
[`Platform.worker`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform.elm#L65-L72)
and
[`_Platform_worker`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Platform.js#L15-L39).

### 3.2 Debug module and build modes

`Debug` is available in development only.
The module documentation says it is not for packages or production.
`Debug.toString` and `Debug.log` are unavailable with `--optimize`.
`Debug.todo` is also unavailable with `--optimize`.
See
[`Debug.elm`](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Debug.elm#L7-L12),
[the toString note](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Debug.elm#L31-L35),
and
[the todo note](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Debug.elm#L86-L88).

The kernel has DEBUG and PROD variants.
`_Debug_log__PROD` returns the value without logging.
`_Debug_log__DEBUG` logs to the console.
`_Debug_toString__PROD` returns `<internals>`.
See
[`Debug.js` kernel variants](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Debug.js#L12-L21)
and
[toString variants](https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Debug.js#L43-L51).

The compiler selects kernel sections by mode.
Kernel files mark sections with `/**__PROD/` and `/**__DEBUG/`.
The Dev modes keep the DEBUG sections.
The Prod mode keeps the PROD sections.
See
[kernel marker parsing](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/compiler/src/Parse/Primitives/Kernel.hs#L107-L111)
and
[kernel section selection](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/compiler/src/Generate/JavaScript.hs#L324-L364).

The compiler maps the flags to modes.
`elm make --debug` maps to `Output.Debug`.
`elm make --optimize` maps to `Output.Prod`.
`elm make` maps to `Output.Dev`.
The debug and optimize flags conflict.
See
[`Make.hs` flag mapping](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/ui/terminal/src/Make.hs#L28-L53)
and
[the clashing-flags error](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/builder/src/Reporting/Exit/Make.hs#L64-L75).

The Debug mode is the Dev mode plus interfaces.
`Mode.debug` builds `Dev target (Just interfaces)`.
`Mode.dev` builds `Dev target Nothing`.
`Mode.prod` builds the optimized mode.
See
[`Mode.hs`](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/compiler/src/Generate/JavaScript/Mode.hs#L27-L58).

The Prod mode rejects Debug uses.
The compiler reports `CannotOptimizeDebugValues`.
The optimize flag strips information that Debug needs.
See
[`noDebugUses`](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/builder/src/Generate/Output.hs#L215-L227)
and
[the error text](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/builder/src/Reporting/Exit/Make.hs#L45-L62).

The 0.19 upgrade document restates the optimize rule.
`--optimize` forgets information useful for debugging.
The `Debug` module becomes unavailable.
See
[the `--optimize` section](https://github.com/elm/compiler/blob/1bd5b36915a38335195ca7792fe3995f53d84d5e/docs/upgrade-instructions/0.19.0.md#L101-L110).

The plain dev build keeps the DEBUG kernel variants.
This is source inference from the mode sections.
The debugger kernel is separate and stricter.
Section 3.4 records its rule.

Browser navigation history is browser-owned.
`pushUrl` adds a browser history entry.
`replaceUrl` does not add one.
Elm manages only the history the program created.
This is application navigation state, not message history.
See
[`Browser/Navigation.elm`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Navigation.elm#L51-L140).

### 3.3 Elm 0.18 debugger (virtual-dom)

Elm 0.18 shipped a time-traveling debugger.
The official announcement describes it as the core of the release.
The debugger wraps the `init`, `update`, `view`, and `subscriptions` functions
of the user program.
The wrapper model holds a message history.
See
[the 0.18 announcement](https://elm-lang.org/news/the-perfect-bug-report)
and
[`VirtualDom/Debug.elm`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/Debug.elm#L20-L51).

Every user message is recorded before the update runs.
`updateUserMsg` calls `History.add userMsg userModel history`.
The wrapper then runs the real update.
The history entry holds the message and the pre-update model.
See
[`updateUserMsg`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/Debug.elm#L271-L306).

The history is a snapshot list.
Each snapshot holds a model and up to 64 messages.
`maxSnapshotSize` is 64.
Snapshots are appended without a total cap.
Retention is unbounded overall and chunked at 64 messages.
See
[`History.elm`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/History.elm#L26-L53)
and
[`addRecent`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/History.elm#L123-L147).

The history supports time travel.
`Jump` re-runs the pure part of `update` from a snapshot.
The sidebar numbers messages in order.
The debugger can pause, resume, and step.
See
[`Jump`, `Up`, and `Down`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/Debug.elm#L115-L168)
and
[`History.get`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/History.elm#L154-L200).

Replay requires re-running `update`.
`History.get` applies each message with the pure part of `update`.
Import rebuilds the whole history from the initial model.
The decoder folds messages through `update`.
See
[the import decoder](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/History.elm#L79-L93).

Import and export were the headline feature.
The announcement calls import and export the feature for QA teams.
The debugger exports the session as JSON.
A changed program rejects incompatible history with a clear error.
See
[the announcement](https://elm-lang.org/news/the-perfect-bug-report)
and
[`Debug.elm` import and export](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/Debug.elm#L170-L217).

The debugger embeds program type metadata.
`Metadata` records Elm version and message types.
Import checks compatibility at decode time.
See
[`Metadata.elm`](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/Metadata.elm#L20-L43)
and
[the compatibility check](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/src/VirtualDom/Metadata.elm#L147-L165).

Time travel rewinds the Elm program only.
The announcement states that JavaScript and the database do not rewind.
The wrapper model drives the paused view from history.
Host state is not simulated or restored.
See
[the announcement](https://elm-lang.org/news/the-perfect-bug-report).

The debugger runs in development builds.
`elm-make --debug` enables it.
`elm-reactor` enables it by default.
The package declares Elm 0.18 only.
See
[the announcement](https://elm-lang.org/news/the-perfect-bug-report),
[`elm-make` flag](https://github.com/elm-lang/elm-make/blob/1a554833a70694ab142b9179bfac996143f68d9e/src/Flags.hs#L134-L140),
and
[the package version bound](https://github.com/elm-lang/virtual-dom/blob/68333d3a9b17b6e60bfba7ff064b6802d1dd2c64/elm-package.json#L12).

`elm-make` includes the debugger module only in debug mode.
In non-debug mode the build filters out `VirtualDom.Debug`.
Debug metadata carries versions and program types.
See
[`Generate.hs`](https://github.com/elm-lang/elm-make/blob/1a554833a70694ab142b9179bfac996143f68d9e/src/Pipeline/Generate.hs#L122-L126)
and
[the metadata builder](https://github.com/elm-lang/elm-make/blob/1a554833a70694ab142b9179bfac996143f68d9e/src/Pipeline/Generate.hs#L210-L226).

### 3.4 Elm 0.19 debugger (elm/browser)

Elm 0.19 keeps the time-traveling debugger.
The debugger moved from `elm-lang/virtual-dom` into `elm/browser`.
The package is `elm/browser` 1.0.2 for Elm 0.19.
The source holds `Debugger.Main`, `Debugger.History`, and
`Elm.Kernel.Debugger`.
See
[`elm.json`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/elm.json#L6-L13)
and the
[debugger sources](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Main.elm#L1-L10).

The official CLI documents the debugger.
The `elm make --debug` help text names the time-traveling debugger.
It says the debugger rewinds and replays events.
It says events can be imported and exported for bug reports.
See
[the make command flags](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/ui/terminal/src/Main.hs#L196-L204).

The debugger is not part of the compiler runtime.
`Browser.elm` imports `Debugger.Main`.
`Elm/Kernel/Browser.js` declares placeholder variables.
The element and document wrappers choose the debugger when present.
See
[`Browser.elm` imports](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm#L33-L36)
and
[`Elm/Kernel/Browser.js`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Elm/Kernel/Browser.js#L27-L92).

The compiler emits the Debugger kernel only in debug mode.
Kernel globals from the `Debugger` home are excluded otherwise.
The exclusion is at code generation time.
See
[kernel exclusion](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/compiler/src/Generate/JavaScript.hs#L195-L204)
and
[the `Debugger` name](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/compiler/src/Elm/Name.hs#L275-L277).

The Debugger kernel wraps the program loop.
`_Debugger_element` and `_Debugger_document` replace the plain loop.
They pass `wrapInit`, `wrapUpdate`, and `wrapSubs` to the platform.
They render the corner view and the popout view.
See
[`_Debugger_element`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Elm/Kernel/Debugger.js#L38-L99)
and
[`_Debugger_document`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Elm/Kernel/Debugger.js#L102-L158).

The debugger applies to browser programs.
`sandbox` uses the element kernel path.
`element`, `document`, and `application` use the same paths.
`Platform.worker` programs are not wrapped.
See
[`Browser.elm` program builders](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm#L63-L130)
and
[`application`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm#L207-L217).

The debugger retains every user message.
`wrapUpdate` calls `History.add userMsg userModel model.history`.
The record happens before the real update runs.
The entry holds the message and the pre-update model.
See
[`wrapUpdate`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Main.elm#L195-L225).

The 0.19 history uses the same snapshot scheme as 0.18.
`maxSnapshotSize` is 31 in 0.19.
The source explains the trade between DOM nodes and memory.
Snapshots are appended without a total cap.
Retention is unbounded overall and chunked at 31 messages.
See
[`History.elm`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/History.elm#L33-L45)
and
[`addRecent`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/History.elm#L138-L162).

The debugger supports time travel.
`Jump` and `SliderJump` re-run the pure part of `update`.
`Resume`, `Up`, and `Down` move through the history.
A slider and a popout window present the history.
See
[`Jump` and `SliderJump`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Main.elm#L251-L289),
[`jumpUpdate`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Main.elm#L330-L349),
and
[`History.get`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/History.elm#L169-L191).

The debugger supports import and export.
`Export` downloads metadata and history as JSON.
`Import` reads a file and rebuilds the history.
The rebuild re-runs every message from the initial model.
See
[`Import`, `Export`, and `Upload`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Main.elm#L291-L307),
[`loadNewHistory`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Main.elm#L431-L458),
and
[the import decoder](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/History.elm#L96-L109).

Import validates compatibility with program metadata.
The metadata records the Elm version and message types.
`Metadata.check` reports version and type differences.
The overlay reports bad, risky, or fine imports.
See
[`Metadata.elm`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Metadata.elm#L23-L46),
[the check](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Metadata.elm#L154-L160),
and
[`assessImport`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Debugger/Overlay.elm#L78-L98).

The compiler embeds the metadata in debug mode.
`toDebugMetadata` builds the metadata object.
It runs only in the Dev mode with interfaces.
Prod and plain Dev modes pass zero instead.
See
[`toDebugMetadata`](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/compiler/src/Generate/JavaScript/Expression.hs#L1056-L1069).

The debugger displays raw values.
`Expando` renders messages and models.
`Elm.Kernel.Debugger` stringifies messages for the sidebar.
There is no redaction layer.
See
[`messageToString`](https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Elm/Kernel/Debugger.js#L324-L377).

The debugger is a development-build feature.
`elm make --debug` enables it.
`elm make --optimize` disables it and rejects Debug uses.
`elm reactor` compiles in Dev mode without the debugger.
See
[`toMode`](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/ui/terminal/src/Make.hs#L47-L53),
[the reactor interface](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/ui/terminal/src/Main.hs#L141-L162),
and
[the reactor compile path](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/ui/terminal/src/Develop.hs#L161-L171).

The `--debug` and `--optimize` flags conflict.
The error text says `--debug` adds debugger information.
It says `--optimize` takes information away.
The 0.19.1 notes list bug fixes for `--debug`.
See
[the clashing-flags error](https://github.com/elm/compiler/blob/32059a289d27e303fa1665e9ada0a52eb688f302/builder/src/Reporting/Exit/Make.hs#L64-L75)
and
[the 0.19.1 notes](https://github.com/elm/compiler/blob/1bd5b36915a38335195ca7792fe3995f53d84d5e/docs/upgrade-instructions/0.19.1.md#L14).

The 0.18 debugger and the 0.19 debugger differ.
0.18 lived in `elm-lang/virtual-dom` with chunk size 64.
0.19 lives in `elm/browser` with chunk size 31.
0.18 reactor enabled debug by default.
0.19 reactor does not.
The retention, replay, and import behavior are the same.

### 3.5 Ownership in the Elm line

The compiler owns the build-mode wiring.
It decides when the Debugger kernel is emitted.
`elm/browser` owns the debugger implementation.
The runtime owns the plain model loop.
The browser owns navigation history.
Applications own message meaning and transitions.

## 4. elm-program-test

### 4.1 What code retains messages, models, and effects

The test driver keeps one current model.
`TestState.currentModel` holds the latest model.
Messages replace the model. The driver does not log them.
See
[`TestState`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/TestState.elm#L16-L39).

The driver keeps only the last effect.
`TestState.lastEffect` holds the most recent effect.
`expectLastEffect` and `simulateLastEffect` read that one value.
There is no effect list.
See
[`simulateLastEffect`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L1926-L1948)
and
[`expectLastEffect`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L1951-L1974).

The driver retains pending simulated effects.
The work queue holds effects to drain.
The HTTP store holds requests until a simulated response.
The port store holds all values sent to each port.
See
[`EffectSimulation`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest/EffectSimulation.elm#L21-L44).

A `TestLog` type with a model history exists.
It defines `history : List model`.
No code constructs or reads it.
It is unused dead code.
See
[`TestLog`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L281-L284).

The package simulates its own programs.
It never activates the Elm debugger.
`createWorker` simulates `Platform.worker` programs.
See
[`createWorker`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L382-L394).

### 4.2 Default, optional, bounded, or unbounded

Retention is default within a test.
The driver records effects as the program produces them.
No flag turns the recording off.

Bounds are per-test and per-domain.
HTTP requests stay until simulated responses remove them.
Port values accumulate for the whole test.
`clearOutgoingPortValues` resets one port log.
See
[the response simulation](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L1668-L1702)
and
[`clearOutgoingPortValues`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest/EffectSimulation.elm#L120-L122).

### 4.3 Identity, ordering, and lifecycle

Messages apply in the order the test sends them.
Effects drain from a FIFO work queue.
HTTP requests are keyed by method and URL.
The port log preserves arrival order.
See
[`stepWorkQueue`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest/EffectSimulation.elm#L62-L79).

The sources define no admitted, processed, or committed message stages.
The only lifecycle labels are pending and resolved.
A request is pending until the test simulates a response.
This matches the pending-requests failure text.
See
[the failure text](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest/Failure.elm#L68-L101).

### 4.4 Crash reports and failure output

Failures are printed with retained records.
HTTP failures list the pending requests.
View failures dump the current HTML.
The `ProgramTest` value carries a failure log.
See
[the `ProgramTest` description](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest.elm#L232-L247)
and
[`Failure.elm`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/ProgramTest/Failure.elm#L15-L30).

### 4.5 Replay and time travel

elm-program-test offers no replay or time travel.
The test starts fresh from `init`.
Each simulation step moves forward.
There is no rewind API.
The driver simulates time forward only.
See
[`advanceTime`](https://github.com/avh4/elm-program-test/blob/195131b038cab24fd3b7806930c19e40809cdd35/src/TestState.elm#L240-L300).

### 4.6 Graph inspection and performance instrumentation

elm-program-test has neither.
It inspects views, models, and effects through assertions.
There is no graph surface to inspect.

### 4.7 Redaction, build mode, transport, and disabling

The package defines no redaction rules.
It runs in elm-test, a test build.
Port values are JSON values.
Failures print values through the Elm failure formatter.
This is test tooling policy, not a runtime rule.

### 4.8 Ownership: framework versus application versus tooling

The driver owns the simulated runtime.
It owns model storage, effect recording, navigation, and virtual time.
The test owns stimuli and assertions.
The failure format is tooling-owned.
This matches the census family descriptions for this package.

## 5. Confirmed absence versus lack of documentation

These absences are confirmed in the sources.

- Bonsai production code retains no action history.
- Bonsai test handles retain one stored view, not a view history.
- Rust Crux retains no event history.
- The plain Elm 0.19 runtime retains no message history.
- Elm 0.19 default builds and `--optimize` builds include no debugger.
- Elm 0.19 `elm reactor` does not enable the debugger.
- The Elm debugger does not wrap worker programs.
- elm-program-test retains no message history.

These are gaps in documentation, not confirmed absences.

- The 0.19 announcement does not describe the debugger.
- The `elm/browser` README does not document the debugger.
- Crux documents no bound for the bridge registry.
- Bonsai documents no bound for the pending action queue.
- The Elm debugger documents no total history bound.

## 6. Contradictions and uncertainty

One source has an internal contradiction.
`elm-program-test` defines `TestLog` with a model history.
No code uses `TestLog`.
The type is evidence of an abandoned design, not a feature.
This is source inference.

One design differs between the Elm versions.
0.18 reactor enabled debug mode by default.
0.19 reactor compiles in Dev mode.
The 0.18 announcement documents the reactor default.
The 0.19 source shows the Dev mode.
There is no documented 0.19 statement about the change.

One behavior is source inference.
The compiler emits the Debugger kernel only in debug mode.
The `__Debugger_element` fallback confirms the design.
The fallback is visible in `Elm/Kernel/Browser.js`.
No documentation describes the fallback in words.

One limit is undocumented.
The debugger history has no total cap.
The snapshot chunk sizes are 31 in 0.19 and 64 in 0.18.
The 0.19 comment explains the chunk choice.
It does not promise a total bound.

The virtual-dom package bound is still valid.
The 0.18 debugger never shipped for 0.19.
The 0.19 debugger is a separate implementation in `elm/browser`.
The relocation is visible in the package sources.
No announcement documents the relocation.

## 7. Evidence for the ticket

The ticket asks whether Eta Crux needs bounded committed-action diagnostics.
This report does not answer that question.
It records what each reference does.

Production builds retain no committed-action history.
Bonsai, Crux, and the plain Elm runtime retain one model each.
The Elm debugger retains full message history in dev builds.
That history is unbounded, chunked, and paired with replay tooling.
It is enabled only by `elm make --debug`.

Retained diagnostics are test-only or dev-only in every reference.
Bonsai and Crux retain nothing in production code.
elm-program-test retains effect records inside a test.
Crash output in test tools uses retained pending state.
The Elm debugger shows history in its own UI.

Every reference separates concerns by design.
Graph inspection and performance instrumentation are separate from history.
Replay and time travel are separate from diagnostics.
Redaction is application or tooling policy in every reference.

The evidence supports these distinctions for the Eta Crux discussion.
Bounded history, replay, graph inspection, and failure snapshots are
independent decisions.
The references show no framework that couples them.
Elm is the only reference with a full retained message history.
Its history is a dev-build feature with import and export.

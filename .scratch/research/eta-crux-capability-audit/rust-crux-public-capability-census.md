# Rust Crux public capability census

## Scope and method

This report inventories public architectural capability families, not every public function.
It reviews the five published crates in the upstream Crux workspace.

The source snapshot is upstream commit
[`9ca03f3545c7b695be0d1e49d1bda925c43f04e2`](https://github.com/redbadger/crux/commit/9ca03f3545c7b695be0d1e49d1bda925c43f04e2),
dated 2026-08-07.
The snapshot contains `crux_core` 0.20.0, `crux_macros` 0.10.1,
`crux_http` 0.20.0, `crux_kv` 0.14.0, and `crux_time` 0.18.0.
See the pinned
[`crux_core` manifest](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/Cargo.toml#L1-L16),
[`crux_macros` manifest](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_macros/Cargo.toml#L1-L15),
and [workspace members](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/Cargo.toml#L1-L10).

The official overview defines Crux as a side-effect-free Rust core inside a
platform shell.
The shell owns UI work and external effects.
The core owns pure calculations and internal state.
See the
[official architecture overview](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L45-L68)
and its
[shell description](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L108-L119).

Each contract below has one of two evidence labels:

- **Documented contract** quotes or restates public documentation.
- **Source inference** reports behavior visible in the implementation but not promised by public prose.

The classifications are research evidence only.
They do not decide adoption, deferral, or rejection for Eta Crux.

## Classification key

- **plausible generic Eta Crux role**: The family can support a framework-neutral application or host capability.
- **design evidence only**: The family gives useful laws or patterns, but its current form does not clearly belong in Eta Crux.
- **Rust Crux-specific**: The contract depends on Rust traits, generated Rust code, or Crux cross-language packaging.

## Census summary

The census contains 22 public capability families.

| Number | Capability family | Research classification |
|---:|---|---|
| 1 | Application state and event transitions | plausible generic Eta Crux role |
| 2 | View projection and render notification | plausible generic Eta Crux role |
| 3 | Core runtime and shell boundary | plausible generic Eta Crux role |
| 4 | Operations, effects, requests, and resolution | plausible generic Eta Crux role |
| 5 | Commands and asynchronous orchestration | plausible generic Eta Crux role |
| 6 | Command builders and dependent chains | plausible generic Eta Crux role |
| 7 | Streaming requests and subscriptions | plausible generic Eta Crux role |
| 8 | Cancellation and command task lifecycle | plausible generic Eta Crux role |
| 9 | Child application and command composition | plausible generic Eta Crux role |
| 10 | Core middleware and internal effect handling | plausible generic Eta Crux role |
| 11 | Type-based effect routing | design evidence only |
| 12 | Serialized bridge and wire formats | Rust Crux-specific |
| 13 | Effect declaration and generated adapters | Rust Crux-specific |
| 14 | Foreign type generation | Rust Crux-specific |
| 15 | HTTP capability and protocol | plausible generic Eta Crux role |
| 16 | HTTP client middleware | design evidence only |
| 17 | Key-value capability and protocol | plausible generic Eta Crux role |
| 18 | Time and cancellable timers | plausible generic Eta Crux role |
| 19 | Direct command inspection and resolution tests | plausible generic Eta Crux role |
| 20 | Generated effect test helpers | plausible generic Eta Crux role |
| 21 | HTTP response and rejection test values | plausible generic Eta Crux role |
| 22 | Legacy application test driver | design evidence only |

The counts are 16 plausible generic roles, three design-evidence families, and
three Rust Crux-specific families.

## Core and shell capability details

### 1. Application state and event transitions

- **Purpose:** An `App` defines `Event`, `Model`, `ViewModel`, and `Effect`.
  Its `update` function mutates the model after an event and returns a command.
- **Documented contract:** `Event` is the main core input.
  `update` defines the model transition and describes managed effects.
  `Command::done` represents a transition with no effects.
- **Source inference:** `App` itself does not store the model.
  `Core` stores one model and passes exclusive mutable access to `update`.
- **Test control:** A test can instantiate the app and model, call `update`
  directly, and inspect both the model and returned command.
- **Ownership:** The application owns event meaning and transition logic.
  `Core` owns model storage when the application runs inside a core.
- **Classification:** **plausible generic Eta Crux role**.
  An event-driven state transition is independent of Rust Crux shell technology.
- **Sources:** [`App` and `update`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/lib.rs#L255-L285)
  and the [official component model](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L70-L94).

### 2. View projection and render notification

- **Purpose:** `App::view` derives a shell-facing `ViewModel` from the model.
  `render` sends a notification that tells the shell to redraw.
- **Documented contract:** `view` returns the current UI state.
  `RenderOperation` has unit output, and `render` is a shell notification.
  A render request does not carry the view model.
- **Source inference:** Crux does not cache the view model.
  Each core or bridge `view` call computes it from the current model.
- **Test control:** Tests call `view` directly and compare its value.
  They can also assert that a returned command contains one render request.
- **Ownership:** The application owns view projection.
  The shell owns rendering and decides when to call `view`.
  Crux owns delivery of the render notification.
- **Classification:** **plausible generic Eta Crux role**.
  Pull-based output and a separate invalidation signal can support a generic host.
- **Sources:** [`App::view`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/lib.rs#L284-L285),
  [`RenderOperation` and `render`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/capabilities/render.rs#L10-L58),
  and the [official bridge summary](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L159-L172).

### 3. Core runtime and shell boundary

- **Purpose:** `Core` stores the app and model.
  It accepts shell events, returns effects, accepts effect outputs, and returns views.
- **Documented contract:** `process_event` runs `update` and returns ready effects.
  `resolve` resumes a request and returns follow-up effects.
  `view` returns the current view model.
- **Source inference:** After an external event, `Core` drains command-produced events
  in FIFO order.
  Each drained event runs another `update` before ready effects return to the shell.
- **Test control:** Tests can use the typed `Core` as an in-process shell.
  They provide events and request outputs without serialization.
- **Ownership:** `Core` owns model locking, the root command, and internal event draining.
  The shell owns call cadence and every external effect implementation.
- **Classification:** **plausible generic Eta Crux role**.
  The explicit event, effect, response, and view boundary is framework-neutral.
- **Sources:** [`Core` storage and constructors](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/mod.rs#L14-L84),
  [`process_event`, internal event draining, and `view`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/mod.rs#L86-L175),
  and the [official shell message cycle](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L188-L206).

### 4. Operations, effects, requests, and resolution

- **Purpose:** `Operation` binds a shell input type to its output type.
  `Request<Op>` pairs an operation with a resolution handle.
  An application effect enum combines requests from different operation families.
- **Documented contract:** Request handles support `Never`, `Once`, and `Many`.
  A notification cannot resolve.
  A one-shot request consumes its callback after one resolution.
  A stream handle accepts outputs until its receiver concludes.
- **Source inference:** A second resolution of a one-shot request returns
  `ResolveError::Never`.
  A stream resolution after its receiver closes returns `ResolveError::FinishedMany`.
- **Test control:** Tests pattern-match the effect enum, inspect `request.operation`,
  and call `Request::resolve` with a chosen typed output.
- **Ownership:** The capability author owns operation and output types.
  A command owns the callback.
  The shell owns execution and supplies output values.
- **Classification:** **plausible generic Eta Crux role**.
  Typed request cardinality is useful beyond the Rust implementation.
- **Sources:** [`Operation`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/capability/mod.rs#L1-L17),
  [`Request`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/request.rs#L8-L63),
  and [`RequestHandle` cardinality and errors](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/resolve.rs#L8-L57).

### 5. Commands and asynchronous orchestration

- **Purpose:** `Command` describes shell effects, application events, and asynchronous
  tasks that coordinate them.
- **Documented contract:** A command runs tasks until they settle.
  `then` runs commands in sequence.
  `and` and `all` run commands concurrently.
  `effects` and `events` drive the executor and return currently ready outputs.
- **Source inference:** Command channels are unbounded.
  The source records that a command can create unbounded requests or tasks.
- **Test control:** Tests repeatedly read `effects`, resolve requests, read `events`,
  and use `is_done` to establish completion.
- **Ownership:** A command owns its task executor and output channels.
  The core polls the root command.
  The shell owns all work represented by emitted effects.
- **Classification:** **plausible generic Eta Crux role**.
  Sequential and concurrent effect descriptions are generic application needs.
- **Sources:** [command module contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L1-L20),
  [`Command` creation and unbounded channels](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L264-L350),
  and [output and composition operations](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L445-L526).

### 6. Command builders and dependent chains

- **Purpose:** Notification, request, and stream builders create commands without
  requiring application code to write an asynchronous task.
- **Documented contract:** Request builders can map results and chain a notification,
  request, or stream.
  `then_send` converts each final result into an application event.
  A plain `build` discards an unbound result.
- **Source inference:** Dependent chains do not emit the next request until the prior
  future produces an output.
  Stream-to-stream chaining uses unordered flattening.
- **Test control:** Each builder can become a command.
  Tests then inspect and resolve each emitted request in sequence.
- **Ownership:** Crux owns chain scheduling.
  The capability author owns result mapping.
  The application owns the event constructor.
- **Classification:** **plausible generic Eta Crux role**.
  Typed dependent effect chains can reduce generic application coordination code.
- **Sources:** [builder purpose and stream composition limit](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/builder.rs#L1-L7),
  [request mapping and chaining](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/builder.rs#L60-L100),
  [`then_send` and discarded output](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/builder.rs#L362-L392),
  and [stream chains](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/builder.rs#L499-L640).

### 7. Streaming requests and subscriptions

- **Purpose:** `stream_from_shell` creates one request that can receive many shell outputs.
  A `StreamBuilder` maps those outputs to events or further operations.
- **Documented contract:** Each shell resolution yields one stream item.
  `then_send` sends one application event for each item.
  The stream can be finite or unbounded.
- **Source inference:** The stream transport uses an unbounded channel.
  The request is sent on the first poll, not when the builder is created.
- **Test control:** A test retains the request and resolves it many times.
  After each resolution, the test reads ready events or follow-up effects.
- **Ownership:** The shell owns subscription production.
  The command owns the stream receiver and event mapping.
  Cancellation ends command-side interest.
- **Classification:** **plausible generic Eta Crux role**.
  Host-owned streams are a generic boundary requirement.
- **Sources:** [`stream_from_shell`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L427-L443),
  [`ShellStream` creation and polling](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/context.rs#L93-L128),
  and [`StreamBuilder::then_send`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/builder.rs#L605-L640).

### 8. Cancellation and command task lifecycle

- **Purpose:** Abort handles stop a complete command or one spawned task.
  Capability code can add a domain cancellation protocol, as timers do.
- **Documented contract:** Aborting a command terminates it and all subtasks.
  A spawned task can also be aborted through its join handle.
  Dropping a shell request handle can abort a task waiting at that request.
- **Source inference:** Command abort does not send a generic cancellation effect to the shell.
  External cleanup needs a capability-specific protocol or shell policy.
- **Test control:** Tests retain an abort handle, call `abort`, and inspect
  `was_aborted` and `is_done`.
  Cancellation tests can also drop request handles.
- **Ownership:** The command owns task cancellation.
  The shell still owns external work.
  A capability owns any explicit external cleanup operation.
- **Classification:** **plausible generic Eta Crux role**.
  Task cancellation and explicit external cleanup are generic lifecycle concerns.
- **Sources:** [public command cancellation contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L158-L180),
  [`abort_handle`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L572-L595),
  and [request cancellation behavior](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/context.rs#L56-L89).

### 9. Child application and command composition

- **Purpose:** Parent applications can embed child commands by mapping child effects
  and events into parent types.
- **Documented contract:** `Command::from` and `into` use compatible conversions.
  `map_effect` and `map_event` transform only their named output channel.
- **Source inference:** Mapping hosts the child command as a task in a new command.
  It preserves the other output channel unchanged.
- **Test control:** Tests run the mapped command and inspect parent effects and events.
  No separate composition driver exists.
- **Ownership:** The child owns its local protocol.
  The parent owns conversion into its larger event and effect types.
  Crux owns forwarding.
- **Classification:** **plausible generic Eta Crux role**.
  Typed child-to-parent lifting is useful for modular application logic.
- **Sources:** [`from` and `into`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L359-L379)
  and [`map_effect` and `map_event`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L528-L570).

### 10. Core middleware and internal effect handling

- **Purpose:** `Layer` wraps a core to transform effects or execute selected effects
  in Rust before remaining effects reach the shell.
- **Documented contract:** Effect middleware must resolve asynchronously.
  Synchronous resolution inside `try_process_effect` panics.
  Unknown effects pass to the next layer or shell callback.
  Follow-up effects pass through the same layer stack.
- **Source inference:** Each handling layer selects effects through `TryInto<Request<Op>>`.
  A mapping layer converts immediate and later effects with the same conversion.
- **Test control:** Tests supply an effect middleware and callback.
  They can assert immediate effects, delayed callback effects, and the synchronous-resolution panic.
- **Ownership:** Middleware owns selected effect execution.
  The wrapped core owns state and command progress.
  The shell callback owns effects that no layer handles.
- **Classification:** **plausible generic Eta Crux role**.
  Explicit host-operation layers can be generic even though this Rust trait shape is not.
- **Sources:** [`Layer` boundary and callbacks](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/middleware/mod.rs#L31-L105),
  [`EffectMiddleware` asynchronous contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/middleware/effect_handling.rs#L13-L121),
  and [effect pass-through behavior](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/middleware/effect_handling.rs#L271-L349).

### 11. Type-based effect routing

- **Purpose:** `EffectRouter` sends each effect to a serialized lane, parked typed
  lane, in-process buffer, or core-local handler.
- **Documented contract:** Follow-up effects return through the same routing closure.
  `Serialized` uses bytes and IDs.
  `Parked` keeps typed values behind IDs.
  `Buffer` stores typed requests until a caller drains them.
- **Source inference:** The route set owns weak references to an `Arc<EffectRouter>`.
  Resolving a parked or serialized request advances and reroutes the core runtime.
- **Test control:** The public `Buffer` lane supports direct request collection.
  Tests can also exercise custom route selection and typed resolution.
- **Ownership:** The router owns route policy.
  Each route owns its request registry or buffer.
  Route handlers and the shell own effect execution.
- **Classification:** **design evidence only**.
  Per-effect dispatch is useful evidence, but the lane and cyclic Rust ownership model is specialized.
- **Sources:** [router overview and lane contracts](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/effects/mod.rs#L1-L49),
  [`EffectRouter` lifetime routing](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/effects/mod.rs#L60-L184),
  and [`Buffer`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/effects/routes/buffer.rs#L5-L49).

### 12. Serialized bridge and wire formats

- **Purpose:** `Bridge` exposes the typed core as serialized `update`, `resolve`,
  and `view` calls for foreign shells.
- **Documented contract:** Each serialized effect request contains an `EffectId`.
  The shell returns that ID with serialized output.
  Bincode is the default format, and JSON is also supplied.
  A custom format does not receive generated shell support.
- **Source inference:** The bridge registry retains resolution callbacks until the
  matching ID resumes them.
  Each call serializes one batch of currently ready requests.
- **Test control:** Tests serialize events and outputs through the selected format.
  They can inspect request IDs, byte batches, bridge errors, and serialized views.
- **Ownership:** The bridge owns serialization and the outstanding-request registry.
  The foreign shell owns bytes and must preserve request IDs.
- **Classification:** **Rust Crux-specific**.
  This family exists for Rust cores embedded in generated cross-language shells.
- **Sources:** [`FfiFormat`, request IDs, and `Bridge`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/mod.rs#L18-L84),
  [`Bridge::update`, `resolve`, and `view`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/mod.rs#L137-L265),
  and [Bincode and JSON formats](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/formats.rs#L3-L47).

### 13. Effect declaration and generated adapters

- **Purpose:** `#[effect]` turns an application effect enum into the adapters that
  commands, middleware, testing, and FFI need.
- **Documented contract:** The macro implements the `Effect` marker.
  With `typegen`, it also implements `EffectFFI`.
  Each enum variant supports conversion from and back to its typed request.
- **Source inference:** The macro also conditionally generates one test extension method
  group per effect variant.
- **Test control:** Macro snapshot tests inspect generated code.
  Application tests use generated request extraction and helper methods.
- **Ownership:** The application owns the effect enum.
  `crux_macros` owns generated trait and conversion implementations.
- **Classification:** **Rust Crux-specific**.
  This family depends on Rust procedural macros, enums, and trait coherence.
- **Sources:** [`effect` macro contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_macros/src/lib.rs#L13-L53),
  [`Effect` and `EffectFFI`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/core/effect.rs#L5-L34),
  and [generated conversions and test methods](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_macros/src/effect/macro_impl.rs#L95-L160).

### 14. Foreign type generation

- **Purpose:** Type generation creates Swift, Kotlin, C#, and TypeScript definitions
  for events, views, effects, operations, and outputs.
- **Documented contract:** `TypeRegistry::register_app` registers the app effect,
  event, and view model.
  `CodeGenerator` writes language packages with Bincode support.
- **Source inference:** The generator owns build-time files, not runtime effects.
  TypeScript generation also runs `pnpm install` and `tsc`.
- **Test control:** Tests register sample app types and generate into temporary directories.
  They can compare generated files and reported errors.
- **Ownership:** The build process owns generation and output directories.
  Shell projects own the generated types after generation.
- **Classification:** **Rust Crux-specific**.
  The family serves Crux foreign-language packaging and Rust type reflection.
- **Sources:** [`TypeRegistry` and app registration](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/type_generation/facet.rs#L121-L223),
  [language generators](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/type_generation/facet.rs#L231-L351),
  and [TypeScript tool execution](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/type_generation/facet.rs#L353-L388).

## Published capability details

### 15. HTTP capability and protocol

- **Purpose:** `crux_http` builds HTTP operations for shell execution.
  It supports standard methods, headers, queries, byte, string, JSON, and form bodies.
- **Documented contract:** The shell protocol uses plain request and response carriers.
  Transport failures use `HttpResult::Err`.
  A completed exchange uses `HttpResult::Ok`, including a 4xx or 5xx response.
  The app-facing API converts 4xx and 5xx responses into `HttpError::Http`.
- **Source inference:** Response decoding runs in the command after shell resolution.
  The shell owns no application response type.
- **Test control:** Tests inspect `HttpRequest` exactly and resolve it with `HttpResult`.
  Protocol builders can construct intentionally invalid header strings.
- **Ownership:** The shell owns network I/O.
  `crux_http` owns request conversion, status policy, and body decoding.
  The application owns response handling.
- **Classification:** **plausible generic Eta Crux role**.
  A typed HTTP boundary is a reusable host capability.
- **Sources:** [app-facing status and error contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/lib.rs#L2-L22),
  [command request execution and decoding](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/command.rs#L386-L412),
  and [shell protocol status contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/protocol.rs#L252-L297).

### 16. HTTP client middleware

- **Purpose:** `Middleware`, `Next`, `Client`, and `Redirect` describe asynchronous
  request interception around an HTTP endpoint.
- **Documented contract:** A middleware can call the remaining chain.
  `Redirect` follows five redirect status codes up to a fixed attempt count.
  However, middleware added through the current command builder does not run.
- **Source inference:** External users cannot construct a `Client`.
  Its constructors and middleware installer are crate-private and test-only.
  Thus, the public middleware surface is not a usable current capability path.
- **Test control:** Upstream tests use a private fake shell and private client constructor.
  Public application tests cannot use that fake shell.
- **Ownership:** If this path runs, the client owns middleware order and endpoint calls.
  In the current command API, the shell directly owns HTTP execution instead.
- **Classification:** **design evidence only**.
  Interceptor ordering is useful evidence, but the active API documents middleware as a no-op.
- **Sources:** [`Middleware` and `Next`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/middleware.rs#L62-L122),
  [documented command API no-op](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/command.rs#L339-L381),
  and [private client construction](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/client.rs#L73-L111).

### 17. Key-value capability and protocol

- **Purpose:** `crux_kv` asks the shell to get, set, delete, check, and list persisted keys.
- **Documented contract:** `set` and `delete` return the prior value.
  `list_keys` uses an opaque cursor.
  Cursor zero means that no page remains.
  An unknown cursor returns `CursorNotFound`.
- **Source inference:** Capability result mapping panics when the shell returns a response
  variant that does not match the requested operation.
- **Test control:** Tests inspect `KeyValueOperation` and resolve it with a chosen
  `KeyValueResult`.
  No store implementation ships as public test support.
- **Ownership:** The shell owns persistence, cursor creation, and page ordering.
  `crux_kv` owns the protocol and typed result conversion.
- **Classification:** **plausible generic Eta Crux role**.
  Host-owned persistence is a reusable application capability.
- **Sources:** [`KeyValue` operations](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_kv/src/lib.rs#L17-L83),
  [operation and cursor contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_kv/src/protocol/mod.rs#L10-L39),
  and [response conversion](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_kv/src/protocol/mod.rs#L128-L213).

### 18. Time and cancellable timers

- **Purpose:** `crux_time` requests wall-clock time, a notification at an instant,
  or a notification after a duration.
- **Documented contract:** Timer requests carry unique IDs.
  A timer completes with a matching completed handle or returns `Cleared`.
  Calling `TimerHandle::clear` sends a `TimeRequest::Clear` for shell cleanup.
  Dropping the handle leaves the timer active and no longer clearable.
- **Source inference:** IDs come from one process-global atomic counter.
  Clear races prefer the clear branch because the implementation uses `select_biased`.
- **Test control:** Tests resolve time operations with chosen instants and timer responses.
  They can clear a retained handle before or after the timer request appears.
  The crate does not supply a test clock.
- **Ownership:** The shell owns wall time and timer resources.
  The capability owns IDs, race selection, and the explicit clear protocol.
- **Classification:** **plausible generic Eta Crux role**.
  Controlled time requests and cancellation cleanup are generic host concerns.
- **Sources:** [`Time` purpose and timer contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_time/src/lib.rs#L33-L74),
  [`notify_at` race](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_time/src/lib.rs#L76-L149),
  [`TimerHandle::clear`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_time/src/lib.rs#L224-L241),
  and [wire operations](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_time/src/protocol/mod.rs#L13-L37).

## Test capability details

### 19. Direct command inspection and resolution tests

- **Purpose:** The `testing` feature adds assertion methods directly to `Command`.
  The normal command API also exposes effects, events, completion, and request resolution.
- **Documented contract:** `expect_one_effect` and `expect_one_event` enforce exact
  cardinality for the selected channel.
  `expect_done` requires command completion.
  No-output assertions do not imply completion.
- **Source inference:** Each assertion first drives the command until it settles.
  Reading an iterator consumes the currently queued values.
- **Test control:** Tests can inspect effects and events, provide typed outputs,
  repeat the cycle, and assert final completion.
- **Ownership:** The test owns shell simulation and all supplied outputs.
  The command owns scheduling and pending work.
- **Classification:** **plausible generic Eta Crux role**.
  Deterministic effect observation and resolution are generic test needs.
- **Sources:** [official test-shell model](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L115-L119),
  [command assertions](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L258-L367),
  and [direct command test example](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/command/mod.rs#L183-L237).

### 20. Generated effect test helpers

- **Purpose:** `#[effect]` generates fluent command helpers for each effect variant.
  They assert a variant, inspect its operation, or resolve it from a closure.
- **Documented contract:** `expect_only_<variant>` requires that variant and no other effect.
  `resolve_<variant>` supplies the operation to a closure that returns its output.
  Helpers exist only with the `testing` feature.
- **Source inference:** The generated `resolve` helper takes the next effect,
  requires the selected variant, and immediately resolves its request.
- **Test control:** The helper names derive from the application effect enum.
  Tests chain assertions and resolutions without a separate runner.
- **Ownership:** The macro owns helper generation.
  The test owns expected operations and outputs.
  The command still owns progress.
- **Classification:** **plausible generic Eta Crux role**.
  Typed per-effect assertions are useful even if Eta uses no Rust macro.
- **Sources:** [official feature and helper contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-1/testing.md#L8-L18),
  [official generated helper behavior](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-1/testing.md#L44-L53),
  and [generated helper implementation](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_macros/src/effect/macro_impl.rs#L192-L304).

### 21. HTTP response and rejection test values

- **Purpose:** `crux_http::testing` builds app-facing successful responses and
  HTTP rejection errors.
- **Documented contract:** `ResponseBuilder` refuses error status codes.
  `rejection` and `rejection_from` construct `HttpError::Http` values for 4xx and 5xx responses.
- **Source inference:** These helpers model values after the command performs status
  conversion.
  They do not execute a shell or network client.
- **Test control:** Tests can provide typed bodies, status codes, headers, and rejection bodies.
- **Ownership:** The test owns the synthetic exchange.
  `crux_http` owns conversion to its app-facing response and error types.
- **Classification:** **plausible generic Eta Crux role**.
  Capability-specific boundary fixtures support concise deterministic tests.
- **Sources:** [`testing` module contract](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/testing/mod.rs#L1-L19),
  [`ResponseBuilder`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/testing/response_builder.rs#L13-L100),
  and [rejection builders](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/testing/rejection.rs#L1-L91).

### 22. Legacy application test driver

- **Purpose:** `AppTester` retains a root command across update and resolve steps.
  `Update` groups ready effects and events.
- **Documented contract:** Upstream deprecates `AppTester`.
  Direct command tests replace it.
  Its helper can resolve one request, require one resulting event, then run that event.
- **Source inference:** The tester owns a mutex-protected root command.
  It does not own model storage because each call receives a mutable model.
- **Test control:** Tests call `update`, `resolve`, `view`, and `Update` assertions.
- **Ownership:** The tester owns command continuity.
  The test owns model storage and each stimulus.
- **Classification:** **design evidence only**.
  The persistent-driver pattern is useful evidence, but upstream keeps this API only for migration.
- **Sources:** [`AppTester` deprecation and purpose](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L7-L37),
  [`update`, `resolve`, and view control](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L45-L138),
  and [`Update` assertions](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/testing.rs#L155-L256).

## Excluded public and workspace families

These exclusions prevent public names from disappearing silently from the census.

| Excluded surface | Reason | Primary source |
|---|---|---|
| Deprecated `Bridge::process_event` and `Bridge::handle_response` | Compatibility aliases for family 12. The current API uses output-buffer `update` and `resolve`. | [`Bridge` deprecated methods](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/bridge/mod.rs#L113-L209) |
| Deprecated UniFFI bindgen support | A compatibility package tool, not an application capability. Upstream directs users to BoltFFI. | [`bindgen` feature and deprecation](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/lib.rs#L244-L249) |
| Deprecated `Capability` derive | An obsolete macro surface. Upstream directs users to `#[effect]`. | [`Capability` derive deprecation](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_macros/src/lib.rs#L61-L66) |
| Serde-reflection `typegen` implementation | An alternate implementation of family 14. It does not add an architectural capability. | [`typegen` public alias](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/lib.rs#L250-L253) and [its generator](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/type_generation/serde.rs#L141-L159) |
| HTTP body, request, response, error, and expectation types | Data and codecs inside family 15. They do not own a separate effect lifecycle. | [`crux_http` exports](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/lib.rs#L25-L62) |
| HTTP `http-types` compatibility feature | A legacy data conversion surface, not a current capability contract. | [`http-types` feature](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/Cargo.toml#L14-L21) |
| Key-value `Value`, errors, and result wrappers | Wire carriers and conversions inside family 17. | [`Value`](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_kv/src/protocol/value.rs#L4-L35) |
| Time `Duration`, `Instant`, `TimerId`, and optional Chrono conversions | Wire carriers and conversions inside family 18. | [`crux_time::protocol` exports](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_time/src/protocol/mod.rs#L1-L24) |
| `doctest_support` | An unpublished workspace fixture for upstream documentation. | [`doctest_support` manifest](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/doctest_support/Cargo.toml#L1-L16) |
| `examples_support/api_server` | An unpublished example server. It is not library test support. | [`api_server` manifest](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/examples_support/api_server/Cargo.toml#L1-L8) |
| Example SSE and PubSub capabilities | Useful examples, but not exported public library families. Streaming semantics remain covered by family 7. | [official example capability list](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L150-L157) |
| Platform shells and generated UI bindings | Product host implementations. The generic boundary that they implement is family 3 or family 12. | [official shell boundary](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L108-L113) |
| Examples, benchmarks, release tools, and repository tests | Evidence and maintenance infrastructure, not public user capability surfaces. | [workspace member list](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/Cargo.toml#L1-L10) |

## Coverage check

The following table maps every public crate entry point to a census disposition.

| Public crate or module | Disposition |
|---|---|
| `crux_core::App` and `Core` | Families 1, 2, and 3 |
| `crux_core::capability` and core request types | Family 4 |
| `crux_core::command` | Families 5 through 9 |
| `crux_core::render` | Family 2 |
| `crux_core::middleware` | Family 10 |
| `crux_core::effects` and `effects::routes` | Family 11 |
| `crux_core::bridge` | Family 12 |
| `crux_core::type_generation` | Family 14 |
| `crux_core::testing` | Families 19 and 22 |
| `crux_macros` | Families 13 and 20 |
| `crux_http` core exports, `command`, and `protocol` | Family 15 |
| `crux_http::client` and `middleware` | Family 16 |
| `crux_http::testing` | Family 21 |
| `crux_kv` | Family 17 |
| `crux_time` | Family 18 |

The public crate entry points come from
[`crux_core` exports](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_core/src/lib.rs#L212-L257),
[`crux_http` exports](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_http/src/lib.rs#L25-L64),
[`crux_kv` exports](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_kv/src/lib.rs#L1-L17),
and [`crux_time` exports](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/crux_time/src/lib.rs#L1-L50).

## Residual uncertainty

The snapshot is pre-1.0 and under active development.
The official README warns that breaking API changes can occur.
See the
[project status note](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/README.md#L40-L43).

The effect router is new and marked as an advanced use case.
Its public documentation points to a prototype integration test and an RFC.
This report records its current contract but does not infer stability.

The HTTP middleware API has conflicting surface signals.
Its types remain public, but current command documentation states that middleware does not run.
The source also prevents external construction of the client that executes it.

Command cancellation stops core tasks.
No public contract states that it cancels already-started shell work.
Only capability-specific protocols, such as `TimeRequest::Clear`, express shell cleanup.

Crux supplies deterministic effect resolution but no general virtual clock, queued shell,
or reusable simulator.
Time tests control responses directly.
The official guide discusses application-built simulators as a possible pattern, not shipped support.
See the
[official simulation discussion](https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-2/testing-effects.md#L72-L110).

# Rust Crux and Elm publication semantics

Ticket: [`docs/wayfinder/eta-crux-typed-projection-delivery/issues/04-rust-crux-and-elm-publication-semantics.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/issues/04-rust-crux-and-elm-publication-semantics.md)

## Question

Which Rust Crux and Elm publication semantics can inform Eta Crux typed
projection delivery?

This report records publication contracts for Rust Crux and Elm. It does not
select a public interface.

## Answer

Rust Crux separates the render notice from the view value. The `Render` effect
is a fire-and-forget notification. The shell pulls the whole view model with a
separate `view` call. The serialized bridge returns one batch of id-tagged
effect requests per core call. A render notification carries no payload, no
view model, and no acknowledgment.

Elm publishes one whole-program view. The view is a pure function of the whole
model. The runtime calls the view function once at start and schedules it
after every update. The browser kernel coalesces draws to animation frames
and draws the latest model. Subscriptions are a re-evaluated bag that the
runtime groups per effect manager. Browser.Events and Time reconcile their
own lists. Ports are whole-value `Cmd` and `Sub` boundaries with
JSON-compatible values. Elm has no per-projection observation contract.

Eta Crux can take the notice-then-pull separation, batch publication per
advancement, ascending non-reused request ids, and manager-local
subscription reconciliation.

Eta Crux cannot take missing delivery acknowledgment, a pull that recomputes a
projection instead of returning a retained committed output, unbounded queues,
animation-frame batching, or the absence of a per-projection observation
contract.

## Method

Primary sources only.

| Source | Role |
|---|---|
| redbadger/crux tag `crux_core-v0.20.0` | Current released Rust Crux source |
| redbadger/crux master `9ca03f35` | Live Crux book source and example shells |
| elm/core 1.0.5, elm/browser 1.0.2, elm/time 1.0.0, elm/html 1.0.1, elm/virtual-dom 1.0.5 | Current released Elm package kernels |
| guide.elm-lang.org live pages | Current official Elm guide |
| Local Eta Crux files | Map constraints, baseline report, semantic laws, and `CONTEXT.md` terms |

Classification:

| Class | Meaning |
|---|---|
| Documented | Official doc comment, guide text, or book text |
| Source | Current implementation behavior |
| Inference | Reading that this report adds |

This report did not run Rust Crux tests, Elm builds, or a browser runtime.

## Source revisions

Facts captured on 2026-08-13.

| Source | Revision |
|---|---|
| redbadger/crux current release | Tag `crux_core-v0.20.0`, commit `a3d1256ecad6a43fbb6abc45b97124e920f72b4f`, committed 2026-08-07 |
| redbadger/crux master | `9ca03f3545c7b695be0d1e49d1bda925c43f04e2`, committed 2026-08-07 |
| elm/core released | 1.0.5, commit `84f38891468e8e153fc85a9b63bdafd81b24664e`, committed 2020-02-15 |
| elm/browser released | 1.0.2, commit `53e3caa265fd9da3ec9880d47bb95eed6fe24ee6`, committed 2019-11-01 |
| elm/virtual-dom released | 1.0.5, commit `79d31f5889930aa5d0d8e874a0807076d5c16891`, committed 2025-11-12 |
| elm/time released | 1.0.0, commit `7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce`, committed 2018-05-27 |
| elm/html released | 1.0.1, commit `1affbf39efef4b4529110a567f706130c178a457`, committed 2025-11-12 |
| Elm guide | Live pages at guide.elm-lang.org. No published revision pin |
| Crux book | Published at redbadger.github.io/crux from master `docs/src`. The `docs/STABLE_REF` file at master names `crux_core-v0.20.0` |

The `crux_core/src` tree and the `docs/src` tree are identical between the
`crux_core-v0.20.0` tag and master `9ca03f35`. The two revisions differ only in
`docs/STABLE_REF` and `docs/VERSIONING.md`. This report cites the tag for
source files and master for book files and examples.

elm/time master `dc3b75b7` differs from the 1.0.0 tag only in doc comments for
`Zone` and `every`. The `every` function and its effect manager are identical.
This report cites the 1.0.0 tag.

### Rust Crux source files

| ID | File and role | URL |
|---|---|---|
| RX-APP | `crux_core/src/lib.rs` — `App` trait, `update`, `view` | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/lib.rs |
| RX-CORE | `crux_core/src/core/mod.rs` — `Core`, `process_event`, `resolve`, `view` | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/core/mod.rs |
| RX-CMD | `crux_core/src/command/mod.rs` — `Command`, `notify_shell`, channels | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/command/mod.rs |
| RX-CTX | `crux_core/src/command/context.rs` — `CommandContext`, shell request types | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/command/context.rs |
| RX-BLD | `crux_core/src/command/builder.rs` — `NotificationBuilder` | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/command/builder.rs |
| RX-RENDER | `crux_core/src/capabilities/render.rs` — `RenderOperation`, `render` | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/capabilities/render.rs |
| RX-REQ | `crux_core/src/core/request.rs` — `Request`, resolve kinds | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/core/request.rs |
| RX-BRIDGE | `crux_core/src/bridge/mod.rs` — `Bridge`, `FfiFormat`, serialized interface | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/bridge/mod.rs |
| RX-REG | `crux_core/src/bridge/registry.rs` — `EffectId`, `ResolveRegistry` | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/bridge/registry.rs |
| RX-SERDE | `crux_core/src/bridge/request_serde.rs` — `ResolveSerialized` | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/bridge/request_serde.rs |
| RX-EFFECTS | `crux_core/src/effects/mod.rs` — `EffectRouter`, lanes | https://github.com/redbadger/crux/blob/a3d1256ecad6a43fbb6abc45b97124e920f72b4f/crux_core/src/effects/mod.rs |
| RX-BOOK-ARCH | `docs/src/part-2/elm_architecture.md` — Core and Shell model | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-2/elm_architecture.md |
| RX-BOOK-BASIC | `docs/src/part-1/basic_app.md` — render and view guidance | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-1/basic_app.md |
| RX-BOOK-FX | `docs/src/part-2/effects.md` — command builders, notification | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-2/effects.md |
| RX-BOOK-SHELL | `docs/src/part-2/shell.md` — three shell methods | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-2/shell.md |
| RX-BOOK-RT | `docs/src/part-4/runtime.md` — command runtime | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/part-4/runtime.md |
| RX-RFC-CMD | `docs/src/rfcs/command.md` — adopted Command RFC | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/rfcs/command.md |
| RX-RFC-ROUTER | `docs/src/rfcs/effect-router.md` — effect lanes | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/docs/src/rfcs/effect-router.md |
| RX-FFI | `examples/counter/shared/src/ffi.rs` — `update`, `resolve`, `view` FFI | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/examples/counter/shared/src/ffi.rs |
| RX-APP-EX | `examples/counter/shared/src/app.rs` — counter `update` and `view` | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/examples/counter/shared/src/app.rs |
| RX-TS | `examples/counter/web-nextjs/src/app/core.ts` — React shell render handling | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/examples/counter/web-nextjs/src/app/core.ts |
| RX-TUI | `examples/counter/tui/src/main.rs` — Rust shell render loop | https://github.com/redbadger/crux/blob/9ca03f3545c7b695be0d1e49d1bda925c43f04e2/examples/counter/tui/src/main.rs |

### Elm source files

| ID | File and role | URL |
|---|---|---|
| EL-PLATFORM | `src/Elm/Kernel/Platform.js` — program init, effects queue, ports | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Platform.js |
| EL-SCHED | `src/Elm/Kernel/Scheduler.js` — process queue and stepping | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Elm/Kernel/Scheduler.js |
| EL-PLAT | `src/Platform.elm` — `Program`, `worker` | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform.elm |
| EL-CMD | `src/Platform/Cmd.elm` — `Cmd`, `batch`, `map` | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Cmd.elm |
| EL-SUB | `src/Platform/Sub.elm` — `Sub`, `batch`, `map` | https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/Platform/Sub.elm |
| EL-BROWSER | `src/Browser.elm` — `sandbox`, `element`, `document`, `application` | https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser.elm |
| EL-BROWSER-JS | `src/Elm/Kernel/Browser.js` — element renderer and animator | https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Elm/Kernel/Browser.js |
| EL-EVENTS | `src/Browser/Events.elm` — event subscription effect manager | https://github.com/elm/browser/blob/53e3caa265fd9da3ec9880d47bb95eed6fe24ee6/src/Browser/Events.elm |
| EL-TIME | `src/Time.elm` — `every` and its effect manager | https://github.com/elm/time/blob/7b97ef513b289d7b88704fcfc5a0807f7eb4f5ce/src/Time.elm |
| EL-LAZY | `src/Html/Lazy.elm` — `lazy` semantics | https://github.com/elm/html/blob/1affbf39efef4b4529110a567f706130c178a457/src/Html/Lazy.elm |
| EL-VDOM | `src/Elm/Kernel/VirtualDom.js` — thunk and diff implementation | https://github.com/elm/virtual-dom/blob/79d31f5889930aa5d0d8e874a0807076d5c16891/src/Elm/Kernel/VirtualDom.js |
| EL-GUIDE-ARCH | Guide page, The Elm Architecture | https://guide.elm-lang.org/architecture/ |
| EL-GUIDE-FX | Guide page, Commands and Subscriptions | https://guide.elm-lang.org/effects/ |
| EL-GUIDE-PORTS | Guide page, Ports | https://guide.elm-lang.org/interop/ports.html |
| EL-GUIDE-TIME | Guide page, Time | https://guide.elm-lang.org/effects/time.html |

Eta Crux context is the current delivery baseline, the typed-projection map,
and the semantic laws. Those files are local project sources.

## Rust Crux view projection

Documented in RX-APP and RX-BOOK-ARCH.

The `App` trait has two functions. `update` mutates the model and returns a
`Command`. `view` returns the current state of the user interface
(RX-APP, `App` trait and `view` doc, lines 255-286).

The book states that the view model is a step between the model and the UI.
The UI on screen is a projection of the model
(RX-BOOK-ARCH, lines 9-10).

Source in RX-CORE.

`Core::view` reads the model under a `std::sync::RwLock` read lock and calls
`app.view(&model)` (lines 171-175). Each pull recomputes the view model. The
core does not retain a serialized or cached view model. The core owns the
model. The shell owns the last view model it pulled. The read lock waits
while a writer holds the model lock. The pull is synchronous and can block on
that lock.

The `ViewModel` type is a serializable value. The counter example derives
`Facet`, `Serialize`, `Deserialize`, and `Clone` on it
(RX-APP-EX, lines 29-32).

Inference. The view projection is a complete whole-model output. It is not a
per-projection delivery. There is no projection identity and no projection
subscription.

### Matrix: view projection

| Field | Fact | Class |
|---|---|---|
| Trigger | Shell calls `Core::view` or `Bridge::view` at any time | Source, RX-CORE `view` |
| Initial replay | None from the core. The React shell pulls once at boot | Source, RX-TS `initialize` |
| Removal or disposal | None. There is no observer or subscription | Documented absence |
| Batching or coalescing | None. Each pull computes one fresh view model | Source, RX-CORE `view` |
| Order | Pull reads the model at call time. It sees the state at that time | Source, RX-CORE `view` |
| Backpressure | No consumer-driven delivery backpressure. The synchronous pull can wait for the model write lock | Source, RX-CORE `view` |
| Reconnection or reactivation | Not applicable. Pull has no session state | Inference |
| Latest-value owner | Core model under `RwLock`. The shell owns the last pulled view model | Source, RX-CORE |
| Transferable semantics | Complete output recomputed from the latest state, on demand | Inference |
| Non-transferable semantics | Recompute instead of retained committed output. No commit identity on the pull | Inference. Conflicts with `D-07` retention |

## Rust Crux render notification

Documented in RX-RENDER.

`RenderOperation` is a unit struct. Its `Output` type is `()` (lines 10-17).
`render_builder` and `render` signal to the shell that a redraw of the UI is
needed (lines 19 and 50). The book calls this "notifying the shell that a
new view model is available" (RX-BOOK-SHELL, lines 20-21).

Source in RX-CTX and RX-CORE.

`Command::notify_shell` creates a request that resolves never. The request
carries the operation and a `RequestHandle::Never`
(RX-CTX, `notify_shell`, lines 42-54, and RX-REQ, `resolves_never`, lines 38-43).
The effect is sent immediately. The call returns immediately
(RX-CTX, lines 42-54).

The core drains the command runtime and returns every effect request from one
update cycle in one `Vec` (RX-CORE, `process`, lines 144-163).

Every counter event variant mutates the model and returns `render()`
(RX-APP-EX, `update`, lines 44-52). The example does not show an event that
leaves the model unchanged.

Inference. The render notification is fire-and-forget. It carries no view
model and no commit or revision identity. The shell cannot acknowledge it.

### Matrix: render notification

| Field | Fact | Class |
|---|---|---|
| Trigger | `update` returns a command that includes `render()` | Documented, RX-RENDER |
| Initial replay | None. No automatic render at core start | Source, RX-CORE |
| Removal or disposal | None. A notification is never stored | Source, RX-REG |
| Batching or coalescing | One `Vec` of effects per core call. No dedup of render effects | Source, RX-CORE `process` and RX-BRIDGE `process_effects` |
| Order | Not documented. Tasks run as a `FuturesUnordered`-like set | Documented, RX-RFC-CMD lines 174-177 |
| Backpressure | None. Effect and event channels are unbounded | Documented, RX-CMD lines 308-311 |
| Reconnection or reactivation | Not applicable | Inference |
| Latest-value owner | The core model. The notification itself carries no value | Source, RX-CORE |
| Transferable semantics | A notice that a new output exists, separate from the output value | Inference |
| Non-transferable semantics | No acknowledgment. No payload. No per-notification identity | Inference. Conflicts with the map delivery token |

## Rust Crux serialized bridge behavior

Documented in RX-BRIDGE and RX-BOOK-SHELL.

`Bridge` wraps a `Core` and presents the same interface in serialized form.
The shell sees three methods: `update`, `resolve`, and `view`
(RX-BOOK-SHELL, lines 36-40).

Source in RX-BRIDGE.

`Bridge::update` deserializes the event, runs `Core::process_event`, registers
each effect with the `ResolveRegistry`, and serializes one `Vec<Request>`
(lines 145-155 and 238-254). `Bridge::resolve` resumes a stored request by
`EffectId`, runs the core, and returns follow-up requests (lines 198-209).
`Bridge::view` serializes the current view model (lines 261-266).

Each `Request` carries an `id` and the effect payload (lines 47-55). The wire
batch is `Requests( Vec<Request> )` with a transparent serde wrapper
(lines 69-73). `BincodeFfiFormat` is the default format. `JsonFfiFormat` also
exists (lines 11 and 76-84).

`EffectId` ids ascend and are never reused. A resolved id stays unusable
(RX-REG, lines 11-21). A request that resolves never is not stored in the
registry. The source comment states that storing one keeps an entry that
nothing ever removes (RX-REG, lines 80-89).
A `Once` entry turns into `Never` on resolution and is dropped
(RX-REG, lines 122-127).

Source in RX-SERDE.

`ResolveSerialized` has three states: `Never`, `Once`, and `Many` (lines
20-25). `Never` resolution returns `ResolveError::Never` (lines 28-31).

Documented in RX-RFC-ROUTER.

The serialized lane keeps bridge-like behavior. A request is registered with
an id, the shell receives bytes, the shell resolves with id and bytes, and
the registry resumes the right suspended request (lines 136-147).

The FFI example exposes exactly the three methods
(RX-FFI, lines 35-67).

The order of effects inside one batch is not a documented contract. The
`Command` runtime runs tasks like a `FuturesUnordered` set. The RFC states
that tasks run in the order they get woken up (RX-RFC-CMD, lines 174-177).

### Matrix: serialized bridge behavior

| Field | Fact | Class |
|---|---|---|
| Trigger | Shell calls `update` with serialized bytes, or `resolve` with an id and bytes | Documented, RX-BOOK-SHELL |
| Initial replay | None. The shell pulls the initial view separately | Source, RX-TS `initialize` |
| Removal or disposal | Registry entries drop on resolution. Notifications are never stored | Source, RX-REG |
| Batching or coalescing | All requests from one core call serialize as one batch | Source, RX-BRIDGE `process_effects` |
| Order | Ids ascend and are never reused. Order inside a batch is not documented | Source, RX-REG |
| Backpressure | None. The bridge buffers are caller-owned. Core channels are unbounded | Documented, RX-CMD lines 308-311 |
| Reconnection or reactivation | None. No session concept in the bridge | Documented absence |
| Latest-value owner | Core model. Registry holds outstanding resolvable requests | Source, RX-CORE and RX-REG |
| Transferable semantics | One batch of requests per call, with ascending non-reused ids | Inference |
| Non-transferable semantics | No delivery acknowledgment. No session identity. No ordering law across calls | Inference. Conflicts with `W-02` sequence law |

## Rust Crux notification-then-pull

Documented in RX-BOOK-BASIC.

The book states that the shell calls the `view` function when ready
(RX-BOOK-BASIC, lines 179-181). The `render()` call returns a `Command`,
which `update` passes on to the caller (lines 175-177).

Source in RX-TS and RX-TUI.

The React shell `update` method sends the event, receives the serialized
request batch, and processes each effect. The `Render` arm calls
`this.setState(this.view())`. The shell pulls the view model when it handles
a render notification (RX-TS, lines 56-75). At boot the shell pulls the
initial view model once (RX-TS, lines 35-39).

The TUI shell processes each effect from `process_event`. The `Render` arm
does nothing. A comment states that the shell re-renders on the next loop
iteration. The `render` method pulls `core.view()` on every draw
(RX-TUI, lines 89-97 and 100-105).

Inference. The render notification is a notice. The pull is a separate call.
Two render notifications in one batch cause two view pulls. The core does not
coalesce them. A shell can coalesce the draws itself, as React does through
state assignment.

### Matrix: notification-then-pull

| Field | Fact | Class |
|---|---|---|
| Trigger | Render effect in the request batch | Source, RX-TS `processEffect` |
| Initial replay | Shell pulls the initial view at boot | Source, RX-TS `initialize` |
| Removal or disposal | None | Documented absence |
| Batching or coalescing | Shell-side coalescing only. React assigns state, and the TUI draws per frame | Source, RX-TS and RX-TUI |
| Order | Pull happens after the update that produced the notice | Source, RX-CORE and RX-TS |
| Backpressure | None | Documented, RX-CMD |
| Reconnection or reactivation | Not applicable | Inference |
| Latest-value owner | The pull reads the core model at pull time | Source, RX-CORE `view` |
| Transferable semantics | Notice without payload, followed by a pull of the latest complete output | Inference |
| Non-transferable semantics | Pull recomputes a projection. No atomic commit snapshot on the pull | Inference. Conflicts with `D-08` |

## Elm whole-program view publication

Documented in EL-GUIDE-ARCH and EL-GUIDE-FX.

An Elm program has three parts: Model, View, and Update. View is a way to
turn state into HTML (EL-GUIDE-ARCH). The runtime figures out how to render
`Html` efficiently, decides what changed, and computes the minimal DOM
modification (EL-GUIDE-FX, sandbox section).

Documented in EL-BROWSER.

`Browser.element`, `document`, and `application` take a record with `init`,
`view`, `update`, and `subscriptions` (EL-BROWSER, lines 104-112, 122-130,
and 207-217). `Browser.sandbox` adds no commands or subscriptions (lines
63-75).

Source in EL-BROWSER-JS and EL-PLATFORM.

`_Platform_initialize` decodes flags, runs `init`, builds the stepper, and
enqueues the initial effects and subscriptions (EL-PLATFORM, lines 35-55).
`sendToApp` runs `update`, passes the new model to the stepper, then
enqueues the new effects and the new subscription bag
(EL-PLATFORM, lines 45-51). The stepper invocation precedes the effects
enqueue. A browser stepper defers the actual draw to an animation frame. The
draw does not synchronously precede the effects.

`_Browser_makeAnimator` draws the initial model immediately (EL-BROWSER-JS,
line 112). A draw calls `view(model)`, diffs the new vdom against the old,
and applies the patches (EL-BROWSER-JS, lines 47-53 and 79-89).

The animator state machine has `NO_REQUEST`, `PENDING_REQUEST`, and
`EXTRA_REQUEST`. An async model update requests one animation frame. A second
update before that frame marks an extra request. The frame draws the latest
model and then returns to `NO_REQUEST` (EL-BROWSER-JS, lines 110-135).

Source in EL-SCHED.

The scheduler runs one FIFO queue of processes. It processes each process
step until the process suspends (EL-SCHED, lines 131-148 and 151-194).

Inference. The stepper invocation is ordered per update. Draws coalesce per
animation frame to the latest model. Intermediate models are not drawn.

### Matrix: whole-program view publication

| Field | Fact | Class |
|---|---|---|
| Trigger | After each `update` and once after `init` | Source, EL-PLATFORM `sendToApp` |
| Initial replay | The animator draws the initial model immediately | Source, EL-BROWSER-JS |
| Removal or disposal | None. The whole view is replaced by diff | Documented absence |
| Batching or coalescing | Draws coalesce per animation frame. The latest model wins | Source, EL-BROWSER-JS animator |
| Order | Update runs, then the stepper invocation, then effects. An asynchronous stepper defers the draw to a frame | Source, EL-PLATFORM and EL-BROWSER-JS |
| Backpressure | None. The scheduler queue is unbounded | Source, EL-SCHED |
| Reconnection or reactivation | Not applicable | Inference |
| Latest-value owner | Runtime `model` variable and the animator `currNode` | Source, EL-PLATFORM and EL-BROWSER-JS |
| Transferable semantics | A pure whole-model view function with runtime-owned diff | Inference |
| Non-transferable semantics | Animation-frame timing. DOM patching as publication | Inference |

## Elm subscriptions

Documented in EL-SUB and EL-GUIDE-FX.

A subscription tells the runtime to watch an event source and turn events
into messages. The runtime manages the details. The Sub module states that
Elm manages reconnection itself for sources like web sockets
(EL-SUB, lines 33-43).

The program supplies `subscriptions : Model -> Sub msg`. The runtime
re-evaluates it after each update and once after init
(EL-PLATFORM, lines 49 and 52).

Documented in EL-GUIDE-TIME.

`Time.every` is the basic subscription pattern. You give a configuration and
a function that turns the current time into a message.

Source in EL-EVENTS and EL-TIME.

The platform groups the re-evaluated bag by manager. It sends each manager
only its own subscriptions (`_Platform_gatherEffects`, EL-PLATFORM, lines
273-297). The platform performs no keyed diff itself. Each manager
reconciles its own list in `onEffects`.

`Browser.Events` keys its list by the node prefix plus the event name (lines
330-340). A key present only in the old list kills the process. A key present
in both keeps the process. A key present only in the new list spawns a
process (EL-EVENTS, `onEffects`, lines 304-323).

`Time.every` keys by interval. It spawns a timer per new interval and kills
timers for removed intervals (EL-TIME, `onEffects`, lines 457-483). Each
tick reads the current time and sends one message per tagger for that
interval (lines 514-527).

Source in EL-EVENTS.

`onSelfMsg` applies the current decoder from the current subscription list.
A kept process uses the newest decoder for the same key
(EL-EVENTS, lines 289-302).

### Matrix: subscriptions

| Field | Fact | Class |
|---|---|---|
| Trigger | Re-evaluated after each `update` and once after `init` | Source, EL-PLATFORM |
| Initial replay | The initial subscription bag runs after init | Source, EL-PLATFORM |
| Removal or disposal | Browser.Events and Time kill processes for keys removed from their lists | Source, EL-EVENTS and EL-TIME |
| Batching or coalescing | One `onEffects` call per manager per round, with that manager's new list | Source, EL-PLATFORM dispatch |
| Order | Messages reach `update` in scheduler FIFO order | Source, EL-SCHED |
| Backpressure | None. The scheduler queue is unbounded | Source, EL-SCHED |
| Reconnection or reactivation | For Browser.Events and Time, an unchanged key keeps the process. A new key kills and respawns | Source, EL-EVENTS and EL-TIME |
| Latest-value owner | The effect manager process and its state | Source, EL-EVENTS and EL-TIME |
| Transferable semantics | Manager-local subscription reconciliation with explicit add and remove | Inference |
| Non-transferable semantics | JS event listeners as transport. No delivery acknowledgment | Inference |

## Elm ports

Documented in EL-GUIDE-PORTS.

Ports allow communication between Elm and JavaScript. An outgoing port is a
function of type `value -> Cmd msg`. An incoming port is a function of type
`(value -> msg) -> Sub msg`. Values that cross ports are the same types that
work with flags. Sending `Json.Encode.Value` through ports is recommended.

All port declarations must appear in a `port module`. Ports exist in
applications, not in packages. The compiler dead-code-eliminates unused
ports.

Source in EL-PLATFORM.

An outgoing port is an effect manager with a command map. `onEffects`
iterates the gathered command list, converts each value, and calls every
subscribed JavaScript callback once per command (EL-PLATFORM, lines 363-411).
JavaScript subscribes and unsubscribes callbacks by reference (lines 390-405).
`_Platform_insert` prepends each gathered command to the manager list (lines
319-328). The delivered order is therefore the reverse of the bag traversal
order. That order is not documented.

An incoming port is an effect manager with a subscription map. `onEffects`
replaces the stored subscription list (lines 449-453). A JavaScript call to
`send` decodes the value and sends one message per subscription to the app
(lines 457-468).

Documented in EL-CMD.

`Cmd.batch` hands each command to the runtime at the same time. The doc
states that there are no ordering guarantees about the results
(EL-CMD, lines 58-69).

### Matrix: ports

| Field | Fact | Class |
|---|---|---|
| Trigger | Outgoing: a `Cmd` from `update` or `init`. Incoming: a JavaScript `send` call | Documented, EL-GUIDE-PORTS. Source, EL-PLATFORM |
| Initial replay | Outgoing: init commands run once. Incoming: none | Source, EL-PLATFORM |
| Removal or disposal | Outgoing: JavaScript unsubscribes by reference. Incoming: subscription list replacement | Source, EL-PLATFORM |
| Batching or coalescing | Outgoing: one call per command in the list. Incoming: one message per subscription | Source, EL-PLATFORM |
| Order | Outgoing: not documented. The manager iterates the gathered list, which `_Platform_insert` builds by prepending. Incoming: JavaScript call order | Source, EL-PLATFORM |
| Backpressure | None | Source, EL-SCHED |
| Reconnection or reactivation | Incoming port replaces its subscription list on each `onEffects` call | Source, EL-PLATFORM |
| Latest-value owner | None. No retained latest value. Each outgoing value reaches the JavaScript callbacks individually. Each incoming value becomes individual messages | Source, EL-PLATFORM |
| Transferable semantics | Whole-value command and subscription boundaries | Inference |
| Non-transferable semantics | JSON-only values. No delivery acknowledgment. No ordering law for results | Documented, EL-GUIDE-PORTS and EL-CMD |

## Elm per-projection observation contract

Documented absence.

The program boundary is the whole model. `view` takes the whole model,
`update` takes the whole model, and `subscriptions` takes the whole model
(EL-BROWSER, lines 104-112). No documented API observes one projection of the
model.

`Html.lazy` is the closest mechanism. Documented in EL-LAZY.

`lazy` bundles a function and its arguments for later. During diffing, the
runtime checks whether all arguments are equal by reference. If so, it skips
calling the function (EL-LAZY, lines 9-12 and 25-32).

Source in EL-VDOM.

A lazy node is a thunk holding `__refs` and a `__thunk` (lines 160-168).
The diff compares every reference with strict JavaScript equality. Equal
references reuse the old node. Unequal references run the thunk and diff the
subtree (lines 752-770).

Inference. `Html.lazy` is a diff-skipping memoization inside the whole view
diff. It does not create a delivery. It does not push values. It does not
give a projection identity. It is not an observation contract.

`Html.map`, `Cmd.map`, and `Sub.map` transform messages. They do not create
per-projection observation (EL-CMD, lines 83-85, and EL-SUB, lines 82-84).

### Matrix: per-projection observation contract

| Field | Fact | Class |
|---|---|---|
| Trigger | None. There is no projection observation | Documented absence |
| Initial replay | None | Documented absence |
| Removal or disposal | None | Documented absence |
| Batching or coalescing | `Html.lazy` skips subtree diff on equal references | Source, EL-VDOM |
| Order | Diff order within the whole-program draw | Source, EL-VDOM |
| Backpressure | None | Source, EL-SCHED |
| Reconnection or reactivation | Not applicable | Inference |
| Latest-value owner | The runtime model and vdom | Source, EL-PLATFORM |
| Transferable semantics | Reference-equality cutoff as an application-owned optimization | Inference |
| Non-transferable semantics | A per-projection observation contract. Lazy is not a delivery path | Inference. Conflicts with the typed projection map |

## Comparison with the Eta Crux ownership seam

The map requires Eta Crux to own stabilization, atomic commit, delivery
order, serialized sessions, and delivery acknowledgment. The driver stays the
only transport writer ([`map.md`](../../../docs/wayfinder/eta-crux-typed-projection-delivery/map.md) lines 16-17).

| Map or baseline requirement | Rust Crux fact | Elm fact | Comparison |
|---|---|---|---|
| Stabilization and atomic commit (`T-04`) | No commit frame. `update` mutates the model directly | No commit frame. `update` returns a new model | Neither has an atomic commit boundary |
| One complete root output per commit (`T-03`) | One complete view model per pull | One complete view per draw | Both publish complete outputs. Neither publishes per commit |
| Latest committed output pull (`O-01`, `D-07`) | `view` recomputes from the model | Runtime owns the model | Pull exists. Retained committed snapshot does not |
| Delivery after commit (`O-02`) | Notice after update, pull on demand | Stepper runs after update. Draw is deferred to a frame | Both publish after update. No commit fence |
| Delivery acknowledgment (map) | None. Notifications resolve never | None | Gap. Eta Crux keeps the delivery token |
| Delivery order (map) | No documented effect order. Ascending non-reused ids | FIFO process queue. No order law for command results | Gap. Eta Crux owns delivery order and sequence numbers |
| Serialized sessions (map) | No session concept | No session concept | Gap. Eta Crux owns session replacement |
| Driver is the only transport writer | Shell pulls the view. Shell resolves requests | Runtime owns effects | Compatible in shape. The pull owner differs |

The baseline report states that no inspected source selects a next public
interface ([`current-eta-crux-delivery-baseline.md`](./current-eta-crux-delivery-baseline.md) lines 452-453). This report makes no selection either.

## What Eta Crux can transfer

1. Notice without payload, followed by a pull of the latest complete output.
   Rust Crux renders this way. The pull owner in Eta Crux is the driver
   latest committed output.
2. One batch of requests per advancement. The core drains its runtime and
   returns all effects from one update cycle together.
3. Ascending, non-reused request ids across one bridge.
4. A notification that carries no value and is not stored. The registry
   keeps only resolvable requests.
5. Manager-local subscription reconciliation. Browser.Events and Time key
   their lists and reuse or replace processes on add, keep, and remove.
6. A whole-model view as the application-owned projection. Application code
   decides what the output contains.
7. A runtime that only runs when the shell drives it. The core does nothing
   without a shell call.

## What Eta Crux cannot transfer

1. Missing delivery acknowledgment. Rust Crux renders resolve never. Elm
   effects have no acknowledgment. Eta Crux requires a delivery token
   (`T-05`).
2. A pull that recomputes a projection. Rust Crux recomputes the view model
   at pull time. Eta Crux retains one complete committed output (`D-07`).
3. Unbounded queues as the transport. Rust Crux channels and the Elm
   scheduler queue are unbounded. Eta Crux has explicit ingress and request
   capacities (`A-09`).
4. Animation-frame batching. The Elm animator coalesces draws per browser
   frame. Eta Crux owns delivery order, not browser timing.
5. The absence of a per-projection observation contract. The typed
   projection map requires projections with delivery contracts.
6. The absence of session identity. Rust Crux and Elm have no session
   replacement. Eta Crux owns serialized sessions (`W-08`).
7. Direct model mutation as publication. Rust Crux mutates the model inside
   `update`. Eta Crux commits one complete root frame (`T-04`).
8. JavaScript event listeners and DOM patching as the delivery path.
9. Concurrent effect order as a public contract. Rust Crux tasks run as a
   `FuturesUnordered`-like set. The order is not documented.

## Inform later comparison

The typed-projection map requires a later comparison of four designs. Rust
Crux and Elm map onto those designs as follows.

### Complete-output delivery

Rust Crux returns one complete view model per pull. Elm renders one complete
view per frame.

Both match current Eta Crux in shape. One advancement still publishes one
complete root output.

Neither carries a commit or revision identity on the delivered value.

### Notification followed by pull

Rust Crux implements notification-then-pull exactly. The render effect
carries no payload. The shell pulls the view model separately.

Elm has no separate notice channel. The stepper invokes the view function
after each update. An asynchronous browser stepper defers the draw to a
frame.

If Eta Crux uses notice-then-pull, the notice must follow the commit and the
pull owner must be the driver latest committed output.

### Independent streams

Rust Crux has one view projection. Effects are request streams, not
projection streams.

Elm subscriptions are independent event sources. Each subscription produces
messages, not projections.

Independent projection streams give no atomic observation of several
changed values. The map serialized session order requires one delivery
order.

### Application effects

Elm ports are the application-effect boundary. They are `Cmd` and `Sub`
boundaries with JSON-compatible values.

Rust Crux treats the UI update as a shell effect.

Application effects as delivery make the driver not the only writer. The map
forbids that.

## Remaining uncertainty

1. The live Crux book is generated from master. The `STABLE_REF` file at
   master names `crux_core-v0.20.0`. The book content and the tag source are
   identical, so this report cites both revisions.
2. Code anchors in `crux_core` reference `docs/internals/runtime.md` and
   `docs/internals/bridge.md`. Those files do not exist in the repository at
   the tag or at master. The anchors point at planned documentation.
3. The Elm guide has no published revision pin. Live pages are the
   authority. The guide content can change after this report.
4. elm/time master differs from the 1.0.0 tag only in doc comments. This
   report cites the released 1.0.0 tag.
5. This report did not run Rust Crux tests, Elm builds, or a browser
   runtime. Source behavior claims come from reading the code.
6. The animator coalescing behavior depends on browser scheduling. The state
   machine is source behavior. The exact frame timing is environment
   behavior.
7. Rust Crux changed its API across releases. This report cites the current
   `crux_core-v0.20.0` surface. Older reports and the older `AppCore`
   interface are history.
8. The sibling reports live on `master`. The links in this report resolve
   after this branch merges.

## Self-check

Mode: pragmatic Simplified Technical English. Text class: descriptive.

Chosen nouns: notice, notification, pull, output, batch, subscription,
projection, session, acknowledgment. Chosen verbs: notify, pull, publish,
deliver, commit, subscribe, resolve.

No procedure steps. No `should`, `would`, `may`, `might`, or `could` in
report prose. No semicolon in report prose.

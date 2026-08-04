# Bonsai and Rust Crux testing surfaces (primary sources)

Status: research for Wayfinder issue
`docs/wayfinder/eta-crux-first-principles/issues/12-testing-contract.md`.

This note records **public test APIs** and **representative tests** from first-party
sources only. It audits provisional Eta Crux test ideas against those sources.
Provisional ideas are not settled law.

## Source inventory

### Bonsai / Jane Street

| Source | Path / URL | Identity |
|---|---|---|
| Bonsai core | `/home/ribelo/projects/github/bonsai` | commit `1e4682c1312e737aa94554139a28ebcd0c077bd6` (`v0.18~preview.130.100+614`), remote `https://github.com/janestreet/bonsai` |
| Driver API | `src/driver/bonsai_driver.mli`, `src/driver/bonsai_driver.ml` | production advancement surface |
| Instrumentation | `src/driver/instrumentation.mli` | `default_for_test_handles` |
| Lifecycle | `src/private_base/lifecycle.mli` | activation / deactivation / display hooks |
| README test pitch | `README.md` | `Handle` / expect-test demo; links `bonsai_test` |
| Test package | `/home/ribelo/projects/github/oxmono/opam/bonsai_test` | opam homepage `https://github.com/janestreet/bonsai_test` (local oxmono checkout; no git SHA) |
| Handle / Result_spec | `bonsai_test/proc.mli`, `bonsai_test/proc.ml` | public test harness |
| Test driver wrapper | `bonsai_test/driver.mli`, `bonsai_test/driver.ml` | thin wrapper over `Bonsai_driver` |
| Self-tests | `bonsai_test/of_bonsai_itself/*` | lifecycle, assoc path, stabilization, effects, races |
| Clock | `/home/ribelo/projects/github/oxmono/opam/bonsai_concrete/ui_time_source/ui_time_source.mli` | `create`, `advance_clock`, `advance_clock_by`, `now` |
| Effect testing | `/home/ribelo/projects/github/oxmono/opam/virtual_dom/ui_effect/src/ui_effect_intf.ml` | `Effect.For_testing.Query_response_tracker` |
| Web test docs | `/home/ribelo/projects/github/oxmono/opam/bonsai_web/docs/how_to/testing.md` | official how-to; also `https://github.com/janestreet/bonsai_web/blob/master/docs/how_to/testing.md` |
| Runtime loop docs | `bonsai_web/docs/how_to/bonsai_runtime.md` | frame phases |
| Web test package | `/home/ribelo/projects/github/oxmono/opam/bonsai_web_test` | `Handle.click_on`, `input_text`, RPC stubs, vdom lint |
| Bench scenarios | `bonsai/bench_scenario/bonsai_bench_scenario.mli` | inject / recompute / clock for perf, not unit tests |

### Rust Crux

| Source | Path / URL | Identity |
|---|---|---|
| Crux monorepo | `/home/ribelo/projects/github/crux` | commit `1cc20871de1a039ffbea13cadb68dabe60db6214`, remote `https://github.com/redbadger/crux/` |
| App trait | `crux_core/src/lib.rs` | `App::update`, `App::view` |
| Production core | `crux_core/src/core/mod.rs` | `Core::process_event`, `Core::resolve`, `Core::view` |
| Request resolve | `crux_core/src/core/request.rs`, `resolve.rs` | one-shot / many-shot handles |
| Test harness | `crux_core/src/testing.rs` | `AppTester`, `Update`, `assert_effect!` (legacy-friendly) |
| Testing guide | `docs/src/guide/testing.md` | published as `https://redbadger.github.io/crux/guide/testing.html` |
| Effects guide | `docs/src/guide/effects.md` | managed effects; command inspect APIs |
| Runtime internals | `docs/src/internals/runtime.md` | executor; process_event/resolve as transaction |
| Core tests | `crux_core/tests/{testing,capability_orchestration,capability_runtime,middleware,json_bridge}.rs` | harness + production Core |
| Command unit tests | `crux_core/src/command/tests/*.rs` | race / cancel / composition |
| Example tests | `examples/counter/shared/src/app.rs`, `examples/notes/shared/src/app.rs` | production `App::update` + effect resolve |
| Time capability tests | `crux_time/tests/{time_test,cancellation}.rs` | timer request/resolve |
| HTTP test helpers | `crux_http/src/testing/{mod,response_builder,fake_shell}.rs` | `ResponseBuilder`; crate-private `FakeShell` |

Related prior Eta research (not a primary source for claims here):
`.scratch/research/eta-crux/reference-semantics.md`.

---

## 1. Bonsai testing surface

### 1.1 Package split

- **Computation core** (`bonsai`) ships the production driver
  (`Bonsai_driver.create`, `flush`, `result`, `trigger_lifecycles`,
  `schedule_event`).
- **Unit-test package** (`bonsai_test`) ships `Handle` and `Result_spec` over that
  driver. README points to
  `https://github.com/janestreet/bonsai_test` and web docs in `bonsai_web`.
- **Web adapter tests** (`bonsai_web_test`) re-export `Handle` / `Result_spec` and
  add VDOM interaction, lint, RPC connectors, and async flush.

Transferable lesson: test helpers sit **beside** the production driver. They do
not replace advancement.

### 1.2 Construction: ordinary computation + Result_spec

Public construction (`bonsai_test/proc.mli`):

```ocaml
Handle.create
  ?start_time ?optimize
  (result_spec : ('result, 'incoming) Result_spec.t)
  (local_ Bonsai.graph -> 'result Bonsai.t)
  -> ('result, 'incoming) Handle.t
```

`Result_spec.S` is a small first-class module:

- `type t` — root result type
- `type incoming` — values the test injects
- `val view : t -> string` — canonical printable output
- `val incoming : t -> incoming -> unit Effect.t` — map inject value to an effect

Helpers: `Result_spec.sexp`, `string`, `invisible`, `No_incoming`.

`Handle.create` (`proc.ml`):

1. Builds a private `Time_source.create ~start`.
2. Wraps the user computation so the driver result is
   `(result, lazy view, inject)`.
3. Calls `Driver.create` → `Bonsai_driver.create` with
   `Instrumentation.default_for_test_handles ()`.
4. Registers cleanup that invalidates Incremental observers.

Ordinary application construction is preserved: the test passes the same
`graph -> 'a Bonsai.t` shape production uses. Input from the outside is usually
a `Bonsai.Expert.Var.t` (docs `testing.md`), not a second app type.

### 1.3 Advancement = production frame, exposed in pieces

Driver main loop comment (`bonsai_driver.mli`):

1. `flush` — dequeue events and process actions
2. `result` — read the computed value
3. `trigger_lifecycles` — deactivations, activations, after-display

`Handle.recompute_view` (`proc.ml`) is exactly:

```ocaml
Driver.flush handle;
let computed, _, _ = Driver.result handle in
simulate_diff_patch computed;  (* optional hook between result and lifecycle *)
Driver.trigger_lifecycles handle
```

Higher helpers:

| API | Role |
|---|---|
| `show` / `show_into_string` | one frame + print `Result_spec.view` |
| `show_diff` | frame + patdiff against last stored view |
| `store_view` | frame + store without print |
| `recompute_view_until_stable` | loop while `has_after_display_events` (default max 100) |
| `do_actions` | schedule inject effects; **does not** recompute until next frame |
| `advance_clock` / `advance_clock_by` | test clock only; needs a later recompute |
| `last_result` | typed result after last flush |

Web docs call `recompute_view` “one frame of the Bonsai runtime”
(`bonsai_web/docs/how_to/testing.md`). Runtime doc
(`bonsai_runtime.md`) expands production order: clock flush → action application
(with per-action stabilize when needed) → stabilize → before_display → DOM patch
→ after_display / on_change.

**Support for “separately exposed driver phases”:** strong in Bonsai. Tests and
the production driver share named steps. Tests can also pass
`?simulate_diff_patch` between result and lifecycle (adapter-reconciliation
slot).

**Support for “one harness over production Root/Driver”:** strong. Test
`Driver.t` holds a `Bonsai_driver.t` and reroutes flush/result/lifecycle
(`bonsai_test/driver.ml`).

### 1.4 Action injection

`Handle.do_actions handle [incoming; ...]` maps each value through
`Result_spec.incoming`, sequences effects, and `schedule_event`s them. Actions
sit in the production action queue until `flush`.

Representative pattern (`testing.md` state-test; same shape in
`test_action_stabilization.ml`): custom `Result_spec` that pairs model with
inject function; `do_actions` then `show`.

Web layer adds host-event injection without a second runtime:
`Handle.click_on`, `input_text`, `keydown`, … (`bonsai_web_test/proc.mli`).
These fire VDOM listeners, which schedule the same effects.

### 1.5 Effect handling

Bonsai does **not** stage shell-style effect requests for the test to resolve by
default. `Ui_effect` runs inside the process:

- sync functions complete immediately
- deferred / svar-based effects complete when filled
- inject-into-state-machine effects enqueue actions for the next flush

Test control uses **dependency substitution**, not a second effect runtime:

```ocaml
Effect.For_testing.Query_response_tracker.create ()
Effect.For_testing.of_query_response_tracker qrt
Query_response_tracker.maybe_respond qrt ~f:(...)
Query_response_tracker.queries_pending_response qrt
```

(`ui_effect_intf.ml` `For_testing`). Representative use:
`bonsai_test/of_bonsai_itself/test_effect_throttling.ml` — tracker as effect
source, `do_actions`, `recompute_view`, selective `maybe_respond`.

**Lesson for Eta:** “real effects with controlled dependencies” matches Bonsai
better than Crux-style resolve of every effect. Crux resolve is needed because
the shell is outside the process.

### 1.6 Clock, lifecycle, assoc identity, stabilization

| Concern | Public surface / representative test |
|---|---|
| Clock | `Handle.advance_clock*`; `Time_source.create ~start` (`ui_time_source.mli`); docs clock test in `testing.md` |
| Lifecycle order | Driver: deactivate → activate → after_display; tests print effects via `Effect.print_s` in `test_with_inverted_lifecycle_ordering.ml` |
| Assoc / path identity | Private path IDs; `path_test.ml` (assoc keys, quickcheck on path alpha); effect-throttling “poll in an assoc” |
| Stabilization | `Handle.print_actions` / `print_stabilizations`; `test_action_stabilization.ml` shows skipped vs required stabilizations between actions |
| Inactive / race | expect-tests named “race inactive-delivery” in `test_cont_bonsai.ml` / `test_proc_bonsai.ml` (scenario tests, not a checkpoint DSL) |

### 1.7 Exhaustive assertions and “transcript”

Bonsai’s default exhaustive style is **expect-tests on printable view diffs**,
plus optional effect print side channels (`Effect.print_s`). There is **no**
single ordered transcript type for all events.

Optional debug instrumentation:

- `print_actions`, `print_stabilizations`, `print_stabilization_tracker_stats`
- `print_computation_structure` (skeleton sexp; internal)
- `show_model` marked `rampantly_nondeterministic` / internal alert
- Driver-only type-equality checks when path is
  `lib/bonsai/test/of_bonsai_itself` or web equivalent
  (`bonsai_driver.ml` `am_running_bonsai_test`)

Instrumentation config for test handles is **inert timers**
(`default_for_test_handles`), not a probe-event stream.

Property testing appears only for **narrow pure properties** (path ID alphabet,
clock continuation after weird schedules), not as the primary app-test DSL
(`path_test.ml`, `test_bonsai_clock_every_dynamic.ml`).

### 1.8 Adapter / host testing

- Core `bonsai_test`: host-agnostic; result is any `'a` with a string view.
- `bonsai_web_test`: adapter-specific — VDOM print, linter
  (`Siblings_have_same_vdom_key`, …), `Test_selector`, RPC implementations /
  connectors, jsdom experimental handle.
- Docs are explicit about **gaps vs production browser**: no event propagation;
  hooks/widgets do not run; Node mocks browser APIs
  (`testing.md` “Limitations”).

Transferable lesson: **canonical computation output** and **host adapter
behavior** are separate test layers. Web tests extend Handle; they do not fork
advancement.

### 1.9 What Bonsai does *not* provide

- No production Root/Driver “endpoint admission” API in the test package (that
  problem is Eta-specific).
- No typed application probe-event type.
- No named race checkpoints as framework API.
- No requirement that tests avoid property tests entirely (they use Quickcheck
  sparingly for pure helpers).
- `recompute_view_until_stable` is documented as often an **antipattern** when
  multi-frame state sync is avoidable (`testing.md`).

---

## 2. Rust Crux testing surface

### 2.1 Architecture that makes tests simple

From `crux_core` README and `docs/src/guide/testing.md`:

- Core is pure with respect to host I/O: `update` mutates `Model` and returns
  `Command<Effect, Event>` (or legacy capability side channels).
- Shell (or test) observes effects, performs work, resolves requests, may feed
  events back.
- “No need for fakes, mocks or stubs” of the **app**. The test **is** a shell
  that inspects effect **data**.

Production entry points (`core/mod.rs`):

| API | Role |
|---|---|
| `Core::process_event(event) -> Vec<Effect>` | run update + drain command executor |
| `Core::resolve(request, output) -> Result<Vec<Effect>, _>` | complete a request; drain more work |
| `Core::view() -> ViewModel` | project UI data |

Internals (`runtime.md`): one call to `process_event` or `resolve` is a
**transaction** that polls the capability/command executor until shell requests
are emitted.

### 2.2 Public test APIs

**Preferred modern path (docs + examples):** call `App::update` directly; inspect
`Command`:

- `cmd.effects()` / `events()` iterators
- `expect_one_effect()`
- generated `Effect::is_*` / `into_*` / `expect_*` filters
- `request.resolve(output)`
- `assert_effect!(cmd, Effect::Render(_))`
- `app.view(&model)` for ViewModel assertions

**Legacy helper** `crux_core::testing::AppTester` (`testing.rs`):

- `AppTester::new` / `default`
- `update(event, &mut model) -> Update { effects, events }`
- `resolve` / `resolve_to_event_then_update`
- `view`
- `Update::{expect_one_effect, expect_one_event, assert_empty, take_effects, ...}`

Docs state `AppTester` is **no longer required** after the Command API; it
remains for migration confidence.

### 2.3 Production semantics vs separate simulator

Crux does **not** ship a second app simulator with different laws.

| Mode | Used when | Semantics |
|---|---|---|
| Direct `App::update` + Command inspect | most example tests | same transition function as production; test plays shell |
| `AppTester` | older / orchestration tests | thin capability context + command spawner; still calls `app.update` |
| `Core` / `Bridge` | runtime, FFI, middleware tests | production runtime entry |
| Middleware `handle_effects_using` | in-process effect handlers | production core with layered shell substitutes |

Representative production-path tests:

- `examples/counter/shared/src/app.rs` `get_counter`: `app.update` →
  `expect_http` → `request.resolve(HttpResult::Ok(...))` → follow events →
  `assert_effect!` Render → `app.view`.
- `examples/notes/shared/src/app.rs` timer and KV tests: filter
  `Effect::into_time` / `into_key_value`, resolve `TimeResponse` /
  `KeyValueResult`, assert cancel/restart.
- Notes multi-peer helper `Peer` manually holds PubSub requests and resolves
  streams — a **local shell fake**, not a framework simulator.
- `crux_core/tests/capability_runtime.rs` uses `Core::process_event` /
  `Core::resolve` and shuffles concurrent effects.
- `crux_core/src/command/tests/async_effects.rs` `effects_race`: resolve order
  decides which `select!` branch wins — **race controlled by resolve order**,
  not named checkpoints.

### 2.4 Capability fakes and HTTP helpers

- App tests rarely implement capability traits. They inspect **operation
  payloads** on `Request<Op>`.
- `crux_http::testing::ResponseBuilder` builds typed HTTP bodies for resolve.
- `crux_http::testing::FakeShell` is **`pub(crate)`** — for the HTTP crate’s
  own tests, not the public app-test story. Public story is resolve-with-data.
- Time tests (`crux_time/tests`) assert `TimeRequest::{NotifyAfter, Clear}` and
  resolve `TimeResponse::{DurationElapsed, Cleared, Now}` without a real clock
  thread.

### 2.5 Event loops, time, lifecycle, shell testing

- **Event loop:** explicit in the test. Each `update` / `resolve` is one step.
  Streaming effects (SSE, PubSub) stay open; tests resolve multiple times.
- **Time:** effect-level, not a shared test clock. “Time passed” means the test
  resolved a timer request. (Contrast Bonsai’s `Time_source`.)
- **Lifecycle:** no Bonsai-like activate/deactivate graph. Long-lived work is
  command/capability tasks until resolved or cancelled.
- **Shell testing:** optional. Core claims unit tests replace integration tests
  for app logic. Platform shells are out of scope for `crux_core` unit tests.
  Middleware experiments process some effects inside the process while the outer
  shell still sees residual effects.

### 2.6 Exhaustive checks and property tests

- Docs use “exhaustive” to mean **high-coverage unit tests**, not a transcript
  combinator.
- Assertions are ordinary `assert_eq!`, pattern matches on operations, and
  `assert_effect!`.
- No public property-test DSL for apps. Command combinator tests are handwritten
  scenarios (`effects_race`, cancellation, composition).

### 2.7 What Crux does *not* provide

- No shared multi-phase driver like Bonsai flush/result/lifecycle (the “driver”
  is `process_event` / `resolve` / `view`).
- No host adapter reconciliation phase in the core test API (Render is just
  another effect).
- No typed probe instrumentation in production arbitration points.
- No production endpoint admission (FFI bridge has resolve-id registry; that is
  wire state, not app test law).
- Capability Compose docs note composed effects are **harder to enter mid-
  transaction** — a caution against opaque orchestration for tests.

---

## 3. Transferable semantic lessons vs framework-specific API

### Keep as semantics (both or one strong source)

| Lesson | Bonsai | Crux |
|---|---|---|
| Tests use the **same advancement / transition primitive** as production | `Bonsai_driver.flush` via Handle | `App::update` / `Core::process_event` |
| Tests construct the **ordinary app**, not a test-only app type | `graph -> 'a Bonsai.t` | `App` impl + `Model` |
| **Typed output** is the primary observation | `last_result` / `Result_spec.view` | `view` / model fields |
| **Effects are data-visible** at a test seam | inject + QRT pending queries; prints | `Command` effects + resolve |
| **Time is controlled**, not wall-clock | `Time_source` advance | resolve timer operations |
| **Host UI is optional** for logic tests | core Handle without DOM | core without shell UI |
| Prefer **scenario expect/assert tests** over a property DSL | expect-tests | unit tests |
| Multi-step async work needs an **explicit correlation path** | effect completion → action queue | `Request::resolve` → events |

### Treat as framework-specific (do not copy blindly)

| API / shape | Why local |
|---|---|
| `Result_spec` + string expect / patdiff | Bonsai/UI culture; Eta may prefer typed Alcotest |
| VDOM click/input helpers | web adapter only |
| `Query_response_tracker` | Ui_effect deferred model |
| `AppTester` | Crux legacy capabilities |
| `assert_effect!` macro / `Effect` enum filters | Crux Effect derive |
| FFI `Bridge` id registry | multi-language shell |
| `Render` as mandatory effect | shell convention; Eta can publish typed root output without Render |
| Capability crates as core surface | packaging for multi-shell I/O |

### Tension between references (important for Eta)

1. **Where effects run**
   - Bonsai: in-process effects; tests control **dependencies**.
   - Crux: effects leave the core; tests **resolve** operations.
   - Eta already has in-process Eta effects. Crux resolve is **not** required as
     the default harness shape (also noted in
     `reference-semantics.md` §6.1). Prefer Bonsai-like control of dependencies
     plus optional intercept of staged work.

2. **What “one frame” means**
   - Bonsai: multi-phase graph stabilize + lifecycle.
   - Crux: one `update`/`resolve` transaction + executor drain.
   - Eta driver (Wayfinder 06/10) is closer to Bonsai phases, with Eta post-
     commit effect start.

3. **Clock**
   - Bonsai embeds a clock in the driver.
   - Crux encodes time as capability operations.
   - Eta already owns a test clock; Bonsai’s advance-then-recompute pattern fits.

---

## 4. Audit of provisional Eta Crux test ideas

Ideas are provisional. Verdicts: **support**, **contradict**, or **unanswered**.

### 4.1 One harness over production Root/Driver

- **Bonsai: support.** Handle → test Driver → `Bonsai_driver`.
- **Crux: partial support.** Prefer direct `App::update`; `Core` is used when
  testing runtime/FFI. Not one mandatory harness type.
- **Eta note:** matches issue 12 “must use the production advancement
  primitive.” Prefer one harness over Root/Driver, with optional thin helpers
  (Crux shows helpers are optional).

### 4.2 Real Eta effects with controlled dependencies

- **Bonsai: support.** Real `Ui_effect` + substituted effect functions / QRT.
- **Crux: partial.** Effects are real **intents**; execution is fake by resolve.
  Docs boast “no mocks” of app code, not “effects run for real.”
- **Eta note:** because Eta effects run in-process, Bonsai’s dependency control
  is the better default. Crux-style pure intent inspection is still useful for
  **host requests** (issue 13), which are shell-like.

### 4.3 Separately exposed driver phases

- **Bonsai: strong support.** flush / result / lifecycle; optional mid-hook
  `simulate_diff_patch`.
- **Crux: weak / different.** Only process_event vs resolve vs view.
- **Eta note:** Wayfinder driver already has multi-phase commit/delivery; expose
  the same phases in tests. Do not invent Crux-only process/resolve as the sole
  API if Root/Driver already has richer phases.

### 4.4 Ordinary application construction

- **Both: support.**
- Bonsai: same computation function; Vars for inputs.
- Crux: same `App`, often `Model::default` or hand-built model.

### 4.5 Production endpoint admission

- **Both: unanswered** for app unit tests.
- Crux Bridge has resolve-id and serialization errors (`json_bridge.rs`), which
  are wire/session concerns, not a general test harness feature.
- **Eta note:** endpoint admission is Eta-specific (issues 13/16/18). Test it
  through the **production driver binding**, not a parallel admission engine.

### 4.6 Canonical output plus separate adapter fake

- **Bonsai: support.** Core Handle on typed/`string` result; web package adds
  VDOM + interaction separately. Runtime docs separate stabilize from DOM patch.
- **Crux: partial.** ViewModel is canonical for UI; Render effect is a signal.
  Shell fakes are ad hoc (notes `Peer`, private HTTP `FakeShell`).
- **Eta note:** strong support for typed root output assertions **plus** a
  recording adapter fake that is not the core harness.

### 4.7 Typed application probes

- **Both: unanswered** as a first-class public test type.
- Bonsai uses `Effect.print_s` and expect output, or result fields, not a probe
  channel type.
- Crux uses model/view/effect data.
- **Eta note:** optional; not required by references. If kept, keep it thin and
  caller-defined (see 4.13).

### 4.8 Eta test clock and controlled sources

- **Bonsai: support** for clock-in-driver + advance API.
- **Crux: support** for controlled **sources as effect operations** (time/http),
  not a driver clock.
- **Eta note:** use Eta test clock for time-indexed graph/sources (Bonsai-like).
  Use controlled effect/request dependencies for host I/O (both).

### 4.9 Named race checkpoints

- **Both: contradict as framework API.**
- Races are tested by **scenario order**: Bonsai multi-frame + inactive delivery
  tests; Crux resolve order in `effects_race`.
- Neither exposes “named checkpoints” as a product feature.
- **Eta note:** prefer explicit phase steps and deterministic scheduling over a
  checkpoint vocabulary unless Eta concurrency forces it. If Eta needs
  synchronization points, name them after **production arbitration points**,
  not a free-form test DSL.

### 4.10 One ordered exhaustive transcript

- **Both: contradict as single mandatory artifact.**
- Bonsai: view snapshots + optional prints; not one global transcript type.
- Crux: assert on effects/events/model per step; docs “exhaustive” means
  coverage, not a transcript combinator.
- **Eta note:** a single transcript can be a **test helper** for hard
  interleavings, but references do not require it as the primary contract.
  Prefer step-local asserts + optional recording adapter.

### 4.11 No property-test DSL

- **Bonsai: partial support.** Primary UX is expect-tests; Quickcheck exists for
  pure helpers.
- **Crux: support.** No property DSL.
- **Eta note:** “no property-test DSL” is fine as “do not invent a second
  testing language.” It should **not** ban ordinary qcheck for pure laws (Eta
  already uses law tests elsewhere). App behavior tests can stay scenario-
  based.

### 4.12 Optional inert test instrumentation in production arbitration points

- **Bonsai: partial support.** Test handles use inert instrumentation config;
  extra asserts only under `am_running_bonsai_test` path prefixes; print_* are
  opt-in and sometimes internal.
- **Crux: weak.** No probe hooks in `update`; middleware is a production
  extension point for effect handling, not test probes.
- **Eta note:** optional inert hooks at real arbitration points match Bonsai
  more than Crux. Keep them **inert by default** and avoid a second semantics
  path when probes are off (issue 12).

### 4.13 Caller-defined typed probe-event type

- **Both: unanswered.**
- Closest: Bonsai `Result_spec.incoming` (injection type, not probe output);
  Crux `Event` (production events).
- **Eta note:** if probes exist, a caller-defined type is consistent with
  Bonsai’s first-class `Result_spec` modules. Do not hard-code a framework probe
  enum.

---

## 5. Simpler and deeper alternatives suggested by the references

### Simpler (often better)

1. **Crux-simple path for pure transitions**
   When testing only model transitions and staged host requests, call the
   production update/advance and assert on typed outputs + request payloads.
   Skip a heavy harness type until multi-phase graph tests need it
   (`AppTester` deprecation lesson).

2. **Bonsai Handle shape without VDOM**
   One handle: create(root), inject, advance_one_frame, read_result,
   advance_clock. String expect is optional; typed Alcotest is enough.

3. **Recording adapter as a separate value**
   Do not fold adapter reconciliation into core advancement. Bonsai’s
   `simulate_diff_patch` is an optional hook; Crux keeps Render as data.

4. **Control races by scheduling, not checkpoint names**
   Resolve/complete work in the order under test (Crux `effects_race`; Bonsai
   multi-`recompute_view`).

### Deeper (worth the complexity when Eta needs it)

1. **Shared multi-phase advancement with test-visible seams**
   Expose the same phases production uses (Bonsai flush/result/lifecycle; Eta
   commit/delivery/post-commit). This is deeper than Crux’s single
   process_event, and matches Eta’s driver design.

2. **Two effect seams, clearly separated**
   - **In-process Eta effects:** real runtime + controlled dependencies
     (Bonsai-like).
   - **Host requests:** inspectable intent + test resolve/complete
     (Crux-like).
   Collapsing both into one “pending command handle” API over-copies Crux
   (`reference-semantics.md` warning).

3. **Identity / lifecycle / admission tests on production paths**
   Bonsai tests assoc path identity and inactive delivery against the real
   graph. Eta should test keyed identity, stale injection, and endpoint
   admission through Root/Driver, not a mock graph.

4. **Optional mid-delivery hook for adapter fakes**
   Bonsai `simulate_diff_patch` sits between result and lifecycle. Eta can
   expose an analogous hook after canonical output commit and before post-commit
   work, so adapter fakes record without forking semantics.

---

## 6. Mapping to issue 12 decision questions

| Issue 12 question | Reference guidance |
|---|---|
| Construct root with inputs and dependencies | Ordinary app construction; Vars / model setup; inject controlled effect deps |
| Inject typed actions; advance one transaction | Bonsai `do_actions` + `recompute_view`; Crux `update`/`process_event` |
| Inspect typed output and adapter reconciliation | Typed result/view first; adapter fake separate; optional mid-phase hook |
| Intercept / execute / cancel / provide effect results | Eta effects: run or substitute deps; host requests: inspect + complete |
| Control time and long-lived sources | Test clock advance (Bonsai); resolve/cancel source ops (Crux time) |
| Dynamic activation, disposal, keyed identity, stale injection | Bonsai lifecycle + path/assoc tests; Crux has little graph lifecycle |
| Failures, defects, cleanup | Both surface errors as data or prints; Eta should use production failure boundary |
| Ingress closure vs endpoint admission | Not covered by Bonsai/Crux unit harnesses; use production driver binding |
| Commit vs fatal; batch start vs stop | Bonsai phase order; Crux transaction drain; Eta driver laws |
| Primary failures, secondary records, settlement | Unanswered as a shared transcript; step asserts + optional recording |
| Exhaustive checks without internal node structure | Expect/view/effect data; avoid `show_model`/skeleton unless debugging |
| Host adapter through recording fake | Separate adapter test layer (Bonsai web vs core; Crux ad hoc shells) |

Hard constraints from issue 12 that references reinforce:

- **Use production advancement** — both.
- **Do not identify effects by anonymous function identity** — Crux uses typed
  operations; Bonsai tests pending queries by value in QRT.
- **Do not duplicate the Eta runtime** — Bonsai does not reimplement Incremental;
  Crux does not reimplement `update`.

---

## 7. Citation index (symbols and URLs)

### Bonsai

- `Bonsai_driver.{create,flush,result,trigger_lifecycles,schedule_event}` —
  `https://github.com/janestreet/bonsai/blob/1e4682c1312e737aa94554139a28ebcd0c077bd6/src/driver/bonsai_driver.mli`
- `Bonsai_test.Handle` / `Result_spec` —
  local `bonsai_test/proc.mli`; package
  `https://github.com/janestreet/bonsai_test`
- Testing how-to —
  `https://github.com/janestreet/bonsai_web/blob/master/docs/how_to/testing.md`
- `Effect.For_testing.Query_response_tracker` — `ui_effect` interface module
  `For_testing` in oxmono `virtual_dom/ui_effect`
- `Ui_time_source.{create,advance_clock,advance_clock_by,now}` — oxmono
  `bonsai_concrete/ui_time_source/ui_time_source.mli`

### Crux

- Testing guide —
  `https://redbadger.github.io/crux/guide/testing.html` (source
  `docs/src/guide/testing.md` @ `1cc20871de1a039ffbea13cadb68dabe60db6214`)
- `crux_core::testing::{AppTester,Update,assert_effect}` —
  `https://github.com/redbadger/crux/blob/1cc20871de1a039ffbea13cadb68dabe60db6214/crux_core/src/testing.rs`
- `Core::{process_event,resolve,view}` —
  `.../crux_core/src/core/mod.rs`
- `App::{update,view}` —
  `.../crux_core/src/lib.rs`
- Example tests —
  `.../examples/counter/shared/src/app.rs`,
  `.../examples/notes/shared/src/app.rs`
- Command race test —
  `.../crux_core/src/command/tests/async_effects.rs` (`effects_race`)

---

## 8. Bottom line for Eta Crux issue 12

Design the test surface as **production Root/Driver with thin helpers**, not as
a second runtime.

From **Bonsai**, take: multi-phase advancement, ordinary computation
construction, inject-then-advance, test clock, dependency-controlled effects,
typed result observation, optional adapter hook, scenario expect/assert style.

From **Crux**, take: effects/requests as inspectable data, explicit resolve of
**host** work, ViewModel-style projection, “test is a shell,” no mandatory heavy
harness, race-by-order scenarios.

Reject as required law: Crux pending-command resolve for all Eta effects; a
named race-checkpoint DSL; a single mandatory exhaustive transcript type; a
property-test language for apps; production probe types that change semantics
when enabled.

Still open (references silent or split): production endpoint admission tests,
caller-defined probe events, and how much instrumentation may live inside
arbitration points without forking semantics.

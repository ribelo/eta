# Reference semantics worth keeping for Eta Crux

Date: 2026-07-31
Ticket: [`docs/wayfinder/eta-crux-first-principles/issues/02-reference-semantics.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/02-reference-semantics.md)
Direction fixed by: [`issues/01-eta-crux-direction.md`](../../../docs/wayfinder/eta-crux-first-principles/issues/01-eta-crux-direction.md)

## Question

Which reference semantics belong in Eta Crux? Which exist only because of the
original language, renderer, runtime, or deployment boundary?

## Method

Primary sources only. Secondary blogs, talks, and memory are not evidence.
Claims in the provisional `docs/requirements/eta-crux/` bundle were checked
against those sources and classified as justified, over-copied, or
host/language-specific.

### Local checkouts

| System | Path | Commit (from checkout `refs/heads/master`) |
|---|---|---|
| Bonsai | `/home/ribelo/projects/github/bonsai` | `1e4682c1312e737aa94554139a28ebcd0c077bd6` |
| Incremental | `/home/ribelo/projects/github/incremental` | `2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6` |
| Rust Crux | `/home/ribelo/projects/github/crux` | `1cc20871de1a039ffbea13cadb68dabe60db6214` |

### Acquired into ignored scratch

| System | Path | Provenance |
|---|---|---|
| Elm `core` | `.scratch/refs/core-master/` | GitHub zip of `elm/core` master, 2026-07-31 |
| Elm `browser` | `.scratch/refs/browser-master/` | GitHub zip of `elm/browser` master, 2026-07-31 |
| Elm Architecture guide | `.scratch/refs/elm-architecture.html` | https://guide.elm-lang.org/architecture/ |
| Elm effects guide | `.scratch/refs/elm-effects.html` | https://guide.elm-lang.org/effects/ |

Package pages `Platform.Cmd` / `Platform.Sub` on package.elm-lang.org are SPA
shells (JS-rendered). Their normative text is taken from the Elm source docs in
`.scratch/refs/core-master/src/Platform/{Cmd,Sub}.elm`, which match the published
API surface (core 1.0.5 page titles).

### Also consulted (project-local, not reference frameworks)

- Direction ticket 01 (resolved).
- Provisional bundle `docs/requirements/eta-crux/*` (claims under audit, not
  authority).
- `docs/design/eta_signal-kernel-contract.md` (Eta-owned engine contract).

## Separation rules used in this report

| Layer | Meaning |
|---|---|
| **Semantic contract** | A law about state, actions, dynamic structure, effects, ordering, or observation that Eta Crux may need regardless of host language. |
| **API spelling** | Names, module layouts, combinators, macros, and type shapes (`Cmd`, `Sub`, `assoc`, `Capability`, …). |
| **Renderer / runtime machinery** | DOM frames, VDOM, display hooks, browser sandbox, JS ports, host-thread ownership of a toolkit. |
| **Serialization / FFI boundary** | Wire formats, typegen, request IDs for foreign shells, bincode/uniffi. |
| **Language ownership workaround** | Patterns forced by Rust ownership, OCaml modes, Elm purity, or multi-language shells rather than by application semantics. |

---

## 1. Bonsai — computation layer semantics

Primary evidence: `src/cont.mli`, `src/driver/bonsai_driver.mli`,
`src/private_base/{apply_action_context,lifecycle,computation}.ml(i)`,
`README.md`.

### 1.1 Semantic contracts worth keeping

1. **Composable local state machines, not one global model.**
   `state_machine` returns a model value and an inject function for a local
   action type; the framework owns model storage inside the graph
   (`cont.mli` `state_machine` / `state_machine_with_input` docs;
   `computation.ml` `Leaf0` / `Leaf1`).
   *Why for Eta Crux:* direction 01 requires composable local state and typed
   actions.

2. **Inject does not apply the action inline.**
   Injection produces a schedulable effect (`'action -> unit Effect.t`). The
   driver loop is flush (dequeue/process actions) → result → lifecycle
   (`bonsai_driver.mli` main-loop comment; `flush` / `result` /
   `trigger_lifecycles`).
   *Why:* matches direction 01 “synchronous transition” plus “deterministic
   advancement” with deferred effect delivery.

3. **Transitions may schedule work only through a restricted context.**
   `Apply_action_context` exposes inject, `schedule_event`, and time source —
   not free I/O (`apply_action_context.mli`, `cont.mli` Apply_action_context).
   *Why:* same shape as direction 01 “restricted context for staging ordinary
   Eta effects and injecting later actions.”

4. **Dynamic structure with scoped lifetime.**
   Branching (`enum` / `switch` / `match%sub`) and keyed maps (`assoc`) are
   first-class. Inactive input is explicit
   (`Computation_status.Active | Inactive`). Lifecycle is path-keyed
   (`lifecycle.mli` `Path.Map.t`).
   *Why:* direction 01 names dynamic structure, keyed composition, scoped
   lifetimes.

5. **Keyed `assoc` preserves per-key state while the key lives.**
   `assoc` builds one component instance per map entry and “maintains a state
   machine for every key-value pair” (`cont.mli` assoc docs). Internal AST has
   `Assoc`, `Assoc_on`, `Assoc_simpl` (`computation.ml`).
   *Why:* direction 01 already notes stable keyed `assoc` as the main missing
   `eta_signal` feature; this is the reference law for that feature.

6. **Lifecycle is post-structure, ordered, and effectful.**
   Driver order: deactivations, activations, after-display
   (`bonsai_driver.mli` `trigger_lifecycles`). Edge lifecycle docs order
   `before_display` → display → `on_deactivate` → `on_activate` →
   `after_display` (`cont.mli` Edge.lifecycle).
   *Keep the law “structure change implies deactivate before activate.”*
   *Do not keep* Bonsai’s browser frame/`before_display` vs DOM coupling as a
   public Eta Crux contract (renderer machinery).

7. **One root computation yields one result; the host consumes it.**
   Driver `result : 'r t -> 'r`. Bonsai README is explicit that Bonsai itself is
   generic incremental state machines; `Bonsai_web` is the browser
   specialization.
   *Why:* direction 01 “typed output; host adapters own rendering.”

### 1.2 Bonsai machinery / spelling that should not drive Eta Crux

| Item | Classification | Reason |
|---|---|---|
| `Ui_effect` / UI-time-source APIs | Runtime machinery + API spelling | Bonsai’s effect system is UI-oriented; Eta Crux uses ordinary Eta effects. |
| `before_display` / DOM frame timing | Renderer machinery | Tied to virtual-DOM frames, not application semantics. |
| `Path.t` / `path_id` for addressing | Implementation machinery | Useful internally; direction 01 forbids public path/fragment/Obj/`eta_signal` types. |
| `Actor` return-response effect, `Memo`, `Effect_throttling` | Optional API / product surface | Not required for the V1 semantic core. |
| `match%sub` PPX and autopack tuples | API spelling | Convenience, not law. |
| `assoc_on` model-key remapping | Expert escape hatch | Docs warn almost always use `assoc` (`cont.mli` Expert.assoc_on). |
| VDOM / `bonsai_web` | Renderer | Outside Eta Crux package boundary. |

### 1.3 Transition shape nuance (important for later tickets)

Bonsai’s public `apply_action` returns **only the new model**. Effects are
staged by calling `schedule_event` / `inject` on the context during the
transition. That is a different *API spelling* from Elm’s `(model, Cmd)` pair
or Rust Crux’s `Command` return, but the *semantic law* is the same: model
commit and effect execution are separated; effects run under the runtime after
the transition.

Eta Crux may spell this either as a returned staged-effect list or as a
restricted staging context. Direction 01 already chose “restricted context” +
“run staged effects only after commit.” That is Bonsai-compatible and need not
import Elm/Crux command-list vocabulary.

---

## 2. Incremental — private engine semantics

Primary evidence: `src/incremental_intf.ml` (module docs and API),
`doc/part2-dynamic.mdx`, `doc/part3-map.mdx`.

### 2.1 Semantic contracts that `eta_signal` (private engine) should preserve

These are engine laws. Direction 01 already places them under private
`eta_signal`, not the public Eta Crux programming model.

1. **Explicit stabilization boundary.**
   `Var.set` does not recompute; `stabilize` brings necessary nodes up to date
   (`incremental_intf.ml` opening docs). Matches
   `docs/design/eta_signal-kernel-contract.md` “Stabilization Boundary.”

2. **Observer demand / necessity.**
   A node is necessary iff there is a path to an observed node; stabilize
   computes only necessary nodes (`incremental_intf.ml` necessity paragraph).

3. **Cutoffs stop propagation.**
   Default physical equality; `set_cutoff` customizes
   (`incremental_intf.ml` Cutoff module docs).

4. **Dynamic scopes via bind.**
   `bind` creates dynamic dependency structure; left-hand side changes
   invalidate the previous right-hand side scope
   (`incremental_intf.ml` “Bind, scopes, and invalidation”;
   `doc/part2-dynamic.mdx`).

5. **Keyed collections are not free from `map`/`bind` alone.**
   `doc/part3-map.mdx` shows that mapping a whole `Map.t` recomputes from
   scratch; efficient keyed work needs map-diff operators (`Incr_map`).
   *Why:* justifies direction 01 “stable keyed `assoc` is the main missing
   engine feature” and rejects treating ordinary map/bind as sufficient for
   keyed UI/state collections.

### 2.2 Engine machinery not to surface as Eta Crux API

| Item | Classification |
|---|---|
| Recompute heap / adjust-heights heap / expert nodes | Implementation machinery |
| `Scope.current` / `Scope.within` as user API | Engine machinery; may stay private |
| `Incr_map` package shape and operator names | API spelling of Jane Street’s map layer |
| “Frame” vocabulary | Not an Incremental concept; Bonsai/web only |

---

## 3. Elm — unidirectional update semantics

Primary evidence: guide.elm-lang.org Architecture and Effects pages (fetched
HTML), `elm/core` `Platform.Cmd` / `Platform.Sub`, `elm/browser` `Browser.elm`.

### 3.1 Semantic contracts worth keeping (thin subset)

1. **Unidirectional loop: Model / Update / View.**
   Guide: programs break into model, view, update; computer sends messages back
   in (architecture guide).

2. **Managed effects: intent as data, runtime executes.**
   `Platform.Cmd` docs: effects treated as data given to the runtime; heart of
   testing/reuse/reproducibility. Two kinds: commands and subscriptions.

3. **Update returns new model plus commands; subscriptions are model-derived.**
   `Browser.element`:
   ```text
   update : msg -> model -> (model, Cmd msg)
   subscriptions : model -> Sub msg
   ```
   Sandbox has pure update and no Cmd/Sub (`Browser.sandbox`).

4. **Batching without cross-command result ordering.**
   `Cmd.batch`: “no ordering guarantees about the results”
   (`Platform/Cmd.elm`).

### 3.2 Elm pieces that are not Eta Crux core semantics

| Item | Classification | Reason |
|---|---|---|
| Single global model | Language / architecture default | Elm’s composition style; Bonsai/Eta Crux deliberately use local cells. |
| `Cmd` / `Sub` as *the* dual effect taxonomy | API spelling + runtime split | Useful mental model; Eta already has effects and streams. Forcing public `Cmd`/`Sub` types is vocabulary lock-in, not a law. |
| Runtime-owned HTTP/WebSocket reconnect policy | Runtime machinery | Elm runtime product behavior (`Sub` docs’ websocket story). |
| `Html msg` view as framework output | Renderer | Direction 01: host owns rendering; root yields typed result. |
| Ports / flags / JS interop | Deployment boundary | Elm-in-browser embedding. |
| `Cmd.map` / `Sub.map` for nesting | API spelling for single-msg apps | Local inject functions remove much of this need. |

### 3.3 Ordering claim that old notes over-hardened

Elm documents concurrent command *results* as unordered. It does **not**
publish a detailed multi-phase “tick law” comparable to Bonsai’s
flush/result/lifecycle or the provisional Eta Crux tick note’s
stabilize → lifecycle → observe fragments → spawn commands sequence. Any such
sequence in Eta Crux must be justified from Bonsai-like driver needs and Eta
runtime facts, not from Elm.

---

## 4. Rust Crux — core/shell and testing semantics

Primary evidence: `crux_core/src/lib.rs` (`App` trait),
`crux_core/src/core/{request,effect,resolve}.rs`,
`crux_core/src/bridge/mod.rs`, `crux_core/src/testing.rs`,
`docs/src/{overview,motivation}.md`,
`docs/src/guide/{elm_architecture,effects,message_interface,testing}.md`.

### 4.1 Semantic contracts worth keeping (narrow)

1. **Core is side-effect free; shell executes effects.**
   Overview and effects guide: managed effects; core describes intent; shell
   performs work and returns outcomes as events.

2. **Update is a pure-ish transition producing effect intent.**
   `App::update` mutates model and returns `Command<Effect, Event>`
   (`lib.rs`). Testing can call `update` and inspect effects without a real
   shell (`testing.rs`, testing guide).

3. **View model is a projection, not the domain model.**
   `App::view(model) -> ViewModel`. Shell renders; render is itself an effect
   request in common examples.

4. **Request/resolve pairing for multi-shot and one-shot effects.**
   `RequestHandle::{Never, Once, Many}` (`resolve.rs`); shell resolves with
   operation output.
   *Keep the semantic idea* “async work needs a correlation path back into
   update.”
   *Do not keep* the FFI-shaped handle registry as public OCaml API when Eta
   fibers already provide completion-to-action.

5. **Testability by inspecting staged effects / resolving requests.**
   First-class in Crux docs and `AppTester` / Command APIs.

### 4.2 Crux pieces that exist for multi-language shells — not Eta Crux core

| Item | Classification | Reason |
|---|---|---|
| Core/Shell process split as *architecture identity* | Deployment boundary | Crux’s product goal is shared Rust core across iOS/Android/Web (`lib.rs`, motivation). Eta Crux is in-process OCaml with host adapters. |
| `EffectFFI`, bincode `process_event` / `handle_response` / `view` | Serialization / FFI | `bridge/mod.rs`, message_interface.md: events and effect outputs serialized across FFI. Direction 01 + old boundary note already allow in-process typed values. |
| Typegen / UniFFI / shared_types crates | Language ownership workaround + tooling | Multi-language shells. |
| Capability crates (`crux_http`, `crux_kv`, `crux_time`) as framework surface | Product packaging | Optional host capabilities, not computation-layer laws. |
| `Render` effect as mandatory update output | Renderer convention | Shell-owned UI update; Eta Crux can expose a typed result without a Render effect enum. |
| Migrating dual API (`Capabilities` + `Command`) | Historical API | Docs mark Capabilities deprecated mid-migration. |

### 4.3 What Crux does *not* provide (so old notes should not claim it from Crux)

- No incremental graph, no keyed `assoc`, no per-cell local models.
- No Bonsai-like dynamic structure disposal model.
- Composition is manual child apps + event/effect mapping, not graph-native
  cells.

Borrowing Crux’s shell vocabulary wholesale while also promising Bonsai-like
composition is how the provisional bundle became a hybrid without a single
reference owner.

---

## 5. Smallest coherent semantic subset for the agreed direction

Direction 01 (locked): Bonsai-like layer over private `eta_signal`; Eta effects;
deterministic advancement; typed output; host-owned rendering.

### 5.1 Keep (semantic core)

| # | Law | Primary home |
|---|---|---|
| S1 | Application is a **root computation** that can allocate local state, injectors, lifecycle, and child computations. | Bonsai |
| S2 | **Local state machines** with framework-owned model storage; app sees read-only model values + typed inject. | Bonsai |
| S3 | **Inject enqueues / stages**; transition is synchronous; effects do not run inside the pure transition body. | Bonsai + Elm + Crux (shared law, different spelling) |
| S4 | Transitions get a **restricted context** (stage effects, inject later actions, maybe time). | Bonsai (closest), mapped onto Eta effects |
| S5 | **Dynamic branching** activates one structure and disposes another. | Bonsai + Incremental bind scopes |
| S6 | **Keyed composition (`assoc`)** keeps per-key state while the key lives; key enter/leave create/dispose scopes. | Bonsai + Incremental/Incr_map motivation |
| S7 | **Lifecycle**: deactivate disposed scopes before activate new ones; lifecycle work is staged effects, not free I/O. | Bonsai (order), without DOM frame names |
| S8 | **One deterministic advancement primitive** (hosted or test-driven) that processes pending actions, stabilizes, runs lifecycle, publishes output, then starts staged effects. | Bonsai driver loop + Incremental stabilize; Eta-specific effect start |
| S9 | **Canonical output is one typed root result**; hosts may observe more granularly later, but public contract is not fragments/paths/raw signals. | Direction 01; Bonsai generic result; *rejects* old fragment-tree requirement as public law |
| S10 | **Host adapter owns rendering and host I/O**; Eta Crux ends at computation + typed output (+ staged Eta effects). | Direction 01; Bonsai core vs bonsai_web; Crux core/shell *idea* without FFI |
| S11 | Private engine laws: stabilize, necessity, cutoffs, scopes; keyed map support required for S6. | Incremental + eta_signal contract |

### 5.2 Optional later (not V1 semantic identity)

- Crux-style capability message enum for *truly external* shell work that cannot
  be an in-process Eta effect.
- Elm-style declarative subscription set reconciliation as a *library pattern*
  over Eta streams (only if a ticket proves cells + lifecycle are insufficient).
- Bonsai `wrap`, model resetters, actors, polling helpers as library API.

### 5.3 Explicitly out of the semantic core

- Public `Cmd` / `Sub` dual API as framework vocabulary.
- Fragment address trees, type witnesses, `Obj`, raw `eta_signal` in public API.
- FFI serialization, request-id bridges, typegen.
- DOM/`before_display` frame model.
- Single global model as the only composition story.
- Shell-owned execution of *ordinary* application effects (those are Eta
  effects in-process).

---

## 6. Claims in the old `docs/requirements/eta-crux/` bundle without enough justification

The provisional notes mix three reference systems. Below are claims that do not
follow from primary sources under the agreed direction, or that copy a
host/language boundary into the core.

### 6.1 Over-copied from Rust Crux / multi-shell deployment

| Claim locus | Claim | Problem |
|---|---|---|
| `shell-capabilities.md`, `boundary-contract.md`, `concepts.md` | First-class **capability messages** and shell-owned work as core architecture | Justified for Crux FFI shells; not justified as Eta Crux default when Eta effects already run in-process. Sliml host work is adapter/rendering, not Crux capabilities. |
| `boundary-contract.md` | Boundary payload triple: actions + fragments + capability messages | Over-specifies Crux-like ports; direction 01 only requires typed result + host-owned rendering. |
| `commands-and-effects.md` `cmd-7h2q` | “Shall not serialize or forward that effect across an adapter boundary” | Correct *if* effects stay in-process; the requirement is reacting to a Crux problem Eta Crux should not reintroduce. |
| `testing.md` pending-command handles mirroring Crux resolve | Opaque pending-command resolve API as required harness shape | Crux needs resolve because shell executes effects; Eta tests can run or intercept Eta effects directly. Shape is undecided, not required by reference law. |

### 6.2 Over-copied from Elm as public framework surface

| Claim locus | Claim | Problem |
|---|---|---|
| `subscriptions.md` entire note | Framework-level **Sub** reconciliation by spec equality, batch/none combinators | Elm runtime feature. Eta has streams and lifecycle; no primary source forces a second subscription algebra in the computation core. |
| `commands-and-effects.md` | Commands as first-class dual of transitions returning command lists | Compatible spelling, but presented as law while Bonsai uses context-scheduled effects. Direction 01 already chose restricted context. |
| `concepts.md` / README | “Eta streams for subscriptions” as architectural pillar equal to cells | Unjustified symmetry with Elm `Sub`; may become a library later. |

### 6.3 Over-copied from Bonsai/web or over-specified tick machinery

| Claim locus | Claim | Problem |
|---|---|---|
| `fragments.md`, `adapter.md`, `tick.md`, `testing.md` | **Output fragments** with address trees, scalar/collection fragments, fragment observation phase | Bonsai exposes a typed result (and web VDOM). Path-addressed fragment trees are an invented public contract. Direction 01 forbids fragments/paths as public types; granular delivery is a prototype experiment only. |
| `tick.md` | Detailed phase order including fragment observation before command spawn, batch limits, timer eligibility | Some phases are real (actions → stabilize → lifecycle → effects). Fragment phase and batch policy are not reference laws; batch limits especially lack Bonsai/Elm/Crux primary mandate. |
| `tick.md` / `lifecycle.md` | Init commands staged during activation lifecycle | Plausible Bonsai-like pattern, but not a published portable law; needs its own design ticket. |
| `dispatch.md` | Bounded cross-domain action queue with owner vs non-owner suspension rules | Eio/domain integration design, not a Bonsai/Elm/Crux semantic export. May be needed for Sliml, but it is host concurrency design, not reference semantics. |
| `engine-strategy.md` | `eta_signal_map` sibling package name and exact scope hooks | Engineering plan, not a reference-semantic claim. The *need* for keyed map support is justified; the package split is not. |

### 6.4 Hybrid inventions without a single reference owner

| Claim locus | Claim | Problem |
|---|---|---|
| `concepts.md` command **slots** that interrupt previous command | Neither Elm Cmd nor Bonsai schedule_event defines per-cell slots as core law | Product feature; needs justification or demotion. |
| `composition.md` parent passes **command constructor** to child | Crux/Elm nesting workaround + Bonsai inject mix | Bonsai uses parent-provided inject/effects; “command constructor” vocabulary is hybrid. |
| `core-loop.md` | Input status Active/Inactive on transitions | Justified from Bonsai `Computation_status`. Keep. |
| `README.md` / old wayfinder | Plain mutable state V1 with later graph backend | Contradicts resolved direction 01 (Bonsai-like over private `eta_signal` from the start). Provisional; do not treat as current direction. |

### 6.5 Claims that *are* well-justified (keep as direction, rephrase later)

- Root computation of composable state-machine cells (Bonsai).
- Framework-owned model storage; inject API (Bonsai).
- Transition does not run effects inline; commit then run (Bonsai/Elm/Crux).
- Keyed dynamic collections with stable per-key state (Bonsai + Incremental map
  docs).
- Dynamic branch dispose/activate (Bonsai + Incremental scopes).
- Explicit driver advancement / stabilize (Bonsai driver + Incremental).
- Headless computation without a UI adapter (Bonsai core vs bonsai_web; Crux
  testability idea).
- Host-owned rendering (direction 01; all three references separate view/render
  from pure update, with different boundaries).

---

## 7. Mapping matrix (quick reference)

| Concern | Bonsai | Incremental | Elm | Rust Crux | Eta Crux (direction 01) |
|---|---|---|---|---|---|
| Local composable state | Yes | N/A (engine) | No (global model) | No (global model) | Yes |
| Keyed per-item state | `assoc` | Needs Incr_map | Manual | Manual | Yes (needs engine) |
| Effect execution | UI effect runtime | N/A | Elm runtime | Shell | Eta effects in-process |
| Output | Typed result / VDOM host | Observer values | `Html` | `ViewModel` + Render effect | Typed root result; host renders |
| Dynamic structure | First-class | bind scopes | Manual | Manual | First-class |
| FFI/serialize | No | No | Ports optional | Central | Not core |
| Test seam | Driver + expect tests | stabilize | pure update | update + resolve | Shared advancement primitive |

---

## 8. Conclusions

1. **The semantic spine is Bonsai’s computation layer + Incremental’s engine
   laws**, executed with **Eta effects** and a **host-owned render boundary**.
2. **Elm contributes the unidirectional managed-effect idea**, not `Cmd`/`Sub`
   as public types and not a single global model.
3. **Rust Crux contributes testable pure update + shell execution of *foreign*
   effects**, not FFI bridges, typegen, capability enums, or core/shell process
   identity for an in-process OCaml library.
4. The provisional `docs/requirements/eta-crux/` bundle over-copied Crux shell
   ports, Elm subscriptions, and an invented fragment-address output system, and
   over-specified tick/dispatch/engine packaging. Those must not be treated as
   settled semantics for the first-principles map.
5. Implementation should wait for later tickets (public API, keyed assoc,
   advancement transaction). This report only freezes *which reference laws
   matter*.

## Source checklist (validation)

- [x] Bonsai `cont.mli` state_machine, assoc, Edge.lifecycle, Apply_action_context
- [x] Bonsai `bonsai_driver.mli` flush/result/lifecycles
- [x] Bonsai `computation.ml` Leaf/Assoc/Switch/Lifecycle
- [x] Incremental `incremental_intf.ml` stabilize/necessity/cutoff/scope
- [x] Incremental docs part2 bind, part3 Incr_map
- [x] Elm guide architecture + effects HTML
- [x] Elm `Platform.Cmd` / `Platform.Sub` / `Browser.elm` source
- [x] Crux `App` trait, Request/Resolve, Bridge, effects + message_interface docs
- [x] Direction ticket 01 not reopened
- [x] Old requirements audited for unjustified copies
- [x] No edits to `docs/wayfinder/eta-crux/` or requirements rewrite
- [x] No Eta Crux implementation

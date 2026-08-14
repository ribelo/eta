# Eta substrate and the no-`R` boundary

## Decision

Keep the shipped effect type:

```ocaml
type ('a, +'err) Effect.t
```

Do not add a requirement parameter, `Layer`, `Tag`, an effect-environment
`Context`, or `Effect.provide` to it. The public `Effect` interface says that
dependencies are ordinary OCaml values and that Eta does not own a ZIO-style
environment or layer graph (`lib/eta/effect.mli:1-23`). The project service rule
says the same: applications pass records, modules, closures, and handles;
runtime services are interpreter configuration (`docs/services.md:1-17`).

The component runtime must be a separate seam. It may define typed component
requirements and provisions, dynamic provider availability, component
instances, long-lived component contexts, reconciliation, replacement, and
recovery. A resolved component can then construct ordinary
`('a, 'err) Effect.t` values by passing the handles it needs. Requirements and
provisions must not become a hidden row on every Eta effect.

This matches the component-runtime map: `Effect.t` stays
`('a, 'err) Effect.t`, requirements and provisions stay at the
component-runtime seam, provider availability is dynamic, and the core is
planned as an optional component package (`docs/wayfinder/eta-component-runtime/map.md:12-29`).

### Two meanings of “context”

This report uses **effect-environment context** for the rejected ZIO-style
ambient `Context`/`Tag` mechanism: a requirement container read by effects or
installed with `provide`, and therefore attached to the `Effect.t` contract.
The no-`R` verdict rejects that mechanism only.

It does **not** reject a **component context**. A component context is an
approved, separate component-runtime object or module that owns provider
availability, acquired handles, registrations, child instances, and lifecycle
state across reconciliations. It must stay outside the type of `Effect.t`;
component code can resolve a handle from that context and pass the handle into
an ordinary effect. The existing Eta runtime context and runtime locals are a
third, interpreter-owned mechanism, not either application environment
context or component context.

## Boundary model

| Owner | Owns | Does not own |
| --- | --- | --- |
| Eta `Effect` and `Runtime` | Effect blueprints, typed failures, runtime interpretation, scopes, cancellation, resources, structured concurrency, and runtime observability | Application service graphs, component declarations, provider lookup, or component reconciliation |
| Component runtime | Typed requirement/provision declarations, provider availability, component identity, component context, reconciliation, replacement, and component recovery policy | A second effect algebra or a replacement for Eta resource and concurrency semantics |
| Application | Ordinary service values, factories, records, modules, and explicit handles | Eta's internal runtime tokens and component-owned lifecycle bookkeeping |

The current boundary document explicitly rejects an environment parameter,
`Layer`, service `Tag`, an effect-environment `Context`, and dynamic `provide`; it also says that
runtime clock, tracing, logging, metrics, and random are interpreter
configuration (`docs/zio-boundaries.md:8-24`). This is not merely an absent API.
`Capabilities` makes the same split in its type-level documentation: runtime
traits are small interpreter-owned capabilities, application dependencies stay
ordinary records and values, and random is a portable token rather than an
object capability (`lib/eta/capabilities.mli:1-21`).
The envless verdict records the later OxCaml portability decision, the survival
tests for `provide` and `Layer`, value-restriction costs, and cross-library key
hazards (`.scratch/research/envless-verdict-2026-07-26.md:17-64`,
`:148-183`). DX-E16 independently kept ordinary value passing, while recording
that deeper graphs remain the main uncertainty
(`.scratch/research/dx/e16/report.md:5-16`, `:188-254`).

## Reusable Eta substrate

The following mechanisms are reusable. They provide an execution substrate, not
a component model.

### 1. Lexical ownership and finalization

`Effect.with_resource` is the preferred acquire/use/release bracket.
`Effect.acquire_release` registers a release with the current runtime boundary,
scope, supervisor scope, or daemon body. `Effect.with_scope` creates a nested
scope and releases registered resources in reverse acquisition order
(`lib/eta/effect.mli:606-680`). `finally` and `on_exit` preserve the primary
exit while representing cleanup failures as `Cause.Finalizer` or suppressed
finalizer diagnostics (`lib/eta/effect.mli:558-604`).

The implementation confirms that cleanup runs under cancellation protection,
that successful cleanup preserves the original exit, and that a failed cleanup
is attached to the primary cause (`lib/eta/effect_resource.ml:6-43`). The scope
implementation registers releases in a frame and runs them at scope exit
(`lib/eta/effect_resource.ml:70-106`).

**Component use.** A component context can own acquired providers,
registrations, subscriptions, and child component scopes by placing them under
an Eta scope. A component implementation should use `with_resource` for a
body-bounded handle and `with_scope` plus `acquire_release` for a context-owned
handle. It must not invent a second finalizer stack.

**Limit.** A lexical Eta scope is not yet a long-lived component context. The
component seam must decide how a context survives several resolutions,
activations, and replacements while retaining one explicit owner.

### 2. Structured child work and cancellation

`Supervisor.scoped` is a lexical nursery. Its rank-2 body keeps child handles
inside their owning supervisor scope
(`lib/eta/supervisor.mli:1-12`, `:87-92`). `start` records child work,
`await` observes its result, and `cancel` requests cancellation and waits for
settlement; a pure interruption is normal cancellation, while child and
finalizer failures remain visible (`lib/eta/supervisor.mli:35-50`).

`Supervisor.Scope.request_cancel` is the useful post-commit primitive. It latches
a request and returns before child settlement; repeated requests are idempotent.
`cancel` remains the settlement fence, and `await` observes the child's ordinary
outcome (`lib/eta/supervisor.mli:52-65`). The private scope AST and interpreter
preserve the rank-2 boundary, register the child before its body runs, and
separate request from settlement (`lib/eta/effect_supervisor_scope.ml:4-9`,
`:91-191`).

This contract has direct executable evidence:

- `test_supervisor_request_cancel_returns_before_settlement`;
- `test_supervisor_request_cancel_latches_before_child_start`;
- `test_supervisor_request_cancel_preserves_terminal_winners`;
- `test_supervisor_cancel_after_request_preserves_settlement_diagnostics`;
- `test_supervisor_await_after_request_reports_interruption`; and
- `test_supervisor_request_cancel_calls_follow_scope_program_order`.

They are registered in
`test/core_common/supervisor_common_suites.ml:721-1238`. The generated law
`Supervisor request_cancel repeated requests equal one request across generated
counts and terminal outcomes` covers idempotence and all four terminal classes
(`test/laws/law_properties.ml:3221-3402`; registry row M128 at
`.scratch/research/dx/e22/review/LAWS.md:59-60`).

**Component use.** Replacement or withdrawal can request cancellation of the
old component scope, then start new work after the documented request point.
The component runtime must choose where to await settlement. It must not
pretend that `request_cancel` is a completion fence.

**Limit.** Existing child handles are intentionally lexical. The component
runtime needs a private, durable instance/context owner that can use this
protocol without exposing escaping supervisor handles or an unscoped detach
operation.

### 3. Concurrent composition and coordination

`Effect.par`, `race`, `all`, `all_bounded`, `all_settled`, and `map_par` provide
structured concurrent work with input-order result collection, fail-fast
cancellation where specified, and loser cleanup
(`lib/eta/effect.mli:161-252`). The implementation registers all `all` children
before releasing them, aggregates causes, and waits for cancellation cleanup
(`lib/eta/effect_concurrent.ml:53-107`, `:108-227`, `:317-387`).
Parallel resource acquisition transfers finalizers only after a complete
admission batch (`lib/eta/effect_concurrent.ml:389-422`).

These claims have named generated laws, including:

- `par preserves pair input order across both observable completion directions`;
- `par first observed failure cancels sibling tree and awaits cleanup`;
- `all registers one fiber per generated child before synchronous first failure`;
- `all first observed failure cancels siblings and awaits their finalizers`;
- `race loser cancellation releases an actually held scoped resource`; and
- `map_par never exceeds max_concurrent and reaches the bound when inputs suffice`.

The registry records the corresponding spans and properties
(`.scratch/research/dx/e22/review/LAWS.md:37-58`, `:60-70`).

`Runtime_contract` also exposes typed one-shot promises and bounded streams.
Promises are the runtime commit and wakeup mechanism; streams provide internal
result handoff (`lib/eta/runtime_contract.mli:7-20`, `:61-68`, `:128-137`).
The runtime-common suite checks live waiter wakeup, resolution after waiter
cancellation, and that a cancelled waiter does not strand a live waiter
(`test/runtime_common/runtime_common_suites.ml:978-1065`).

**Component use.** These primitives can drive provider readiness, lifecycle
workers, and internal event handoff after the component runtime owns the
coordination. They do not provide the component dependency graph, stable
component identity, or a reactive withdrawal protocol.

### 4. Backend-neutral runtime contract

`Runtime_contract.t` is a backend-neutral contract for scopes, cancellation,
promises, streams, worker context, locals, and typed runtime service keys
(`lib/eta/runtime_contract.mli:1-45`). It requires owner-domain use for ordinary
operations and callbacks. Promise resolution is the explicit cross-domain
wakeup operation; resumed Eta work returns to its owning domain
(`lib/eta/runtime_contract.mli:96-110`).

The module-shaped `RUNTIME` interface is the typed authoring surface for
backends, while `of_runtime` is the single erased adapter
(`lib/eta/runtime_contract.mli:143-250`, `:268-286`). The current runtime keeps
this backend-neutral boundary in `Runtime.create_with_runtime`
(`lib/eta/runtime.mli:5-39`).

**Component use.** A component runtime can be implemented over this contract
and tested against more than one backend. Its context coordinator can use
promises and streams for readiness and withdrawal, and can use owner-domain
rules to keep component graph mutation on one coordinator domain.

**Limit.** `Runtime_contract.service_key` is a typed key for optional
runtime-package services attached at interpreter construction. It is not an
application provider registry, requirement row, or dynamic component
availability graph. The runtime documentation says that packages own these
keys and retrieve them through `Spi.Expert`
(`lib/eta/runtime.mli:32-34`; `lib/eta/spi.mli:147-169`).

### 5. Runtime locals and dynamic scope

Runtime locals support `Inherit` and `Fiber_local` fork policies. A binding is
restored exactly after its callback, nested bindings restore in LIFO order, and
child changes do not merge at join
(`lib/eta/runtime_contract.mli:22-37`, `:74-84`). The public effect surface
uses this machinery for runtime-owned clock and random overrides. Children
inherit at fork, parallel siblings are isolated, and the outer binding is
restored on every exit (`lib/eta/effect.mli:707-727`).

The optional observability surface uses the same boundary for logger and tracer
overrides. It documents restoration, fork inheritance, sibling isolation, and
captured operation context (`lib/observability/eta_observability.mli:33-49`).
Its log and metric interceptors are scoped, ordered, and fiber-local
(`lib/observability/eta_observability.mli:153-191`, `:241-250`).
The generated properties `dynamic override restoration across each exit kind`,
`override sibling isolation under par`, and
`nested random logger and tracer overrides use innermost bindings and restore
exact outer observations` cover this behavior
(`.scratch/research/dx/e22/review/LAWS.md:72-90`;
`test/laws/law_properties.ml:2894-3042`).

**Component use.** A component runtime may use private locals for an
Eta-owned invariant, such as an internal coordinator marker or instrumentation
context. It must not use a local as a stealth application environment. Provider
requirements must remain explicit in the component API, and component context
restoration must not silently change the documented runtime-local semantics.

### 6. Runtime-owned work beyond a caller scope

`Spi.daemon` starts finite runtime-owned work on the outer switch. Its failures
bypass the typed result and become runtime daemon diagnostics; `Runtime.drain`
waits for currently running finite daemon work
(`lib/eta/spi.mli:1-31`; `lib/eta/runtime.mli:69-84`). The SPI is explicitly
unstable, implementation-facing, and not application dependency injection
(`lib/eta/spi.mli:7-19`).

`with_background` and `with_supervised_background` are the bounded alternatives:
they cancel and await their child when the body exits, with different failure
propagation rules (`lib/eta/effect.mli:682-695`). Common runtime tests cover
body failure, cleanup, daemon drain, and the fact that a daemon child does not
join its local `run_scope`
(`test/runtime_common/runtime_common_suites.ml:434-452`,
`:1121-1152`; `test/core_common/supervisor_common_suites.ml:183-250`).

**Component use.** A component context may need one long-lived coordinator.
That work must be owned by the component runtime and shut down through an
explicit context/root fence. It must not expose `Spi.daemon` as a public
component escape hatch, and it must not turn daemon diagnostics into silently
discarded typed failures.

### 7. Typed outcomes and diagnostics

`Cause` distinguishes typed failures, defects, interruption, sequential and
concurrent causes, finalizer diagnostics, and suppressed finalizer failures
(`lib/eta/cause.mli:1-17`, `:65-73`). `Exit.t` is the complete
success-or-cause boundary (`lib/eta/exit.mli:1-18`). This gives a component
runtime a stable way to preserve primary failure, interruption, cleanup
diagnostics, and concurrent structure.

The boundary is deliberately narrow: `bind_error` handles only catchable typed
failures and does not handle defects, interruption, or finalizer diagnostics
(`lib/eta/effect.mli:285-311`; `docs/zio-boundaries.md:63-76`). Component
recovery must therefore state whether it recovers typed provider failure,
restarts an instance, or reports an uncatchable cause. It must not flatten all
failures into an OCaml `result`.

### 8. Refreshable values

`Eta_cache.Refreshable` preserves the last successful value while a load or
refresh fails. `with_auto` owns its refresh loop lexically, cancels and awaits
that loop on every body exit, and records refresh failures
(`lib/cache/refreshable.mli:1-40`). The implementation uses a versioned
publication rule and `with_supervised_background`
(`lib/cache/refreshable.ml:3-10`, `:25-43`, `:64-118`).

This is useful prior art for provider readiness and last-good-value semantics.
It is not a component context: it has no typed requirement graph, provider
withdrawal, component identity, or generation-owned resource scope. The
boundary documentation also records an open issue: replacing a value does not
close resources held by the old generation
(`docs/zio-boundaries.md:229-242`). A component design must not claim that
`Refreshable` already solves replacement cleanup.

## Contracts that a component seam must preserve

1. **No global environment channel.** Keep `('a, 'err) Effect.t`; use ordinary
   values and local composite records when a subsystem has a deep, volatile
   dependency set (`docs/services.md:173-205`).
2. **No compatibility surface for rejected designs.** Do not add a second
   `Reader` effect, a `Layer` algebra, `Tag`/effect-environment `Context`, or a
   hidden `provide` operation. The envless decision lists these as rejected
   alternatives and gives measurable reopen conditions
   (`.scratch/research/envless-verdict-2026-07-26.md:383-449`). A component
   context remains allowed because it belongs to the separate component-runtime
   seam described above.
3. **Explicit ownership.** Every provider handle, subscription, child
   component, timer, and lifecycle worker must have an owner and an explicit
   settlement fence. Reuse Eta scope finalizers and supervisor cancellation;
   do not add a component-private detach or promotion operation.
4. **Request and settlement remain different.** A component replacement may use
   `request_cancel` as an ordered request point, but it must use `cancel`,
   `await`, supervisor exit, or context shutdown when it needs settlement.
5. **Cause fidelity remains visible.** Preserve `Cause` structure, primary
   failures, interruption, finalizer failures, and concurrent sibling
   diagnostics. Recovery must not convert cleanup failure into a log-only event.
6. **Backend neutrality and portability remain real.** Component graph mutation
   must obey the runtime contract's domain rules. Cross-domain handoff must use
   the contract's explicit resolver path, not arbitrary runtime tokens.
7. **Runtime locals remain runtime-owned.** A component context can use private
   locals only for a component-runtime invariant that cannot be expressed by
   ordinary values. It must not make provider availability ambient to every
   effect.
8. **Observability remains non-interfering.** Component lifecycle and provider
   transitions should use named spans, events, logs, and metrics, while
   preserving the existing scoped ordering and defect behavior.

## Exact component-runtime gaps

The current repository supplies the execution substrate above but does not yet
ship the following component semantics:

| Required capability | Current state | Gap |
| --- | --- | --- |
| Reusable component declaration | No component declaration/instance API in `lib/eta/` | Define the declaration boundary, static requirement/provision types, and one live instance identity |
| Provider availability | Runtime service keys exist only for services supplied at runtime construction | Define dynamic availability, absence, replacement, and typed key/value ownership in the component runtime |
| Long-lived component context | Eta scopes own lexical resources; no context spans multiple activations and reconciliations | Define context ownership, context shutdown, child-instance ownership, and handle validity |
| Reactive resolution | Promises, streams, queues, and pubsub provide coordination only | Define the dependency graph, readiness notifications, withdrawal, backoff, and wakeup rules |
| Reconciliation and replacement | `Effect` has no graph transaction or component replacement protocol | Define provisional work, commit, rollback, old-instance invalidation, and the request/settlement fences |
| State and identity | Eta does not define component incarnation or stale handle semantics | Define whether state is context-owned, instance-owned, or discarded and how old handles fail |
| Component recovery | `Cause` and `Exit` preserve failure data but do not define provider retry or coherence | Define recovery policy, observational equivalence, failure publication, and last-good-value rules |
| Module loading/HMR | Not part of the current Eta core or the component-runtime map's implementation scope | Keep loading and HMR in a separate optional seam |
| Component laws | E22 covers `effect.mli`, `schedule.mli`, `channel.mli`, `queue.mli`, and `semaphore.mli`; it does not claim retrospective coverage for a component API (`.scratch/research/dx/e22/review/LAWS.md:8-21`) | Add named executable laws and a model for every new normative component contract |

The absence is important. It means that Eta can host a component runtime, but
the current interfaces do not already answer provider withdrawal, stale
incarnation, reactive graph commit, component-context shutdown, or replacement
rollback. Those answers belong to the separate seam rather than to `Effect`.

## Verification plan for the new seam

The existing law registry is the source of truth for law-bearing interface
claims. It records one row per claim with an exact source span and a named
property or registered executable suite (`.scratch/research/dx/e22/review/LAWS.md:1-21`).
The current Eta laws already cover the substrate needed by a component runtime:
resource exit classes and ordering, concurrent cancellation, dynamic-scope
restoration and sibling isolation, and supervisor request cancellation
(`.scratch/research/dx/e22/review/LAWS.md:27-90`).

The component seam should add tests before implementation. At minimum, a
deterministic model and generated tests must cover:

- provider add, remove, replacement, and re-entry with distinct instance
  identity;
- a requirement that is unavailable, becomes available, and withdraws while a
  consumer is running;
- provisional resolution failure and rollback without changing the committed
  context;
- the exact order of cancellation requests, new-work admission, finalizers,
  and publication;
- every component and provider exit class: success, typed failure, defect,
  interruption, and cleanup failure;
- stale handles and queued work after component removal;
- recovery that preserves the last coherent committed observation; and
- an available empty fiber census after each finite generated scenario.

Use the existing `Eta_test` clock and runtime-common backend helpers for
determinism. Test backend-neutral behavior through `Runtime_contract`, then
run the Eio adapter. Do not use a fixed example or a self-comparison as a
substitute for a generated out-of-order lifecycle case.

## Rejected substrate changes

- **Restore `R` on `Effect.t`.** This violates the shipped API and the OxCaml
  portability decision. Ordinary values, composite records, and the separate
  component seam cover the remaining use cases.
- **Make component requirements runtime services.** `Runtime_contract.service_key`
  and `Spi.Expert.runtime_service` are package/backend hooks, not application
  provider graphs. Using them for components would make availability an
  interpreter-global concern and would weaken package boundaries.
- **Use runtime locals as an implicit component context.** Locals have precise
  fork and restoration semantics, but they are not a durable provider graph and
  have no component identity or withdrawal protocol.
- **Expose daemon or supervisor handles publicly.** This would weaken structured
  ownership. Keep component-owned long-lived work behind the component context
  and use a context shutdown fence.
- **Add a second resource descriptor language.** Eta already has the
  `Effect.acquire_release`/`with_resource`/`with_scope` architecture; a second
  `Resource.t` would duplicate ownership semantics
  (`docs/zio-boundaries.md:155-220`).

## Evidence gaps

1. The envless verdict records the OxCaml recovery fixtures and compiler
   diagnostics, but says that the recovery fixture directory is no longer in
   the repository (`.scratch/research/envless-verdict-2026-07-26.md:150-170`).
   The shipped capability and island interfaces corroborate the boundary, but
   the original fixture cannot be rerun from this checkout.
2. DX-E16 used a real but shallow service graph. Its report calls confidence
   medium and identifies deeper graph evolution as the remaining uncertainty
   (`.scratch/research/dx/e16/report.md:13-16`, `:188-214`).
3. No current component declaration, provider graph, context, replacement
   implementation, or component-specific executable law exists. The lifecycle,
   recovery, coherence, stale-handle, and reactive-withdrawal rows above are
   therefore design gates, not claims that current Eta already satisfies them.
4. `Eta_cache.Refreshable` has no generation-owned close-on-replace behavior.
   This matters only if a component provider uses resource-owning refresh
   generations; no such current component use case is in the repository
   (`docs/zio-boundaries.md:229-242`).
5. The final component package split and module-loading/HMR boundary remain
   open in the map (`docs/wayfinder/eta-component-runtime/map.md:19-22`,
   `:62-69`). This report does not resolve those later tickets.

## Sources

- `lib/eta/effect.mli`, `lib/eta/runtime.mli`,
  `lib/eta/runtime_contract.mli`, `lib/eta/capabilities.mli`,
  `lib/eta/supervisor.mli`, `lib/eta/spi.mli`,
  `lib/eta/cause.mli`, and `lib/eta/exit.mli`.
- `lib/eta/effect_resource.ml`, `lib/eta/effect_supervisor_scope.ml`,
  `lib/eta/effect_concurrent.ml`, `lib/eta/runtime_core.ml`,
  `lib/eta/runtime_contract.ml`, and `lib/eta/runtime_supervisor.ml`.
- `lib/observability/eta_observability.mli`,
  `test/runtime_common/runtime_common_suites.ml`,
  `test/core_common/runtime_contract_common_suites.ml`,
  `test/core_common/supervisor_common_suites.ml`,
  `test/core_common/observability_common_suites.ml`, and
  `test/laws/law_properties.ml`.
- `docs/services.md`, `docs/zio-boundaries.md`,
  `.scratch/research/envless-verdict-2026-07-26.md`,
  `.scratch/research/dx/e16/report.md`, and
  `.scratch/research/dx/e22/review/LAWS.md`.

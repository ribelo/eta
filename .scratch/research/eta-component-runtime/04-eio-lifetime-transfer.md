# Eio lifetime transfer

## Decision

Eio proves the lexical lifetime of one activation. It does not prove the
temporal lifetime of a component instance.

The reference adapter must give each activation a fresh Eio switch through
the existing Eta lexical scope. The switch stays open until deactivation reaches
its teardown boundary. Reactivation must use a new switch.

The component context needs one small, backend-neutral protocol:

1. Serialize lifecycle transitions for each component instance.
2. Give each activation a fresh generation identity.
3. Stage registrations until activation commits.
4. Fence new use before withdrawal.
5. Withdraw dependents before their providers.
6. Wait for owned children and teardown before the instance becomes inactive.
7. Reject work and cleanup from an old generation.

This protocol owns component instances and long-lived registrations. Eta scopes
continue to own lexical resources. No new Eio resource wrapper is necessary.

## Version and evidence method

Eta declares `eio >= 1.0` in
[`dune-project`](../../../dune-project#L168-L176) and
[`eta_eio.opam`](../../../eta_eio.opam#L14-L17). The active OxCaml switch
contains `eio.1.3+ox`. Its source is the official `oxcaml/eio` repository at
commit
[`7de26f5`](https://github.com/oxcaml/eio/tree/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e).

The report uses the interface as the API contract. It uses the implementation
and first-party tests to explain and test that contract. All Eio links below
refer to that exact commit.

## What Eio proves

### Lexical switch lifetime

`Switch.run` waits for its attached fibers. It then releases attached resources
before it returns. A resource cannot outlive its switch
([interface, lines 5-18 and 37-45][eio-interface-switch]).

The official guide gives the same boundary. A function without a switch cannot
return an attached fiber or open file
([guide, lines 299-353][eio-guide-switches]). A finished switch rejects later
use ([test, lines 120-139][eio-test-finished]).

This boundary matches one activation only if the activation keeps
`Switch.run` open. A component cannot save a finished switch for reactivation.
The adapter must create a new switch for each activation.

### Asynchronous teardown and child ownership

`Fiber.fork ~sw` attaches a child to the switch. The switch cannot finish until
that child finishes ([interface, lines 258-268][eio-interface-fork]).
`Fiber.fork_daemon` cancels a daemon after all non-daemon fibers finish. The
switch still waits for daemon cancellation
([interface, lines 306-313][eio-interface-daemon]).

The implementation waits until its fiber count is zero. It then collects and
runs release hooks ([source, lines 95-115][eio-source-await-idle]).
Therefore, completion of `Switch.run` is the teardown join point.
`Switch.fail` is not that join point. It requests cancellation and returns
immediately ([interface, lines 61-69][eio-interface-fail]).

Eio owns only children attached to the selected switch. A fiber can use an
external switch and outlive the lexical callback that created it. Eio documents
this behavior for fiber-local bindings
([interface, lines 387-394][eio-interface-binding]).
The component protocol must forbid untracked child ownership.

### Finalizer order and at-most-once cleanup

Eio release handlers run serially in LIFO order under `Cancel.protect`
([interface, lines 81-95][eio-interface-release]). Its tests cover LIFO order
on success and failure. They also cover continued cleanup after release errors
([test, lines 295-340][eio-test-release]).

The implementation closes the release queue before it runs the collected
handlers ([source, lines 101-113][eio-source-await-idle]). A cancellable hook
uses one list node. Removal replaces its function with a sentinel
([source, lines 19-29][eio-source-remove-hook]). Thus, switch release and
successful hook removal cannot both run the same hook.

This guarantee is local to one registered hook. Eio does not make an arbitrary
external cleanup action idempotent. A component registration needs its own
generation fence if stale callbacks can reach it.

### Cancellation and races

Cancellation contexts form a tree. Cancellation recursively marks unprotected
children and calls the cancellation function of each suspended fiber
([interface, lines 519-550][eio-interface-cancel]).
Repeated cancellation does nothing
([interface, lines 588-597][eio-interface-cancel-operation]).

Cancellation is cooperative. An operation can commit before cancellation and
still return its result. A later interruptible operation then observes
cancellation ([interface, lines 529-535][eio-interface-cancel]).
The promise implementation uses atomic state and waiter cancellation to select
one result for an await operation
([source, lines 37-66 and 73-91][eio-source-promise]).

Eio does not promise that only one raced side effect occurs. The official guide
states that both actions in `Fiber.first` can succeed
([guide, lines 272-297][eio-guide-racing]). The switch tests also cover both
orders between promise resolution and switch cancellation
([test, lines 141-203][eio-test-races]).

Therefore, cancellation alone cannot fence new component use. The component
context must close admission before it cancels work. It must also identify the
activation generation at each commit point.

### Partial activation failure

If the `Switch.run` body raises, Eio fails the switch. Eio then waits for
children and runs all release hooks before it raises the failure
([source, lines 132-150][eio-source-run]).
Thus, Eio cleans each successfully attached lexical resource after partial
activation.

Eio does not stage or publish a set of component registrations. It also does
not roll back external changes that have no release hook. The component
protocol must keep registrations private until activation commits. Each
external acquisition must still use the Eta lexical resource protocol.

### Dynamic scope and promises

Eio restores the previous fiber-local map after a binding callback returns or
raises ([source, lines 225-234][eio-source-vars]). A fork copies the current
fiber-local map, even when the fiber attaches to another switch
([source, lines 13-24][eio-source-fork]).
The tests cover shadowing, restoration, and fork inheritance
([test, lines 718-774][eio-test-bindings]).

Promises are thread-safe synchronization cells. The API gives them no resource
lifetime or owner ([interface, lines 132-168][eio-interface-promise]).
A promise can signal activation or deactivation. It cannot represent component
ownership, dependency order, or a generation fence.

## What Eta already adds

Eta maps its backend-neutral runtime scope directly to an Eio switch. It maps
scope creation, failure, fibers, promises, and cancellation through
`Runtime_contract`
([adapter, lines 291-328](../../../lib/eio/eta_eio.ml#L291-L328)).
The contract requires a child scope to wait for finite children and cleanup
([contract, lines 176-189](../../../lib/eta/runtime_contract.mli#L176-L189)).

`Effect.acquire_release` adds a finalizer only after acquisition succeeds.
`Effect.with_scope` creates the lexical backend scope
([resource source, lines 70-89](../../../lib/eta/effect_resource.ml#L70-L89)).
Eta clears the finalizer list before execution and runs every finalizer under
backend cancellation protection
([runtime source, lines 296-323](../../../lib/eta/runtime_core.ml#L296-L323)).

Eta also preserves typed lifecycle diagnostics. A cleanup failure becomes a
finalizer cause after success. It becomes a suppressed cause after an earlier
failure or interruption
([resource source, lines 20-43](../../../lib/eta/effect_resource.ml#L20-L43)).
Eta tests serial LIFO cleanup
([test, lines 94-116](../../../test/core_common/resource_common_suites.ml#L94-L116)).
Its generated laws cover cleanup across success, typed failure, defect, and
cancellation
([laws, lines 1216-1314](../../../test/laws/law_properties.ml#L1216-L1314)).

These Eta guarantees are stronger than raw Eio error reporting. They remain
lexical guarantees. Eta has no current component registry, component generation,
dependency withdrawal order, or deactivate-reactivate state machine.

## Scenario results

| Scenario | Eio and Eta guarantee | Missing component rule |
|---|---|---|
| Asynchronous teardown | A lexical scope waits for owned fibers and cleanup. | Deactivation must wait for that scope before it reports `inactive`. |
| Dependency-safe withdrawal | LIFO applies to hooks in one scope. | Fence use, then withdraw dependents before providers from the dependency graph. |
| Finalizer order | Eio and Eta run lexical finalizers serially in LIFO order. | Do not infer graph order from acquisition order. |
| At-most-once cleanup | One Eio hook and one Eta finalizer run at most once. | Reject stale generation actions and make registration withdrawal one-shot. |
| Partial activation failure | Attached or registered lexical resources roll back. | Do not publish staged registrations before all activation steps succeed. |
| Child ownership | A switch waits only for children attached to it. | Record each child component in the component context and forbid untracked escape. |
| Cancellation races | Eio selects one outcome per cancellable wait. Both raced effects can commit. | Close admission before cancellation and check generation at commit points. |
| Reactivation | A fresh switch gives a fresh cancellation and resource boundary. | Never reuse a finished scope. Use a new generation after teardown completes. |

## Reference-adapter shape

The Eio adapter can run each activation in a dedicated lexical scope. The
activation fiber acquires resources, signals readiness, and waits for a
deactivation signal. The body then returns normally. This return closes the
switch and runs Eta finalizers.

The context publishes staged registrations only after the readiness signal. An
acquisition failure closes the scope without publication. On deactivation, the
context first closes admission. It then withdraws dependents and signals each
activation scope in dependency-safe order. The transition finishes only after
each lexical scope returns.

`Switch.fail` remains the failure path, not the normal deactivation path. A
normal deactivation must not convert successful service lifetime into a runtime
failure.

This shape uses Eio as an adapter for an Eta-owned lifecycle invariant. It does
not wrap Eio for convenience.

## Unresolved source gaps

- Eta accepts all Eio versions from `1.0`. The repository does not lock one
  package version. This report uses the active `1.3+ox` dependency.
- Eio specifies LIFO release order, but it does not specify dependency-graph
  withdrawal order.
- Eio specifies race behavior for operations, but it does not specify component
  activation generations or stale callbacks.
- The reviewed Eio tests do not contain a deactivate-reactivate component
  scenario.
- Eta has no production component runtime. Therefore, no Eta test proves the
  missing component protocol.

[eio-interface-switch]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L5-L45
[eio-guide-switches]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/README.md#L299-L353
[eio-test-finished]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/tests/switch.md#L120-L139
[eio-interface-fork]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L258-L268
[eio-interface-daemon]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L306-L313
[eio-source-await-idle]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/switch.ml#L95-L115
[eio-interface-fail]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L61-L69
[eio-interface-binding]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L387-L394
[eio-interface-release]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L81-L95
[eio-test-release]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/tests/switch.md#L295-L340
[eio-source-remove-hook]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/switch.ml#L19-L29
[eio-interface-cancel]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L519-L550
[eio-interface-cancel-operation]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L588-L597
[eio-source-promise]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/promise.ml#L37-L91
[eio-guide-racing]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/README.md#L272-L297
[eio-test-races]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/tests/switch.md#L141-L203
[eio-source-run]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/switch.ml#L132-L150
[eio-source-vars]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/cancel.ml#L225-L234
[eio-source-fork]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/fiber.ml#L13-L24
[eio-test-bindings]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/tests/fiber.md#L718-L774
[eio-interface-promise]: https://github.com/oxcaml/eio/blob/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e/lib_eio/core/eio__core.mli#L132-L168

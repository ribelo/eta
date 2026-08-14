# Cordis TypeScript implementation census

## Scope

This census covers the Cordis checkout at commit
[`8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4`](https://github.com/cordiverse/cordis/commit/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4).
The checkout reports this commit as `HEAD`. The supplied paper is
`.reference/cordis/paper.pdf`. Paper page numbers below are the printed page
numbers.

The census covers the TypeScript source and tests in `core`, `loader`, `group`,
`include`, and `hmr`. It also covers package metadata where it changes the
runtime boundary. The checkout was not modified. Its untracked `paper.pdf`
remains untracked.

## Decision

Cordis is useful prior art for an Eta-native component runtime. It demonstrates
tracked cleanup, dynamic provider availability, dependency-scoped lookup,
declarative reconciliation, and module replacement. It does not define an Eta
API.

Eta must keep `Effect.t` unchanged. Eta must express requirements, provisions,
component instances, and lifecycle state at the component-runtime seam. Eta
must not copy Cordis's mutable JavaScript proxy, `Context` API, Node internal
module loader, or TypeScript package surface.

The closest design evidence is:

- Use an Eta scope and an owned disposal record for component effects.
- Use typed keys and typed values, with dynamic provider availability.
- Re-evaluate a component instance when a required provider changes.
- Keep provider bindings readable during dependent teardown.
- Treat configuration loading and HMR as separate optional adapters.
- Treat recovery as observational equivalence. Do not promise physical-state
  equality.

The implementation also exposes important limits. It does not check inverse
correctness, effect independence, dependency cycles, or interface
compatibility. Its HMR rollback is transactional for import and replacement
errors, but not for an asynchronous component `apply` failure.

## Paper model used for comparison

The paper defines temporal composability as complete and safe reversal of a
component's shared-environment changes. It defines spatial composability as
declared dependencies with reactive lifecycle changes. See
`.reference/cordis/paper.pdf`, §1.1, pp. 4–5.

The paper's formal model has these parts:

| Paper model | Paper source | Census use |
| --- | --- | --- |
| Revertible effects and one-sided inverses | §3.1.1–§3.1.3, pp. 9–17 | Compare `Fiber.effect` and disposal. |
| Coeffect provision, notification, isolation, and interception | §3.2.1–§3.2.3, pp. 18–22 | Compare `ReflectService` and loader realms. |
| Unified context and observational equivalence | §3.3.1–§3.3.2, pp. 22–26 | Separate Eta semantics from JavaScript representation. |
| Fiber lifecycle, guarded withdrawal, iteration, inertia, and failure | §4.1–§4.3.4, pp. 28–38 | Compare `Fiber` state transitions. |
| Preservation, recovery, ordering, progress, and confluence | §4.4.1–§4.4.5, pp. 42–53 | Identify assumptions that the code does not check. |
| Effect tracking and coeffect operations | §5.1.1–§5.1.2, pp. 56–57 | Compare the core implementation. |
| Component lifecycle and context access | §5.1.3–§5.1.4, pp. 58–61 | Compare activation and lookup. |
| Declarative configuration and reconciliation | §5.2.1, pp. 61–64 | Compare `EntryTree`, `Entry`, `Group`, and `Include`. |
| HMR classification and transactional reload | §5.2.2, pp. 64–66 | Compare `Hmr.partialReload`. |
| System boundary and emissions | §6.1, pp. 67–68 | Mark effects that Eta cannot reverse. |
| State replacement and future migration | §7.3, pp. 76–77 | Compare HMR state behavior. |

## Package and runtime boundary

The workspace uses Yarn 4 and runs tests through Yakumo and Vitest
([root `package.json`:L2-L36](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/package.json#L2-L36)).
The core package is `cordis` `4.0.0-rc.8`. Loader and include are optional peer
packages in the core metadata
([core `package.json`:L2-L48](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/package.json#L2-L48)).

The loader is `@cordisjs/plugin-loader` `1.0.0-rc.5`. It depends on
`cosmokit` and has an optional Node internal-loader bridge
([loader `package.json`:L2-L53](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/package.json#L2-L53)).
The group package is only an alias for `Group`
([group `src/index.ts`:L1-L3](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/group/src/index.ts#L1-L3)).

Include is `@cordisjs/plugin-include` `1.0.4`. It adds `js-yaml` and supports
JSON, YAML, and YAML JavaScript expressions
([include `package.json`:L2-L33](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/package.json#L2-L33)).
HMR is `@cordisjs/plugin-hmr` `1.0.15`. It requires the timer service and uses
`chokidar`, `picomatch`, `schemastery`, and Node module internals
([hmr `package.json`:L2-L62](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/package.json#L2-L62)).

`ModuleLoader.fromInternal()` selects a Node 24 v2 or Node 22/23 v1 private
loader interface. It first requires `--expose-internals`, then tries the
optional `node-addon-require-builtin` package
([loader `src/internal.ts`:L96-L123](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/internal.ts#L96-L123)).
This is an implementation boundary, not an Eta semantic requirement.

## Core implementation census

### Context, effects, and disposal

`Context` creates a root proxy, a root fiber, a reflection service, a registry,
an event service, and a logger. `Context.extend` derives a context by prototype.
`isolate` and `intercept` derive child maps
([core `context.ts`:L21-L77](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/context.ts#L21-L77)).
This is Cordis's derived realization of isolation and interception. It does not
change the parent map.

`DisposableList.clear()` returns values in reverse insertion order
([core `utils.ts`:L4-L39](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/utils.ts#L4-L39)).
`Fiber.effect` accepts a function, an iterable of disposers, a promise of a
disposer, or an async iterable of disposers. It collects nested effects,
disposes once, and composes asynchronous disposers in reverse order
([core `fiber.ts`:L229-L339](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L229-L339)).

The async-iterator path checks an epoch before each next item. Disposal stops
future iteration after the current item. A promise cannot be canceled, so its
eventual disposer still runs. Invalid effect values raise `TypeError`.
Synchronous setup errors dispose already-collected effects and re-raise. Async
errors are logged by the task guard and remain observable through the returned
thenable.

The tests cover plugin disposal, manual disposal, nested disposal, LIFO order,
async return, async yield, early disposal, and setup errors
([core `dispose.spec.ts`:L7-L74](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/dispose.spec.ts#L7-L74),
[L76-L183](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/dispose.spec.ts#L76-L183),
[L185-L239](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/dispose.spec.ts#L185-L239)).

### Plugin registry and component instances

`RegistryService` resolves function plugins and objects with an `apply` method.
It keys one runtime by callback identity and creates one `Fiber` per
registration. It rejects invalid plugins and inactive parents
([core `registry.ts`:L144-L213](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/registry.ts#L144-L213)).
Deleting a runtime removes it from the registry and calls every fiber disposer.
The delete operation does not await those disposers.

The root fiber has uid `0`. A component instance gets a fresh uid. The fiber
uses `PENDING`, `LOADING`, `ACTIVE`, `FAILED`, `DISPOSED`, and `UNLOADING`
states. Its `await()` waits for inertia and then raises a stored error
([core `fiber.ts`:L78-L127](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L78-L127),
[L460-L485](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L460-L485)).

Creating a component registers its parent disposal effect. Its callback can be a
class constructor, a function, or an object method. Its configuration is
validated by a Standard Schema when one exists. Async validation is rejected.
Validation and apply failures are logged, set the fiber to `FAILED`, and do not
stop sibling fibers
([core `fiber.ts`:L34-L45](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L34-L45),
[L122-L212](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L122-L212),
[L415-L465](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L415-L465)).

The inertia tests show that a loading or unloading transition completes before
a replacement transition starts. A provider can disappear and reappear during
one transition. The final state is then `ACTIVE`
([core `fiber.spec.ts`:L7-L63](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/fiber.spec.ts#L7-L63)).
The update tests cover restart, configuration replacement, and a consumer
update while its provider reloads
([core `fiber.spec.ts`:L106-L182](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/fiber.spec.ts#L106-L182)).

### Dependency resolution and notification

`ReflectService.provide` installs a service under the current isolation symbol
through `ctx.fiber.effect`. The disposer removes the binding, notifies affected
fibers, waits for those fibers, and only then removes the provider's own fiber
store entry
([core `reflect.ts`:L150-L203](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L150-L203)).
This keeps the provider binding available while dependent teardown runs.

`notify` scans registered fibers. A fiber is affected when it declares the key
and resolves it to the same isolation symbol. The fiber rechecks its
implementation and refreshes its target. `Fiber._refresh` forms an epoch from
provider uids. A missing or inactive provider makes the target inactive. A
different provider uid forces a transition even when the value is equal
([core `reflect.ts`:L205-L227](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L205-L227),
[core `fiber.ts`:L371-L413](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L371-L413)).

Property lookup accepts only declared or provided services. An undeclared
lookup, an inactive required lookup, and a write without a provision raise
errors. `get(name, false)` can inspect an inactive implementation. `set` only
accepts the implementation owned by the current fiber
([core `reflect.ts`:L61-L124](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L61-L124),
[L150-L173](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L150-L173)).
The access tests cover undeclared access, duplicate provision, service
injection, and a leaked context after disposal
([core `reflect.spec.ts`:L12-L65](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/reflect.spec.ts#L12-L65)).

`Service` registers itself as a provision. Its filter compares isolation
symbols. Its configuration resolver merges inherited interception records with
the base and head configuration. A service-specific `Config.merge` is used when
present; otherwise shallow object assignment is used
([core `service.ts`:L18-L67](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/service.ts#L18-L67)).

### Events and context interception

Event registration is itself an effect. `on` asserts an active fiber, binds a
traceable listener, and registers it in the current fiber's disposal list.
`once` disposes before it calls the listener. Dispatch supports synchronous
emit, all-settled parallel dispatch, serial short-circuiting, bail
short-circuiting, and waterfall continuation
([core `events.ts`:L72-L166](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/events.ts#L72-L166)).
Parallel dispatch waits for every listener and raises an `AggregateError`.
Normal emit propagates the first synchronous listener error.

The event tests cover filters, all five dispatch modes, listener disposal,
short-circuiting, and error propagation
([core `events.spec.ts`:L17-L157](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/events.spec.ts#L17-L157)).

`Context.intercept` creates a derived interception map. `Service.resolveConfig`
walks that map and merges records
([core `context.ts`:L65-L77](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/context.ts#L65-L77),
[core `service.ts`:L51-L67](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/service.ts#L51-L67)).
Traceable proxies preserve caller and service-shadow metadata. They let
associated properties resolve through a context accessor
([core `utils.ts`:L110-L217](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/utils.ts#L110-L217)).
This behavior is TypeScript and JavaScript representation. It is not an Eta
API requirement.

### Isolation

Core isolation derives a context with an inherited isolation map. A service
filter compares symbols, so the same key can resolve to different providers.
The tests cover local contexts, shared labels, and isolated events
([core `context.ts`:L65-L69](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/context.ts#L65-L69),
[core `isolate.spec.ts`:L7-L122](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/isolate.spec.ts#L7-L122)).

### Core behavior against the paper

The implementation matches the paper's broad lifecycle shape:

1. A component instance owns effects registered through its context.
2. A required provider must be active before the instance reloads.
3. A provider entering `UNLOADING` stops satisfying dependents before its own
   inverse runs.
4. The provider waits for affected dependents before deleting its binding.
5. A transition can chain from reload to unload or unload to reload.
6. A failed reload records failure and removes the instance's effects.

The exact implementation is `_setEpoch`, `_reload`, and `_unload`
([core `fiber.ts`:L385-L458](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L385-L458)).
The corresponding paper machinery is §4.3.1–§4.3.4 and Algorithms 1–5,
pp. 34–38 and 56–60.

The implementation does not check the paper's witness condition. A callback can
return a disposer that does not undo its change. The paper explicitly makes
this an author obligation in §5.1.1, p. 56. It also does not check pairwise
independence or observational equivalence. The paper uses those conditions in
§3.1.3, §3.3.2, and Theorems 61 and 73.

The implementation also has no dependency-cycle detector. Two fibers that
require each other's services remain pending because `_refresh` finds no active
provider. The paper's §6.5, p. 71, describes the same inactive result but says a
runtime can report the cycle. No report path exists in the cited core or loader
code.

## Loader implementation census

### Entries and trees

`EntryOptions` contains `id`, `name`, `config`, `group`, `disabled`, and
`inject`. The loader extension adds `intercept` and `isolate`
([loader `entry.ts`:L8-L15](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/entry.ts#L8-L15),
[loader `isolate.ts`:L5-L14](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/isolate.ts#L5-L14)).
Nested ids use `:`. Groups are always enabled so that a disabled ancestor
controls their children
([loader `entry.ts`:L34-L73](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/entry.ts#L34-L73)).

`EntryTree` owns a recursive entry store. It resolves nested ids, creates and
moves entries, writes the desired tree, and waits for import and inertia tasks
([loader `tree.ts`:L6-L45](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/tree.ts#L6-L45),
[L47-L122](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/tree.ts#L47-L122)).
The base loader tree writes no external file. Its `write()` is a no-op
([loader `index.ts`:L129-L137](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/index.ts#L129-L137)).

### Reconciliation

`Entry.update` first mutates the desired options. Nullable fields delete an
option. A disabled entry disposes its fiber. An active entry computes a
`deepEqual` field diff, emits `loader/partial-dispose`, patches its context,
and updates the fiber for a configuration change or a group
([loader `entry.ts`:L94-L134](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/entry.ts#L94-L134)).
The module name is not in the update condition. Therefore changing an active
entry's `name` does not rebuild its existing fiber. This is an implementation
behavior, and there is no focused test for it.

The loader's internal update hook persists a component's self-update unless
`noSave` is true. A second hook logs a reload
([loader `index.ts`:L72-L86](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/index.ts#L72-L86)).
The loader marks an entry disabled when its tracked root fiber disposes itself
([loader `index.ts`:L88-L127](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/index.ts#L88-L127)).

`Entry._init` imports a module, unwraps default exports, patches the context,
and registers a fiber. Import errors are logged and return without a fiber.
`Entry.init` does not await the newly created fiber
([loader `entry.ts`:L136-L172](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/entry.ts#L136-L172)).
`Entry._resolveConfig` interpolates ordinary entry configuration. Group
configuration stays as an entry list
([loader `entry.ts`:L75-L91](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/entry.ts#L75-L91)).

`Group.update` reconciles child entries by id with `Promise.all`. It creates
new children, updates surviving children, and removes missing children.
`Group.stop` disposes children
([loader `group.ts`:L5-L70](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/group.ts#L5-L70)).
The group service receives `internal/update` and applies its new child list
([loader `group.ts`:L73-L88](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/group.ts#L73-L88)).

The mock loader tests cover initial load, keyed updates, self-update,
self-dispose, pending injection, and the `await` interception
([loader `index.spec.ts`:L23-L95](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/index.spec.ts#L23-L95),
[L98-L150](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/index.spec.ts#L98-L150)).
Group tests cover nested disable and enable, moves across enabled and disabled
groups, and interception inheritance
([loader `group.spec.ts`:L27-L83](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/group.spec.ts#L27-L83),
[L86-L168](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/group.spec.ts#L86-L168),
[L171-L230](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/group.spec.ts#L171-L230)).

The paper's §5.2.1, pp. 61–64, presents `id`, module URL, isolation,
interception, configuration, and disabled state as a faithful desired-state
entry. The implementation adds `inject`, uses `name` in place of `url`, and
restarts a leaf fiber for every active configuration diff. It does not provide
the paper's explicit component-level configuration diff protocol.

### Managed realms and isolation

The loader's `LocalRealm` creates a symbol tagged by entry id. `GlobalRealm`
creates a symbol shared by entries with the same label
([loader `isolate.ts`:L25-L65](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/isolate.ts#L25-L65)).
`entry-init` creates inherited isolation and interception maps.

`loader/patch-context` computes a new map, records changed realms, sets
delimiter tags, swaps maps, reloads the fiber, transfers a provider binding
when delimiter tags prove that the provider moved with the entry, and notifies
affected dependents. `loader/partial-dispose` garbage-collects unused global
realms
([loader `isolate.ts`:L67-L149](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/isolate.ts#L67-L149),
[L151-L168](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/isolate.ts#L151-L168)).

The isolation tests cover provider and consumer realm changes, nested realms,
provider changes, injector changes, and transfer into and out of groups
([loader `isolate.spec.ts`:L38-L138](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/isolate.spec.ts#L38-L138),
[L172-L249](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/isolate.spec.ts#L172-L249),
[L251-L454](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/isolate.spec.ts#L251-L454),
[L457-L537](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/tests/isolate.spec.ts#L457-L537)).

This is close to paper Definitions 27–31 and Algorithm 7, pp. 20–23 and
63–64. The symbol tables, delimiter keys, and prototypal maps are
representation details.

## Include implementation census

`Include` is a loader entry tree. It resolves a path relative to `baseUrl`,
supports `.json`, `.yaml`, and `.yml`, and changes its base URL to the
configuration file's directory
([include `src/index.ts`:L18-L73](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/src/index.ts#L18-L73)).
YAML accepts a custom `tag:yaml.org,2002:js` scalar that stores an expression.
`interpolate` evaluates these expressions through `with (ctx) { eval(expr) }`
([loader `utils.ts`:L1-L28](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/utils.ts#L1-L28)).
This is a powerful implementation feature. It is not a requirement for an
Eta configuration authority.

`Include` reads and parses the file, checks write access, yields a disposer that
stops its child tree, and applies initial patches
([include `src/index.ts`:L76-L180](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/src/index.ts#L76-L180)).
Patches can disable an entry, override fields, insert at the root, or insert
into a named group. Missing ids, non-group insertion targets, missing ids on
non-insert patches, and name mismatches produce warnings and skip the patch
([include `src/index.ts`:L101-L164](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/src/index.ts#L101-L164)).

`refresh()` re-reads changed content and updates the tree without calling
`applyPatches`. The initial load applies a shallow copy of the data, but
refresh uses the raw data. A read error with no `initial` value is reported as
`config file not found`; this masks parse and access errors. Writes use a
zero-delay timer, a temporary file, and rename. Write errors from the timer are
not returned to the caller
([include `src/index.ts`:L166-L216](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/src/index.ts#L166-L216)).

The include tests cover no patches, disable, override, name mismatch, missing
id, root insertion, group insertion, non-group insertion, multiple patches,
and matching names
([include `patch.spec.ts`:L24-L242](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/tests/patch.spec.ts#L24-L242)).
They do not cover refresh, initial file creation, read-only files, malformed
YAML or JSON, expression evaluation, or write failure.

The paper's configuration section treats serialization and module resolution
as loader concerns. It does not require YAML, JavaScript expressions, patch
warnings, or a write-back format. These features belong in an Eta adapter.

## HMR implementation census

### Classification and stale entries

`loadDependencies` traverses Node `ModuleJob.linked` dependencies. It skips
`node:` modules and `node_modules`
([hmr `src/index.ts`:L27-L47](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L27-L47)).
The service requires the loader's private module interface. It watches files
with Chokidar, collects the main process dependency set as `externals`, and
classifies changes into `accepted` and `declined`
([hmr `src/index.ts`:L49-L153](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L49-L153),
[L174-L227](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L174-L227)).

An external change calls `loader.exit()`. The current loader implementation has
an empty `exit()` method, so this default full-reload path is a no-op
([loader `index.ts`:L153-L163](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/index.ts#L153-L163)).
An import-cache hit stashes a URL and debounces partial reload. A matching
Include filename calls `include.refresh`. Other changes emit `hmr/change`.

The classification algorithm matches paper Algorithm 8. It seeds accepted
with stashed files and declined with externals. It accepts a module when one
child is accepted, declines it when all children are declined, and declines
unresolved cycles at the end.

For each loader entry, HMR resolves the configured module name against the
entry tree base URL. It walks the module dependency tree while treating
declined modules as boundaries. An entry reloads only when that tree intersects
accepted
([hmr `src/index.ts`:L229-L273](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L229-L273)).
`getLinked` exposes direct linked URLs and returns an empty list for an unknown
URL
([hmr `src/index.ts`:L160-L165](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L160-L165)).

### Cache invalidation, replacement, and rollback

HMR backs up and deletes both the ESM load cache and the CommonJS
`require.cache`. It uses `Map.prototype.delete` because Node 24's cache delete
has different semantics
([hmr `src/index.ts`:L274-L310](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L274-L310)).

It imports all replacement modules before it disposes the old plugins. An
import failure calls `handleError`, restores both caches, and leaves the old
plugins installed
([hmr `src/index.ts`:L311-L329](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L311-L329),
[hmr `error.ts`:L6-L35](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/error.ts#L6-L35)).

For a successful import, `registry.delete` disposes old fibers. HMR then
creates replacement fibers with old configuration and re-associates each
entry. If disposal or replacement throws, HMR restores caches, deletes
replacement runtimes, and re-registers the old plugin
([hmr `src/index.ts`:L331-L378](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L331-L378)).
The paper's Algorithm 10 has the same import and replacement rollback shape,
§5.2.2, pp. 65–66.

The implementation does not catch a component `apply` failure as a HMR
replacement failure. `registry.plugin` returns a fiber, and the fiber records
the asynchronous apply failure as `FAILED`. The old runtime has already been
deleted. The new plugin's handlers are absent until a later valid replacement.
The HMR test documents this behavior
([hmr `index.spec.ts`:L722-L762](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L722-L762)).
This differs from a broad reading of the paper's transactional guarantee. The
paper describes import failure and replacement rollback, but the source does
not promote an asynchronous component failure into the HMR transaction.

### HMR tests

The tests cover single-plugin reload and disposal, multiple plugins, dependency
reload, syntax-error rollback, recovery, debounce, configuration-file reload,
service replacement, entry re-association, rapid replacement, event handler
addition and removal, linked dependencies, runtime apply errors, and stash
clearing
([hmr `index.spec.ts`:L103-L162](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L103-L162),
[L191-L279](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L191-L279),
[L305-L429](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L305-L429),
[L491-L556](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L491-L556),
[L613-L697](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L613-L697),
[L788-L798](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L788-L798)).

The HMR tests use temporary writes and timeouts. They show observable behavior.
They do not prove the paper's confluence or independence conditions.

## Implementation-only behavior

The following behaviors exist in the checkout but are not Eta requirements:

1. **JavaScript representation.** Context proxies, traceable service shadows,
   decorators, `Service.invoke`, dotted associated properties, and
   `Reflect`-based access are TypeScript and JavaScript mechanisms. The relevant
   proxy and trace code is
   [core `reflect.ts`:L61-L133](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L61-L133)
   and
   [core `utils.ts`:L141-L217](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/utils.ts#L141-L217).
2. **Plugin identity.** Runtime reuse is keyed by the JavaScript `apply`
   function identity. One callback can have multiple fibers. This is not a
   typed component identity model.
3. **Effect forms.** Functions, synchronous generators, promises, and async
   generators are accepted. Promise cancellation is not provided.
4. **Event protocol.** The five dispatch modes, `AggregateError`, internal
   event names, and `internal/update` waterfall are Cordis mechanisms
   ([core `events.ts`:L14-L31](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/events.ts#L14-L31),
   [L89-L126](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/events.ts#L89-L126)).
5. **Loader format.** Random hexadecimal ids, `:`-joined nested ids, dynamic
   `import()`, `default` export unwrapping, YAML JavaScript expressions, and
   in-place tree writes are implementation choices.
6. **Node HMR.** Chokidar, Node private `ModuleJob` objects, ESM and CommonJS
   cache manipulation, `picomatch` ignore rules, and timer-service debounce are
   not backend-neutral lifecycle semantics.
7. **Logging policy.** Most asynchronous failures are logged and the system
   keeps running. A caller can replace the logger methods in tests. The paper
   does not prescribe this logging policy.

## Paper behavior not enforced by this implementation

The paper contains stronger contracts than the runtime checks:

1. **Inverse witness.** The paper requires an inverse that restores the state at
   which the effect ran. Cordis accepts the returned function without checking
   it. See §3.1.2, Definition 8, and §5.1.1, p. 56.
2. **Independence.** The paper requires pairwise independence for out-of-order
   component removal and interleaving. Cordis does not inspect the operations
   performed by an effect. See §3.1.3, Definitions 19 and 39, and §4.4.2.
3. **Observational equivalence.** The paper defines equivalence through the
   operations exposed by a coeffect. Cordis compares provider uid and realm
   symbols. It has no general observer or equivalence relation. See §3.3.2.
4. **Progress assumptions.** The paper's progress theorem assumes finite
   fibers, bounded iterators, an acyclic precedence relation, and pairwise
   independence. The implementation has no theorem check or cycle diagnostic.
   See §4.4.4, Theorem 66.
5. **Confluence assumptions.** The paper's confluence theorem assumes no failed
   fibers, total provision, and pairwise independence. The implementation does
   not test these conditions before reconciliation. See §4.4.5, Theorem 73.
6. **Typed coeffects.** The paper's coeffect context maps each key to a value
   type, an equivalence, and operations. Cordis's runtime keys are strings and
   values are dynamic. TypeScript declarations help callers, but runtime
   compatibility is not checked. See §3.2.1, Definitions 22 and 24, and
   §6.6, pp. 72–73.
7. **Explicit cycle reporting.** The paper discusses reporting mutual
   dependencies. Cordis leaves the involved fibers pending. No loader or core
   test asserts a diagnostic.
8. **Configuration URL replacement.** The paper says a changed component URL
   rebuilds an entry. Cordis names this field `name`, but the active update path
   does not rebuild on a name-only diff. This is a source-level divergence, not
   an Eta requirement.
9. **Component-level configuration policy.** The paper lets a component decide
   how to apply a new configuration. The default Cordis entry path calls
   `fiber.update`, which restarts the fiber for a changed configuration.
10. **HMR failure scope.** The paper's transactional reload algorithm is not
    applied to asynchronous `apply` failure. The old plugin is removed and the
    new fiber becomes failed.
11. **State migration.** The paper says component-local in-memory state does
    not survive a clean replacement and treats migration as future work,
    §7.3, pp. 76–77. Cordis invalidates accepted module caches and creates a new
    fiber. State held by a longer-lived service or an external system can
    remain.

## Error paths

| Condition | Implementation behavior | Evidence |
| --- | --- | --- |
| Invalid plugin | Immediate error. | [`registry.ts`:L193-L197](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/registry.ts#L193-L197); [`plugin.spec.ts`:L29-L48](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/plugin.spec.ts#L29-L48) |
| Effect on inactive fiber | Raises `CordisError` before registration. | [`fiber.ts`:L224-L227](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L224-L227) |
| Invalid effect result | Raises `TypeError`; collected effects are disposed. | [`fiber.ts`:L229-L327](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L229-L327) |
| Apply or reload error | Logs, stores the error, unloads collected effects, and ends `FAILED`. | [`fiber.ts`:L415-L465](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L415-L465); [`fiber.spec.ts`:L65-L104](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/fiber.spec.ts#L65-L104) |
| Disposer error | Logs and continues with other disposers. | [`fiber.ts`:L437-L448](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/fiber.ts#L437-L448); [`fiber.spec.ts`:L87-L104](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/fiber.spec.ts#L87-L104) |
| Undeclared or inactive service access | Raises an enhanced error. | [`reflect.ts`:L71-L98](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L71-L98); [`reflect.spec.ts`:L12-L65](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/tests/reflect.spec.ts#L12-L65) |
| Duplicate service or wrong owner on `set` | Raises an error. | [`reflect.ts`:L162-L190](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/core/src/reflect.ts#L162-L190) |
| Missing loader module | Logs the import error and leaves the entry without a fiber. | [`entry.ts`:L158-L172](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/loader/src/config/entry.ts#L158-L172) |
| Missing Include file | Uses `initial` if configured; otherwise raises `config file not found`. | [`include/src/index.ts`:L166-L175](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/src/index.ts#L166-L175) |
| Invalid Include patch | Logs a warning and skips the patch. | [`include/src/index.ts`:L116-L160](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/src/index.ts#L116-L160); [`patch.spec.ts`:L80-L196](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/include/tests/patch.spec.ts#L80-L196) |
| HMR private loader unavailable | Constructor raises `--expose-internals is required for HMR service`. | [`hmr/src/index.ts`:L78-L85](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L78-L85) |
| HMR import error | Logs formatted error, restores caches, and keeps old fibers. | [`hmr/src/index.ts`:L311-L329](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/src/index.ts#L311-L329); [`hmr/tests/index.spec.ts`:L309-L340](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L309-L340) |
| HMR `apply` error | Old runtime is removed. New fiber fails. HMR stays alive. | [`hmr/tests/index.spec.ts`:L722-L762](https://github.com/cordiverse/cordis/blob/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4/packages/hmr/tests/index.spec.ts#L722-L762) |

## Untested or weakly tested contracts

The existing tests cover the happy lifecycle paths and several adversarial
transitions. The following contracts remain untested in the selected packages:

- No generated or adversarial test checks inverse correctness, observational
  equivalence, independent out-of-order disposal, or confluence.
- No test checks a dependency cycle or a diagnostic for one.
- No test checks provider-binding visibility during an asynchronous dependent
  disposer.
- No test checks invalid effect values, async validation, `Service.check`
  exceptions, `Config.merge`, wrong-fiber `set`, accessor collisions, or
  mixin cleanup.
- No loader test uses the real Node internal module loader. The loader tests use
  `MockLoader`.
- No test checks active `name`, `inject`, duplicate-id, malformed-entry, or
  random-id reconciliation.
- No Include test checks refresh patch reapplication, initial-file creation,
  read-only write behavior, malformed serialization, JavaScript expressions,
  or delayed write errors.
- No HMR test checks externals and the default `loader.exit()` path, ignored
  files, CJS cache restoration, a failed disposer during replacement, or
  multiple replacement failures in one transaction.
- The HMR tests use wall-clock polling and file writes. They do not establish
  deterministic ordering or the paper's progress bounds.

## Verification

The focused test command was attempted:

```text
yarn test packages/core/tests/dispose.spec.ts --run
```

It did not start. The checkout declares Yarn `4.14.1`, but the environment
provides Yarn `1.22.22`. The checkout also has no `node_modules` directory.
No Cordis files were changed.

The research work used source inspection, line-numbered source reads, package
metadata, the supplied paper, and the existing focused test files. The final
research worktree gate is `git diff --check`.

## Unresolved gaps for Eta design

This census does not select the Eta component-runtime API. The next design work
must decide:

1. The typed representation for requirements and provisions.
2. The ownership boundary between an Eta scope and a component context.
3. The failure policy for a failed activation and for a failed disposer.
4. The observable lifecycle states and diagnostic data.
5. The model for provider replacement while a dependent tears down.
6. The desired-state reconciliation law for module, isolation, interception,
   and configuration changes.
7. The rollback boundary for module import, activation, and external effects.
8. The package split between `eta_component` and configuration/HMR adapters.

The paper's system-boundary rule remains decisive. An external emission cannot
be reversed by a component context without withholding or compensation
(`paper.pdf`, §6.1, pp. 67–68). This is a semantic boundary, not a Cordis API
detail.

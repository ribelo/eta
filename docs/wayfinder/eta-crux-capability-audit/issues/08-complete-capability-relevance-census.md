# Complete capability relevance census

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Which inventoried capability families require an Eta Crux decision?

Review the complete current, historical, reference, substrate, and consumer
censuses. Classify every capability family as:

- an Eta Crux candidate that needs a detailed decision.
- useful design evidence for an existing candidate.
- framework-specific and out of scope.

Record one reason for each non-candidate family. Confirm that all nine reported
gaps already have decision tickets. Create one decision ticket for every
additional candidate and remove its subject from the map fog.

Do not adopt, defer, or reject the new candidates in this ticket.

## Answer

The census uses three relevance classes:

- **Candidate** means that a detailed Eta Crux decision is still necessary.
- **Evidence** means that the family informs a current capability or a candidate.
- **Out of scope** means that the contract belongs to a reference framework or
  an optional provider.

Evidence does not create a new Eta Crux decision. This answer does not adopt,
defer, or reject any candidate.

The evidence comes from the
[current baseline](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md),
[decision history](../../../../.scratch/research/eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md),
[Bonsai census](../../../../.scratch/research/eta-crux-capability-audit/bonsai-public-capability-census.md),
[Rust Crux census](../../../../.scratch/research/eta-crux-capability-audit/rust-crux-public-capability-census.md),
[Elm census](../../../../.scratch/research/eta-crux-capability-audit/elm-public-capability-census.md),
[Eta substrate audit](../../../../.scratch/research/eta-crux-capability-audit/06-eta-substrate-capability-support.md),
and
[consumer audit](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md).

### Candidate closure

All nine reported gaps have detailed decision tickets:

| Reported gap | Decision ticket |
|---|---|
| Graph time and deterministic clock control | [Graph time and deterministic clock control](09-graph-time-and-deterministic-clock-control.md) |
| External graph input | [External graph input](10-external-graph-input.md) |
| Startup facts and flags | [Startup facts and flags](11-startup-facts-and-flags.md) |
| Staged-effect observability | [Staged-effect observability](12-staged-effect-observability.md) |
| Host-owned streaming operations | [Host-owned streaming operations](13-host-owned-streaming-operations.md) |
| Ingress admission classes | [Ingress admission classes](14-ingress-admission-classes.md) |
| Pull observation of root output | [Pull observation of root output](15-pull-observation-of-root-output.md) |
| Host-operation layers | [Host-operation layers](16-host-operation-layers.md) |
| Action history and diagnostics | [Action history and diagnostics](17-action-history-and-diagnostics.md) |

The complete census adds two candidates:

- [Structural model reset](20-structural-model-reset.md) covers reset traversal
  across framework-owned nested state. Prior-value storage remains
  application-composable.
- [Latest-request-wins effect coordination](21-latest-request-wins-effect-coordination.md)
  covers stale results across overlapping work and child incarnations. Basic
  change-triggered effects remain application-composable.

### Bonsai families

| Family | Class | Reason or decision |
|---|---|---|
| 1. Reactive graph values and composition | Evidence | Eta Crux already owns computation composition and cutoff. |
| 2. External inputs and host variables | Candidate | [External graph input](10-external-graph-input.md) decides whether a separate host input belongs in the graph. |
| 3. State, state machines, and actors | Evidence | Eta Crux already owns typed state machines, actions, and staged effects. |
| 4. Model scope, reset, and value history | Candidate | [Structural model reset](20-structural-model-reset.md) covers nested reset. Applications can store prior values in models. |
| 5. Dynamic, lazy, and recursive structure | Evidence | `bind`, `Assoc`, and lifecycle already supply the relevant dynamic structure. |
| 6. Dynamic context | Evidence | Eta Crux keeps dependencies explicit. No consumer shows harmful dependency threading. |
| 7. Time | Candidate | [Graph time and deterministic clock control](09-graph-time-and-deterministic-clock-control.md) covers graph deadlines and test time. |
| 8. Lifecycle hooks | Evidence | Eta Crux already owns active intervals, lifecycle effects, sources, and disposal. |
| 9. Edge-triggered operations and polling | Candidate | [Latest-request-wins effect coordination](21-latest-request-wins-effect-coordination.md) covers stale results. Applications can compare changed values. |
| 10. Effects, graph sampling, and scheduling | Evidence | Opaque staged effects exist. [Staged-effect observability](12-staged-effect-observability.md) covers the test gap. |
| 11. Effect concurrency and coordination | Evidence | Eta already supplies bounded parallelism, semaphores, and supervision. Admission policy informs [Ingress admission classes](14-ingress-admission-classes.md). |
| 12. Shared keyed computations | Evidence | The reference-count law informs keyed lifetimes, but the product depends on Bonsai activation internals. |
| 13. Incremental integration | Evidence | This family connects Bonsai to its substrate. It is not an application capability. |
| 14. Graph paths and stable identity | Out of scope | Its identity encodes Bonsai topology and serialized association keys. |
| 15. Host runtime integration | Evidence | Eta Crux already owns drivers, adapters, hosted loops, and transport bindings. |
| 16. Debugging and introspection protocols | Evidence | Observation points inform [Action history and diagnostics](17-action-history-and-diagnostics.md). The Bonsai graph schema does not transfer. |
| 17. Bidirectional state synchronization and stability | Evidence | Applications own persistence, setters, conflict policy, equality, and stability duration. |
| 18. Deterministic test driving | Evidence | The current test handle exists. Clock control remains in [Graph time and deterministic clock control](09-graph-time-and-deterministic-clock-control.md). |
| 19. Test observation and snapshots | Evidence | The family informs [Staged-effect observability](12-staged-effect-observability.md) and [Pull observation of root output](15-pull-observation-of-root-output.md). |
| 20. Test effects and input isolation | Evidence | Eta controlled dependencies and Eta Crux test adapters already supply the base controls. |
| 21. Computation and performance reports | Evidence | The test pattern is useful, but its counters depend on Bonsai and Incremental internals. |

### Rust Crux families

| Family | Class | Reason or decision |
|---|---|---|
| 1. Application state and event transitions | Evidence | Eta Crux already owns typed actions, state machines, and advancement. |
| 2. View projection and render notification | Candidate | Root output exists. [Pull observation of root output](15-pull-observation-of-root-output.md) covers the missing pull contract. |
| 3. Core runtime and shell boundary | Evidence | Eta Crux already owns the root, driver, adapter, host, and wire boundaries. |
| 4. Operations, effects, requests, and resolution | Candidate | One-shot requests exist. [Host-owned streaming operations](13-host-owned-streaming-operations.md) covers many-response requests. |
| 5. Commands and asynchronous orchestration | Evidence | Eta effects already supply sequential and concurrent orchestration. |
| 6. Command builders and dependent chains | Evidence | Eta effect combinators already express dependent work without a Crux command product. |
| 7. Streaming requests and subscriptions | Candidate | [Host-owned streaming operations](13-host-owned-streaming-operations.md) decides the repeated host-event contract. |
| 8. Cancellation and command task lifecycle | Evidence | Eta scopes and current Crux source and request protocols own cancellation. Shell cleanup informs the streaming decision. |
| 9. Child application and command composition | Evidence | Eta Crux computations already compose typed child behavior into parent graphs. |
| 10. Core middleware and internal effect handling | Candidate | [Host-operation layers](16-host-operation-layers.md) decides whether layers add a public contract. |
| 11. Type-based effect routing | Evidence | Per-operation routing informs host layers. Rust lane ownership does not transfer. |
| 12. Serialized bridge and wire formats | Out of scope | This bridge targets Rust cores in generated foreign-language shells. Eta Crux has its own wire contract. |
| 13. Effect declaration and generated adapters | Out of scope | The family depends on Rust macros, enums, and trait coherence. |
| 14. Foreign type generation | Out of scope | The generator depends on Rust reflection and foreign-language package generation. |
| 15. HTTP capability and protocol | Evidence | It validates the generic host-operation boundary. HTTP code belongs in an optional package. |
| 16. HTTP client middleware | Evidence | Ordering informs [Host-operation layers](16-host-operation-layers.md). The active Rust API does not run this middleware. |
| 17. Key-value capability and protocol | Evidence | It validates typed host operations. Persistence policy belongs in an optional package or application. |
| 18. Time and cancellable timers | Candidate | [Graph time and deterministic clock control](09-graph-time-and-deterministic-clock-control.md) compares graph, shell, and application ownership. |
| 19. Direct command inspection and resolution tests | Candidate | [Staged-effect observability](12-staged-effect-observability.md) decides direct observation without adopting a command algebra by default. |
| 20. Generated effect test helpers | Evidence | Typed helper behavior informs staged-effect tests. Rust macro generation does not transfer. |
| 21. HTTP response and rejection test values | Evidence | Provider fixtures demonstrate deterministic host-operation tests. They do not require a core capability. |
| 22. Legacy application test driver | Evidence | Persistent-driver behavior informs the current test handle. Rust Crux retains this API only for migration. |

### Elm families

| Family | Class | Reason or decision |
|---|---|---|
| 1. Programs and runtime loop | Evidence | Eta Crux already owns a host-driven state-machine root and runtime loop. |
| 2. Flags and initialization input | Candidate | [Startup facts and flags](11-startup-facts-and-flags.md) decides whether construction values need a distinct contract. |
| 3. Messages, model transitions, and view projection | Evidence | Eta Crux already owns actions, state transitions, and complete root output. |
| 4. Commands | Candidate | Opaque staged effects exist. [Staged-effect observability](12-staged-effect-observability.md) covers missing test observation. |
| 5. Subscriptions | Candidate | [Host-owned streaming operations](13-host-owned-streaming-operations.md) decides host-owned event-source lifecycle. |
| 6. Tasks and typed asynchronous results | Evidence | Eta effects already own typed failure and asynchronous composition. |
| 7. Processes, sleep, and cancellation | Candidate | Eta owns fibers and cancellation. Graph time and shell cleanup remain in their named candidate tickets. |
| 8. Effect managers and routers | Out of scope | The contract depends on compiler-approved Elm effect modules and kernel access. |
| 9. Ports | Out of scope | Ports depend on Elm compiler declarations, generated JavaScript, and application-package restrictions. |
| 10. Random generators and seeded execution | Evidence | Eta already supplies injected random capabilities and deterministic test random. |
| 11. Time and zones | Candidate | [Graph time and deterministic clock control](09-graph-time-and-deterministic-clock-control.md) covers time reads, wakes, and test control. |
| 12. HTTP | Evidence | HTTP validates typed host operations. Provider code belongs in an optional package. |
| 13. Files and downloads | Evidence | File operations validate host operations and sources. Browser-specific policy does not belong in core. |
| 14. Bytes and binary codecs | Evidence | Codec composition informs the existing boundary. It owns no independent effect lifecycle. |
| 15. Browser program adapters | Evidence | Their progression informs host-adapter boundaries. Each concrete form remains browser-specific. |
| 16. Browser event subscriptions | Evidence | The source shape informs host-owned streaming. The event contracts remain browser-specific. |
| 17. Browser DOM tasks | Evidence | Typed host queries inform host operations. DOM geometry and mutation remain browser-specific. |
| 18. Navigation, history, and URLs | Evidence | Authority tokens and simulation inform host boundaries. Browser history remains application or provider policy. |
| 19. HTML, SVG, and virtual DOM UI | Out of scope | The family depends on Elm virtual nodes and runtime patch behavior. |
| 20. JSON boundary codecs | Evidence | Boundary validation informs current codecs. It is a data contract, not a new lifecycle. |
| 21. Development debugging | Evidence | Development fences inform diagnostics. Elm compiler restrictions do not transfer. |
| 22. Unit tests, expectations, and fuzz tests | Evidence | Eta test and QCheck own general generators, shrinking, and law execution. |
| 23. Test execution and failure reports | Evidence | Structured counterexamples inform test quality. They do not define an Eta Crux runtime contract. |
| 24. HTML query and event tests | Out of scope | These tests inspect Elm virtual-DOM representations. |
| 25. Whole-program deterministic driver | Candidate | The current handle supplies the driver. Time, staged effects, and pull observation have named decisions. |
| 26. Simulated commands, tasks, effects, and subscriptions | Candidate | Controlled effects exist. Staged observation and streaming have named decisions. |
| 27. Program boundary simulation and observation | Candidate | The current test shell exists. Staged effects and pull output have named decisions. |
| 28. Compiler and package tooling | Out of scope | The family implements Elm syntax, metadata, version policy, and registry behavior. |

### Current, historical, substrate, and consumer closure

Every current production family is evidence for the current surface or a named
candidate:

- Computation, cutoff, state machines, lifecycle, keyed children, and sources
  establish the graph baseline.
- Endpoints, exports, host operations, requests, responses, codecs, and remote
  handles establish the typed boundary baseline.
- Root advancement, post-commit work, drivers, adapters, hosted loops, wire
  frames, and serialized sessions establish the host protocol baseline.
- Failures, crash snapshots, and fixed telemetry inform
  [Action history and diagnostics](17-action-history-and-diagnostics.md).
- Incoming injection, the test shell, the test handle, controlled sources, and
  the recording adapter inform the test candidates.
- JSON and S-expression formats validate wire-format substitution. Benchmark
  rows are performance evidence, not a capability.

The seven named historical requirements also have complete destinations.
`tick-k9r2` and `eng-6h8t` inform
[Graph time and deterministic clock control](09-graph-time-and-deterministic-clock-control.md).
`test-h5w3`, `test-r8k2`, `test-3h6t`, `test-b5r8`, and `cmd-r5w9`
inform [Staged-effect observability](12-staged-effect-observability.md).
No historical gap is accidental.

The Eta substrate adds no separate Eta Crux candidate. Its missing mechanics
already map to graph time, staged-effect observation, host-owned streaming,
ingress admission, host-operation layers, and diagnostics. Available Eta
clocks, queues, scopes, streams, observability, and test controls remain design
evidence for those decisions.

Consumer evidence adds no separate candidate. Time, effect assertions,
many-response work, admission policy, output caches, dispatch layers, and
diagnostics map to the named candidate tickets. Decode tables, claim protocols,
rollback, duplicated state, shadow queues, and domain history remain
application-specific. They occur in one indirect consumer and depend on its
domain policy.

The relevance census is complete. It accounts for all 21 Bonsai families, all
22 Rust Crux families, all 28 Elm families, and all local evidence.

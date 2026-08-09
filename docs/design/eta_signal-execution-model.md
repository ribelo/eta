# Eta Signal execution model

Status: production pre-alpha

## Purpose

This specification describes the implemented execution model for `eta_signal`
and `eta_signal_map`. It is the architecture reference for maintenance and later
optimization.

The implementation is usable and behavior-correct. Wall-time optimization is a
separate effort.

## Authority and scope

The public `.mli` files define the installed interfaces. The
[behavior census](../../.scratch/research/eta-signal-execution-model/binding-signal-behavior.md)
indexes the binding tests and observation points.

This specification describes these production paths:

- `lib/signal/eta_signal.ml`
- `lib/signal/eta_signal.mli`
- `lib/signal/kernel/`
- `lib/signal_map/`
- `lib/signal_stream/`

Eta Crux is outside this specification. It is a consumer of the public Signal
interfaces.

The frozen [performance acceptance matrix](../../.scratch/research/eta-signal-execution-model/performance-acceptance-matrix.md)
remains the later optimization target. This specification does not weaken its
workloads, formulas, or limits.

## Public use

Each application of `Eta_signal.Make` creates one graph identity. The graph has
one owner domain.

```ocaml
module S = Eta_signal.Make (Eta_signal.No_observer_error) ()

let get_ok = function
  | Ok value -> value
  | Error _ -> failwith "signal operation failed"

let source = S.Var.create 1
let doubled = S.map (fun value -> value * 2) (S.Var.watch source)
let observer =
  get_ok (S.Observer.observe doubled ~on_update:(fun _update -> Ok ()))

let () =
  get_ok (S.stabilize ());
  get_ok (S.Var.set source 2);
  get_ok (S.stabilize ());
  Printf.printf "%d\n" (get_ok (S.Observer.read observer));
  get_ok (S.Observer.dispose observer)
```

Graph builders and hot-path operations are synchronous. Timer constructors and
`Var.update_effect` are Eta effects because they need runtime capabilities.

## Public interface rules

| Area | Implemented rule |
|---|---|
| Graph identity | `Make` is generative. Values from different applications do not compose. |
| Domain ownership | Graph operations run on the creating domain and outside registered worker callbacks. Invalid use raises `Invalid_argument`. |
| Construction | `const`, `map`, `bind`, `Var.create`, `Var.watch`, and cutoff combinators return synchronously. |
| Mutation | `Var.set` accepts a value but does not stabilize the graph. |
| Stabilization | `stabilize ()` publishes one snapshot, then delivers post-commit work. |
| Observation | `Observer.read` returns the last committed observed value. It never stabilizes the graph. |
| Callback failure | A typed callback failure settles that event and returns `Observer_error`. A callback exception leaves the event pending. |
| Disposal | `Observer.dispose` is synchronous, checked, and idempotent. |
| Timers | Each timer retains its creating runtime. One stabilization shares one clock sample for each runtime. |
| Map adaptation | `Eta_signal_map.Make (Signal.Package)` adds keyed work to the existing graph. |

The complete behavior remains in `lib/signal/eta_signal.mli` and
`lib/signal_map/eta_signal_map.mli`.

## Module ownership

The private Signal kernel is one wrapped, uninstalled Dune library:
`eta_signal_kernel`. The `eta_signal` package owns this library.

```text
Eta_signal
    |
    v
Graph ---------------------> Eta.Effect
  | \
  |  \---------------------> Post_commit
  |
  +------------------------> Propagation

Eta_signal_map
    |
    v
Eta_signal_map_api --------> Signal.Package
    |
    v
Eta_signal_map_kernel
```

`Propagation` and `Post_commit` are independent leaves. Neither leaf imports
the other leaf or Eta. `Graph` composes both leaves and owns the Eta effect
seam.

### `Propagation`

Path: `lib/signal/kernel/propagation.ml`

Invariant: only the current handle generation can participate. Stale nodes run
after stale dependencies. A failed pass restores committed values and topology.

`Propagation` owns:

- node and scope storage
- generation-safe slots
- source admission
- height-ordered propagation queues
- cutoff evaluation
- the sparse undo journal
- dynamic topology capsules
- keyed reconciliation
- affected-only cleanup

### `Post_commit`

Path: `lib/signal/kernel/post_commit.ml`

Invariant: the driver alone settles observer cursors, timer generations, cleanup
hooks, and stream acknowledgements.

`Post_commit` owns:

- observer publication and acknowledgement
- callback claim and retry state
- finish hooks
- timer demand and generations
- timer start and stop actions
- cleanup failure aggregation

### `Graph`

Path: `lib/signal/kernel/graph.ml`

Invariant: one owner domain and one phase machine authorize every public graph
operation.

`Graph` owns:

- the public functor result
- owner-domain checks
- graph phases
- public error conversion
- Signal construction
- observer ordering
- timer runtime integration
- diagnostics
- the `Package_graph` stable-family seam

`Graph.Make_impl` remains the repo-private constructor for the typed test probe.
External callers use only `Graph.Make` through `Eta_signal.Make`.

## Core representations

### Nodes and handles

Each typed node stores its current value, undo value, write stamp, computation,
cutoff, dependencies, and dependents. It also stores demand, queue, scope, and
diagnostic fields.

The arena stores heterogeneous nodes as existential `packed` values. A long-lived
handle contains a dense slot and an integer generation.

Lookup compares both handle fields. A stale handle cannot name a later node in
the same slot.

Each slot contains:

- its current generation
- a strong packed-node reference while necessary
- a weak packed-node reference while reclaimable
- its free-list state

The allocator can reuse an old free slot. It cannot reuse a slot quarantined by
the current pass.

### Propagation graph

The propagation graph keeps array-backed storage for:

- slots
- free slots and quarantined slots
- the sparse value journal
- structural actions
- dynamic capsules
- normal and topology-priority height queues
- retained source admissions
- pending reclamation handles
- bounded diagnostic tombstones

The journal stores dense slot integers. Each node enters the journal at its
first write in one pass.

### Dynamic scopes

A scope contains a validity flag and an intrusive slot chain. A bind switch
creates one candidate scope and candidate branch.

Dynamic capsules contain rollback and cleanup functions. Rollback restores the
old branch. Cleanup invalidates retired scopes after commit.

### Keyed owners

A keyed owner stores committed input, committed children, and the committed
output root. It also stores candidate children and a candidate output root for
the active pass.

Each present key owns one child incarnation, one data source, one scope, and one
child signal. Continuous presence keeps that identity.

## State transitions

### Public graph phases

```text
Idle
  |
  | stabilize
  v
Planning
  |
  | commit or rollback
  v
Idle
  |
  | post-commit work
  v
Delivering
  |
  v
Idle
```

Construction outside a valid scope raises `Graph_error`. A stabilization during
`Delivering` returns `Reentrant_stabilization`.

### Propagation pass

One successful pass uses this sequence:

1. Admit pending sources and initializers.
2. Enter `Active`.
3. Drain topology-priority work, then normal height work.
4. Evaluate affected necessary nodes.
5. Run the pre-commit checkpoint.
6. Reset the journal length and advance the pass identity.
7. Clear retained admissions.
8. Run affected structural cleanup when required.

A static pass has no structural capsule or structural cleanup work.

### Rollback

A failed pass uses this order:

1. Restore retired identities and topology.
2. Run structural capsule rollback in reverse order.
3. Restore journaled values in reverse order.
4. Discard nodes created by the failed pass.
5. Clear propagation queues.
6. Advance the pass identity.
7. Replay retained source admissions.

This order keeps the last committed snapshot observable and retryable.

### Observer delivery

An observer cursor uses these states:

```text
Never_delivered
      |
      v
Pending(token, Initialized value)
      |
      v
Delivered(value)
```

A later publication creates `Pending(token, Changed(old, new))`. A typed callback
failure settles the pending event and reports the typed error.

A callback exception leaves the event pending. The next stabilization can
retry that exact event. The settle guard matches the pending delivery token,
so a claimed event needs no separate running state.

### Timer lifecycle

A timer uses `Inactive`, `Starting generation`, or
`Running(generation, stop)`. Demand mismatch queues one start or stop action.

A wake publishes only when runtime identity, generation, and demand all match.
Demand loss fences the active generation before cancellation.

A daemon failure moves `Starting` or `Running` to `Inactive`. A demanded timer
returns to the action queue and restarts at the next driver pass.

The public regression is
`timer daemon wake defect restarts while demanded` in
`test/signal/test_eta_signal.ml`.

## Signal Map seam

`Eta_signal_map` depends on the public, sealed `Package_graph` protocol. It does
not depend on `eta_signal_kernel`.

The protocol accepts one stable-family plan. It exposes no graph, node, edge,
scope, phase, queue, or rollback authority.

The map package owns:

- `Eta_signal_map.Map`
- persistent symmetric diff
- the `Keyed(Order).mapi` adapter
- input and output map operations

The Signal kernel owns the stable-family lifecycle and atomic publication. The
map adapter supplies ordered-map operations and the child builder.

## Error model

| Phase | Error channel |
|---|---|
| Construction | Raise `Graph_error`. |
| Synchronous graph operation | Return the documented result error or raise a defect. |
| Stabilization planning | Return `graph_error` for contract failures. Raise user defects. |
| Observer callback | Return `Observer_error` for typed callback failure. Raise callback defects. |
| Timer construction | Use the Eta typed error channel. |
| Wrong owner context | Raise `Invalid_argument`. |

Counter exhaustion fails before integer wrap. The implementation has no silent
fallback and no compatibility path.

## Package ownership

| Package | Installed surface | Runtime dependencies |
|---|---|---|
| `eta_signal` | `Eta_signal` | `eta`, `eta_observability` |
| `eta_signal_map` | `Eta_signal_map` | exact same `eta_signal` release |
| `eta_signal_stream` | `Eta_signal_stream` | `eta_signal`, `eta_stream`, `eta_observability` |

The root `eta` package does not contain Signal or Signal Map. The private
`eta_signal_kernel` library has no `public_name`.

## Replacement route

The usable pre-alpha replacement is complete:

1. The promoted kernel replaced the old engine in production.
2. The synchronous owner-domain interface replaced the lane protocol.
3. `Propagation`, `Post_commit`, and `Graph` replaced history-based module names.
4. `Eta_signal_map` moved to the public `Package_graph` seam.
5. The typed repo-private probe replaced the old `Obj.t` testing token.
6. The demanded-timer restart defect was fixed at the `Post_commit` seam.
7. The current behavior gate replaced aliases for deleted representation tests.

Future architecture work changes these production modules directly. It must not
add an old-engine fallback, compatibility adapter, or feature flag.

## Verification

Use the OxCaml Nix shell:

```sh
nix develop -c dune build @signal-gates @install
EIO_BACKEND=posix nix develop -c dune runtest --force
EIO_BACKEND=posix nix develop -c eta-oxcaml-test-shipped
```

`@signal-gates` runs the current Signal, Signal Map, law, model-fuzz, negative
compile, and deterministic map-complexity suites.

## Performance baseline and deferral

The following focused baseline used one process, three samples, and CPU 2. It is
diagnostic evidence, not the complete acceptance protocol.

| Public workload | Incremental median | Eta median | Eta words | Wall ratio |
|---|---:|---:|---:|---:|
| changed depth 1 | 51.968 ns | 487.804 ns | 328 | 9.387 |
| changed depth 10 | 129.798 ns | 1,395.975 ns | 472 | 10.755 |
| changed depth 100 | 1,073.902 ns | 15,552.490 ns | 2,524 | 14.482 |
| cutoff depth 10 | 32.240 ns | 1,210.957 ns | 432 | 37.561 |
| dynamic switch | 141.403 ns | 2,833.677 ns | 645 | 20.040 |

The focused raw scalar rows allocated no words after warm-up. Their wall ratios
were `1.004`, `1.312`, `1.405`, and `1.966`.

These results do not pass the frozen `1.20` wall-time gate. This map accepts the
usable and behavior-correct implementation before optimization.

The later performance effort must run all three nine-sample process pairs. It
must preserve every frozen workload and formula.

## Rejected paths

The implementation does not use:

- a graph lane or per-operation fiber protocol
- immutable whole-graph snapshots
- persistent state for each pass
- a universal transaction over every recomputed node
- explicit public edge cursors
- a general Eta runtime primitive for Signal
- a private kernel dependency from `eta_signal_map`
- a fallback to the old engine

These paths either failed behavior, module-depth, allocation, or wall-time
evidence during the Wayfinder work.

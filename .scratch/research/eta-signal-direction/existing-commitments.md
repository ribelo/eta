# Existing Signal and Eta Crux commitments

## Scope and reading rule

The direction map makes external consumer usefulness the primary test. Repository
use is inventory only. Existing prose, tests, ADRs, and implementation can be
reopened. (`docs/wayfinder/eta-signal-direction/map.md:20-25,35-56`)

This report uses these dispositions:

- **confirm**: keep the need and the current choice.
- **amend**: keep the need, but change the current choice or wording.
- **replace**: use a later accepted choice instead of an older one.
- **provisional**: record the input, but leave the design decision to the named
  later ticket.

## Source baseline

| Source | Status and authority |
|---|---|
| `docs/wayfinder/eta-signal-direction/map.md:5-25,35-62,70-123` | Current planning map. It sets the consumer-first rule, the evidence limit, and the resolved results of tickets 01-07. |
| `docs/prds/0002-eta-signal-frp.md:3-7,32-70,72-149,545-647,648-781` | Draft Signal product target. It contains the broad contract and a later self-audit. It is evidence, not a final answer. |
| `docs/design/eta_signal-kernel-contract.md:5-12,14-118` | Current kernel behavior target. It defines the public facade boundary and the intended phase, demand, error, dynamic-scope, and stream rules. |
| `docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:3-27,41-49` | Accepted package decision. It keeps keyed collections in `eta_signal_map` and the graph protocol package-private. |
| `docs/requirements/eta-signal/README.md:8-21` and `docs/requirements/eta-signal/keyed-extension.md:8-35` | Signal package requirements. They define the optional core and the private keyed seam. |
| `docs/requirements/eta-signal-map/README.md:8-34` and `docs/requirements/eta-signal-map/keyed-map.md:12-17,67-141` | Signal Map package requirements. They define the persistent map, keyed children, transactions, diagnostics, and performance contract. |
| `docs/wayfinder/eta-signal-keyed-map/map.md:32-47,49-64` | Completed Signal Map design map. Its decisions are stronger than the older Crux keyed sketch. |
| `docs/wayfinder/eta-signal-keyed-map/issues/12-eta-crux-integration-boundary.md:12-29,35-87` | Completed Crux integration decision. It replaces the old `Stdlib.Map.S` and `data_equal` sketch. |
| `docs/design/eta-crux-v1/` | Current Eta Crux V1 authority. It defines the public API, wire protocol, semantic laws, and verification gates. |
| `docs/wayfinder/eta-crux-first-principles/map.md:19-51,53-72` and resolved issues `docs/wayfinder/eta-crux-first-principles/issues/01-eta-crux-direction.md:21-37`, `docs/wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md:30-36,91-119,159-161`, `docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md:27-62,80-120,122-191`, `docs/wayfinder/eta-crux-first-principles/issues/05-action-effect-protocol.md:29-45,85-123`, `docs/wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md:89-114,116-160`, and `docs/wayfinder/eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md:28-49,75-127` | Resolved first-principles design evidence. It keeps raw Signal private and defines Crux identity, advancement, keyed lifetime, and work ownership. |
| `lib/crux/`, `lib/crux_test/`, and `eta_crux.opam` | Current production implementation. Its public shell follows the V1 design, but its custom graph and old Signal helper seams are not target architecture. |
| `lib/signal/eta_signal.mli:122-241,262-373,375-565,567-587,589-699,702-765` and `lib/signal_map/eta_signal_map.mli:1-187` | Current public API authority. These interfaces expose the actual Signal and Signal Map surfaces. |
| `dune-project:38-60`, `eta_signal.opam:1-18`, `eta_signal_map.opam:1-18`, `docs/packages.md:151-171`, and `lib/signal_map/README.md:1-22,38-50,98-120` | Current package and README evidence. The generated opam files confirm the optional package boundary and exact version coupling. |
| `lib/signal/kernel/dune:1-5`, `lib/signal_map/api/dune:1-5`, and `lib/signal_map/api/eta_signal_map_api.ml:40-76` | Current Signal implementation evidence. Signal Map uses a package-private kernel and calls `Signal.Extension.keyed_mapi`. This is not a Crux implementation. |
| `docs/wayfinder/eta-signal-direction/issues/01-complete-repository-evidence.md:45-75` and tickets 02-07 | Resolved evidence work. It confirms the current defects and says that later tickets still own the design. |
| `.scratch/research/eta-signal-direction/claim-census.md:732-781` | Traceability source. It gives every review claim one owner. Ticket 08 is not an owner. |
| `docs/design/eta-crux-v1/README.md`, `public-api.md`, and `semantic-laws.md` | Current HEAD design authority. Ticket 14 reconciles its Signal integration with the final Signal direction. |

## Implementation evidence limit

Current Signal and Signal Map production code is identifiable. The package-private
kernel and the Map API are present in the paths listed above. The current public
Signal Map implementation uses `Keyed(Order).mapi`, not a public
`Keyed_map` node. (`lib/signal_map/api/eta_signal_map_api.ml:40-76`,
`lib/signal_map/eta_signal_map.mli:118-185`)

The current repository contains production Eta Crux code under `lib/crux/` and
public test support under `lib/crux_test/`.

The implementation confirms graph-neutral descriptions, drivers, wire behavior,
failures, requests, sources, and test-harness shape. It does not instantiate
`Eta_signal.Make`. It owns a custom dependency graph and uses the old
`Eta_signal.Owner_transaction` and `Eta_signal_map.Keyed_map` seams.

Ticket 14 treats that engine as implementation evidence, not as target
architecture.

## Commitment matrix

| Topic | External consumer need | Implementation choice in the evidence | Disposition |
|---|---|---|---|
| Fine-grained graph and explicit stabilization | Consumers need derived values, batching, dependency order, cutoffs, and effect integration without a hidden event loop. (`docs/prds/0002-eta-signal-frp.md:9-43`) | `set` marks work. `stabilize` is the propagation boundary. Graph construction is functorized. (`docs/prds/0002-eta-signal-frp.md:94-131,177-192`, `lib/signal/eta_signal.mli:122-165,543-565`) | **confirm** |
| Derived reads and graph liveness | Consumers need a stable read that also explains why the derived graph stays live. | Observer handles own demand and disposal. `Observer.read` is the effectful read surface. Raw derived signals have no value read. (`docs/prds/0002-eta-signal-frp.md:297-365`, `lib/signal/eta_signal.mli:320-373`) | **confirm** |
| Source values and cutoffs | Consumers need explicit control of identity versus structural equality. | Physical equality is the default. Source, node, observer, and stream cutoffs accept explicit equality functions. (`docs/prds/0002-eta-signal-frp.md:390-443`, `lib/signal/eta_signal.mli:262-318,375-415,496-522`) | **confirm** |
| Atomic pure publication | Consumers need no partial derived state after a graph error. They also need retryable source updates. | The PRD and kernel contract promise an atomic pure snapshot. N1 shows that phase entry can still leave `pure` state with no transaction. N2 shows that keyed removal can leave an invalid topology. (`docs/design/eta_signal-kernel-contract.md:14-39,81-93`, `docs/wayfinder/eta-signal-direction/issues/02-atomic-phase-entry.md:22-54`, `docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md:31-60`) | **amend**. Ticket 09 |
| Error boundary and retry | Consumers need typed expected failures, defects for callback exceptions, and a usable graph after a failed pure operation. | The public types expose operation-scoped errors and retry prose. The forced-overflow implementation instead raises `Invalid_argument` and wedges the graph. (`lib/signal/eta_signal.mli:125-161,543-565`, `docs/wayfinder/eta-signal-direction/issues/02-atomic-phase-entry.md:22-30`) | **amend**. Tickets 09 and 16 |
| Dynamic `bind` and scope lifetime | Consumers need branch changes that detach old dependencies and reject captured inactive nodes. | `bind` is public and scope errors are typed. The current invalidation order violates the required closure invariant. (`docs/prds/0002-eta-signal-frp.md:255-280`, `lib/signal/eta_signal.mli:524-541`, `docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md:52-60`) | **amend**. Ticket 09 |
| Observer lifecycle | Consumers need initialization, changed values, explicit disposal, demand release, and a clear invalid-state error. | The public surface has `Initialized` and `Changed`, opaque observer handles, effectful reads, and disposal. It has no ordinary `Unnecessary` event. (`docs/prds/0002-eta-signal-frp.md:297-347`, `lib/signal/eta_signal.mli:167-173,320-373`) | **confirm** for the baseline. Ticket 13 owns any added lifecycle event |
| Observer order | Consumers need a documented total order when observer effects interact. | The PRD promises deterministic graph order. The current comparator forms `A < C < B < A`, and two cases deliver dependent observer `A` before dependency `B`. (`docs/prds/0002-eta-signal-frp.md:319-343`, `docs/wayfinder/eta-signal-direction/issues/04-observer-order-counterexample.md:22-75`) | **amend**. Ticket 11 |
| Signal-to-stream bridge | Consumers need a one-way, bounded, nonblocking bridge with explicit lifecycle ownership and visible loss. | `Stream.observe` returns an observer and stream, drops newest updates when full, reports drops, and closes after observer disposal. (`docs/design/eta_signal-kernel-contract.md:95-108`, `lib/signal/eta_signal.mli:702-765`) | **confirm** the consumer boundary. **provisional** exact surface. Ticket 13 |
| Stream domain rule | Consumers need one exact domain and ownership rule. They must not guess from prose. | The PRD says the returned stream is a same-domain resource. The current interface says the queue can be consumed from another runtime or domain, while graph operations stay owner-domain-only. (`docs/prds/0002-eta-signal-frp.md:467-477,610-611`, `lib/signal/eta_signal.mli:98-106,733-740`) | **amend**. Ticket 13 |
| Time nodes and driver wake | Signal consumers need monotonic time and explicit stabilization. Demand ownership is the current policy. | Signal keeps `now`, `deadline`, `after`, and `interval`. Eta Crux V1 exposes no Signal time description. Crux timers and sources send endpoint actions, and ingress wakes the driver. | **confirm** the Signal time boundary. **reject** a Signal-to-Crux timer wake hook for V1. |
| Small public algebra | Consumers need a regular core, not a parity copy of Incremental. | The current core has constants, variables, maps through `map9`, `both`, `all`, `bind`, observers, time, and streams. The PRD excludes broad helper parity. (`docs/prds/0002-eta-signal-frp.md:194-205,545-567`, `lib/signal/eta_signal.mli:375-541`) | **confirm** the no-parity principle. **provisional** exact surface. Ticket 13 |
| Large fan-in folds | Some consumers need associative or update-aware reduction for large collections. The need is workload-dependent. | The current interface has `all` but no public fold family. F8 identifies this as a capability gap, not a parity order. (`lib/signal/eta_signal.mli:515-522`, `.scratch/research/eta-signal-direction/claim-census.md:251-261`) | **provisional**. Ticket 13 |
| Keyed per-key state | Crux and other external consumers need stable child identity, keyed updates, removal, and fresh re-entry. | `eta_signal_map` is an optional sibling. Its public surface is `Map.Make` plus `Keyed(Order).mapi`, with directed `data_cutoff`, persistent output patches, and keyed diagnostics. (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:7-27`, `lib/signal_map/eta_signal_map.mli:1-115,118-185`) | **confirm** the keyed laws. **provisional** package and operator choices. Tickets 12 and 13 |
| Signal package seam | Consumers need keyed capability without installing keyed code in every Signal program. They do not need graph mutation or scope invariants. | The accepted choice is a package-private `eta_signal_kernel`, exact same-version coupling, and a closed Signal Map factory. (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:18-27,41-49`, `lib/signal/kernel/dune:1-5`, `eta_signal_map.opam:11-17`) | **confirm** the consumer separation. **provisional** seam. Ticket 12 |
| Crux application boundary | Crux consumers need typed computation descriptions without raw Signal types or graph mutation. | One inert `'a Eta_crux.t` compiles into one private Signal graph per root. Applications receive no graph-branded value or capability. | **confirm** graph-neutral descriptions and private interpretation. |
| Crux keyed and lifetime contract | Crux consumers need stable keyed state, stale-incarnation rejection, and scope-owned cleanup. | `Assoc(Order).assoc` uses the direct persistent map type and maps privately to `Keyed(Order).mapi`. The committed root frame owns endpoint and lifecycle manifests. | **confirm** continuous presence, fresh re-entry, stale rejection, and structural work ownership. |
| Crux advancement boundary | Crux consumers need output from a complete commit before lifecycle or effect work starts. | Effectful `Root.advance` stages one model action, runs one Signal stabilization, reads one committed root frame, and returns one mandatory post-commit token. | **confirm** one-event atomic advancement and output-before-work order. |
| Diagnostics and proof | Consumers need read-only diagnostics and maintainers need deterministic laws and work gates. | Signal exposes `stats` and `to_dot`, Signal Map adds nested keyed counters and complexity claims. N2 shows that current DOT and node counts can miss an invalid retained edge. F3 is explicit but incomplete debt despite the PRD self-audit. (`lib/signal/eta_signal.mli:207-241,567-587`, `lib/signal_map/eta_signal_map.mli:161-185`, `docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md:66-73`, `docs/wayfinder/eta-signal-direction/issues/01-complete-repository-evidence.md:59-70`) | **amend**. Tickets 15 and 16 |

## Current Eta Crux V1 bundle

The tracked `docs/design/eta-crux-v1/` directory is current HEAD authority. Its
public API and semantic laws now use the final Crux Cutoff, Assoc, and effectful
advancement contracts.

The first-principles map remains provenance. It is not a second authority.

## Exact stale and provisional statements

- The PRD says `Draft` and records implementation gaps, but its final section
  says that no unresolved audit notes remain and all acceptance criteria have
  evidence. (`docs/prds/0002-eta-signal-frp.md:3-7,692-743,745-781`)
- The PRD and kernel target promise atomic pure publication. N1 and N2 prove
  that the current implementation does not yet enforce that promise at all
  phase and topology boundaries. (`docs/design/eta_signal-kernel-contract.md:20-39`,
  `docs/wayfinder/eta-signal-direction/issues/02-atomic-phase-entry.md:35-54`,
  `docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md:52-60`)
- The PRD promises a same-domain stream resource, but the current public
  interface documents cross-domain stream consumption. (`docs/prds/0002-eta-signal-frp.md:473-477`,
  `lib/signal/eta_signal.mli:733-740`)
- The PRD promises deterministic graph-order observer delivery, but the current
  comparator is cyclic. Ticket 11 must choose the public policy. (`docs/prds/0002-eta-signal-frp.md:330-343`,
  `docs/wayfinder/eta-signal-direction/issues/04-observer-order-counterexample.md:33-75`)
- `docs/requirements/eta-crux/engine-strategy.md` places Signal Map and Signal
  implementation obligations in the Crux bundle and leaves the Signal hook
  open. The completed Signal Map package decision moves those obligations to
  package-owned requirements. (`docs/requirements/eta-crux/engine-strategy.md:25-51`,
  `docs/wayfinder/eta-signal-keyed-map/issues/14-package-and-documentation-boundary.md:108-149`)
- The current Eta Crux V1 authority selects one private Signal graph per root.
  The production custom graph is a stale implementation path, not a second
  backend choice. (`docs/design/eta-crux-v1/README.md:21-32,48-71`,
  `docs/wayfinder/eta-signal-direction/issues/14-eta-crux-signal-contract.md#answer`)
- The first-principles keyed Crux issue now uses the direct persistent Eta map,
  `Assoc(Order)`, named data cutoffs, and `Keyed(Order).mapi`.
- `docs/requirements/eta-crux/core-loop.md` describes a graph value passed to
  root construction. The resolved graph-neutral Crux API keeps Signal private
  and creates the graph inside `Root.create`. (`docs/requirements/eta-crux/core-loop.md:20-30,85-93`,
  `docs/wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md:34-36,117-161`)
- The PRD package self-audit describes the Signal dependency as `eta` and
  `eta_stream`, but current package metadata also declares `eta_observability`.
  (`docs/prds/0002-eta-signal-frp.md:654-657`, `dune-project:38-48`,
  `eta_signal.opam:11-18`) The metadata is the package authority.

## Decisions for later tickets 09-16

Ticket 08 does not choose these questions. It assigns them to the owner that
already holds the related review claims.

| Ticket | Decision it must own |
|---|---|
| 09 | Phase entry, transaction identity, one invalidation frontier, preflight, total commit, rollback authority, and post-commit failure behavior. (`docs/wayfinder/eta-signal-direction/issues/09-transaction-and-invalidation-model.md:1-25`) |
| 10 | Dirty-frontier scheduling, demand references, timer demand, topology, static fan-in, dynamic edge removal, quiescent work, and deterministic economics. (`docs/wayfinder/eta-signal-direction/issues/10-scheduler-demand-and-topology.md:1-18`) |
| 11 | The observer total-order policy, dependency ordering, same-signal order, event collection, fail-fast delivery, retries, coalescing, and disposal. (`docs/wayfinder/eta-signal-direction/issues/11-observer-delivery-contract.md:1-14`) |
| 12 | Closed engine versus narrow first-party seam, graph-factory ownership, package dependencies, version coupling, the two-graphs problem, and typed testing boundaries. It must use external utility, not repository absence, as the seam test. (`docs/wayfinder/eta-signal-direction/issues/12-engine-and-package-seams.md:1-16`) |
| 13 | The final public algebra, folds, cutoff model, observer lifecycle additions, time and stream contracts, and accepted parts of F4, F8, F9, F11, and F12. (`docs/wayfinder/eta-signal-direction/issues/13-public-signal-algebra.md:1-17`) |
| 14 | The exact Crux contract: graph-neutral descriptions, plain-state versus graph backend, keyed `assoc`, dynamic lifetime, timer wake, stabilization, typed output, and test seams. (`docs/wayfinder/eta-signal-direction/issues/14-eta-crux-signal-contract.md:1-12`) |
| 15 | Private module ownership, wrapper deletion or retention, the tombstone index, and the diagnostic seam. (`docs/wayfinder/eta-signal-direction/issues/15-internal-module-ownership.md:1-18`) |
| 16 | Executable law rows, deterministic work gates, cleanup and empty-fiber checks, and final F3/F13 disposition. (`docs/wayfinder/eta-signal-direction/issues/16-laws-and-economics-gates.md:1-13`) |

## Review-census traceability

Ticket 08 directly resolves **no claim-census rows**. A parse of the Owner column
finds tickets 01-07 and 09-17, but no Ticket 08. The census summary states that
every row has one owner. (`.scratch/research/eta-signal-direction/claim-census.md:20-767,768-781`)

Ticket 08 supplies evidence for Ticket 12's `Q06-001`, which explicitly says
that its owner decides the ADR distinction after Ticket 08 evidence. It does
not transfer ownership or resolve that row. (`.scratch/research/eta-signal-direction/claim-census.md:743-746`)
This is consistent with Ticket 01's rule that an assigned row sends a decision
downstream and does not decide it. (`docs/wayfinder/eta-signal-direction/issues/01-complete-repository-evidence.md:72-75`)

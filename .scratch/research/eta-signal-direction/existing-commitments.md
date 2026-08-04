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
| `docs/requirements/eta-crux/engine-strategy.md:8-51`, `docs/requirements/eta-crux/core-loop.md:12-30,85-100`, `docs/requirements/eta-crux/composition.md:12-23,37-50`, `docs/requirements/eta-crux/fragments.md:12-31,35-68`, `docs/requirements/eta-crux/tick.md:12-28,42-64`, `docs/requirements/eta-crux/lifecycle.md:12-34,40-76`, `docs/requirements/eta-crux/testing.md:12-25,29-71`, `docs/requirements/eta-crux/concurrency.md:8-28,32-60`, and `docs/requirements/eta-crux/subscriptions.md:8-23,27-60` | Current Crux requirements. They contain Signal consumer obligations, but also contain open and conflicting backend choices. |
| `docs/wayfinder/eta-crux-first-principles/map.md:19-51,53-72` and resolved issues `docs/wayfinder/eta-crux-first-principles/issues/01-eta-crux-direction.md:21-37`, `docs/wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md:30-36,91-119,159-161`, `docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md:27-62,80-120,122-191`, `docs/wayfinder/eta-crux-first-principles/issues/05-action-effect-protocol.md:29-45,85-123`, `docs/wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md:89-114,116-160`, and `docs/wayfinder/eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md:28-49,75-127` | Resolved first-principles design evidence. It keeps raw Signal private and defines Crux identity, advancement, keyed lifetime, and work ownership. |
| `docs/wayfinder/eta-crux/map.md:5-9,41-72` | A separate current Crux map. It selects plain mutable state for V1 and defers the graph backend. This conflicts with parts of the first-principles map. |
| `lib/signal/eta_signal.mli:122-241,262-373,375-565,567-587,589-699,702-765` and `lib/signal_map/eta_signal_map.mli:1-187` | Current public API authority. These interfaces expose the actual Signal and Signal Map surfaces. |
| `dune-project:38-60`, `eta_signal.opam:1-18`, `eta_signal_map.opam:1-18`, `docs/packages.md:151-171`, and `lib/signal_map/README.md:1-22,38-50,98-120` | Current package and README evidence. The generated opam files confirm the optional package boundary and exact version coupling. |
| `lib/signal/kernel/dune:1-5`, `lib/signal_map/api/dune:1-5`, and `lib/signal_map/api/eta_signal_map_api.ml:40-76` | Current Signal implementation evidence. Signal Map uses a package-private kernel and calls `Signal.Extension.keyed_mapi`. This is not a Crux implementation. |
| `docs/wayfinder/eta-signal-direction/issues/01-complete-repository-evidence.md:45-75` and tickets 02-07 | Resolved evidence work. It confirms the current defects and says that later tickets still own the design. |
| `.scratch/research/eta-signal-direction/claim-census.md:732-781` | Traceability source. It gives every review claim one owner. Ticket 08 is not an owner. |
| `docs/design/eta-crux-v1/README.md@2ecc4f2f:3-19,48-66` and `docs/design/eta-crux-v1/public-api.md@2ecc4f2f:79-85` | Non-HEAD Crux design bundle. It is design prose on branch `docs/eta-crux-v1-design`, not production code and not current HEAD authority. |

## Implementation evidence limit

Current Signal and Signal Map production code is identifiable. The package-private
kernel and the Map API are present in the paths listed above. The current public
Signal Map implementation uses `Keyed(Order).mapi`, not a public
`Keyed_map` node. (`lib/signal_map/api/eta_signal_map_api.ml:40-76`,
`lib/signal_map/eta_signal_map.mli:118-185`)

No production Eta Crux implementation is identifiable. The exact search was:

```text
git log --all -- lib/crux lib/eta_crux test/crux test/eta_crux eta_crux.opam eta_crux.ml eta_crux.mli
```

That search returned no commit. All refs and worktrees contain Crux design files
and `.scratch/prototypes/eta-crux-*` sketches, not a production Crux package.
The current Crux maps also state that implementation is outside their deliverable.
(`docs/wayfinder/eta-crux/map.md:68-76`,
`docs/wayfinder/eta-crux-first-principles/map.md:49-51`)

Persisted-context searches for `SecondAgent`, `Eta Crux implementation`, and
`eta_crux implementation` found no separate implementation snapshot. Ticket 14
asks for an active SecondAgent implementation, but this repository provides none
that can be inspected. (`docs/wayfinder/eta-signal-direction/issues/14-eta-crux-signal-contract.md:1-17`)
This report does not infer Crux behavior from that absence.

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
| Time nodes and driver wake | Signal consumers need monotonic time and explicit stabilization. Demand ownership is the current policy. Crux also needs a wake when time is due. | Signal exposes `now`, `deadline`, `after`, `interval`, `step`, and `step_replay` with demand-owned timer work. The Crux requirement leaves the wake shape open. (`lib/signal/eta_signal.mli:589-699`, `docs/requirements/eta-crux/engine-strategy.md:21-23,44-51`) | **confirm** the time boundary. **provisional** exact Signal and Crux APIs. Tickets 13 and 14 |
| Small public algebra | Consumers need a regular core, not a parity copy of Incremental. | The current core has constants, variables, maps through `map9`, `both`, `all`, `bind`, observers, time, and streams. The PRD excludes broad helper parity. (`docs/prds/0002-eta-signal-frp.md:194-205,545-567`, `lib/signal/eta_signal.mli:375-541`) | **confirm** the no-parity principle. **provisional** exact surface. Ticket 13 |
| Large fan-in folds | Some consumers need associative or update-aware reduction for large collections. The need is workload-dependent. | The current interface has `all` but no public fold family. F8 identifies this as a capability gap, not a parity order. (`lib/signal/eta_signal.mli:515-522`, `.scratch/research/eta-signal-direction/claim-census.md:251-261`) | **provisional**. Ticket 13 |
| Keyed per-key state | Crux and other external consumers need stable child identity, keyed updates, removal, and fresh re-entry. | `eta_signal_map` is an optional sibling. Its public surface is `Map.Make` plus `Keyed(Order).mapi`, with directed `data_cutoff`, persistent output patches, and keyed diagnostics. (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:7-27`, `lib/signal_map/eta_signal_map.mli:1-115,118-185`) | **confirm** the keyed laws. **provisional** package and operator choices. Tickets 12 and 13 |
| Signal package seam | Consumers need keyed capability without installing keyed code in every Signal program. They do not need graph mutation or scope invariants. | The accepted choice is a package-private `eta_signal_kernel`, exact same-version coupling, and a closed Signal Map factory. (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:18-27,41-49`, `lib/signal/kernel/dune:1-5`, `eta_signal_map.opam:11-17`) | **confirm** the consumer separation. **provisional** seam. Ticket 12 |
| Crux application boundary | Crux consumers need typed computation descriptions without raw Signal types or graph mutation. | First-principles design keeps a graph-neutral `'a t` and creates a private graph per root. Current Crux requirements pass a graph value to application construction, while the current Crux map defers the graph backend. (`docs/wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md:30-36,117-161`, `docs/requirements/eta-crux/core-loop.md:20-30,85-93`, `docs/wayfinder/eta-crux/map.md:5-9,61-73`) | **provisional**. Ticket 14 |
| Crux keyed and lifetime contract | Crux consumers need stable keyed state, stale-incarnation rejection, and scope-owned cleanup. | First-principles decisions define continuous presence, fresh re-entry, atomic removal, and structural work ownership. The completed Signal Map integration maps `Assoc(Order).assoc` to `Keyed(Order).mapi`. Action and effect payloads remain Crux decisions. (`docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md:80-120`, `docs/wayfinder/eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md:32-49,75-114`, `docs/wayfinder/eta-signal-keyed-map/issues/12-eta-crux-integration-boundary.md:35-87`) | **replace** the old Crux map sketch. **provisional** for the full Crux contract. Ticket 14 |
| Crux advancement boundary | Crux consumers need output from a complete commit before lifecycle or effect work starts. | The first-principles transaction runs Signal pure stabilization, preflight, output calculation, and one atomic commit before post-commit work. The current plain-state map defers the graph backend. (`docs/wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md:89-114,116-160`, `docs/wayfinder/eta-crux/map.md:61-73`) | **provisional**. Ticket 14 |
| Diagnostics and proof | Consumers need read-only diagnostics and maintainers need deterministic laws and work gates. | Signal exposes `stats` and `to_dot`, Signal Map adds nested keyed counters and complexity claims. N2 shows that current DOT and node counts can miss an invalid retained edge. F3 is explicit but incomplete debt despite the PRD self-audit. (`lib/signal/eta_signal.mli:207-241,567-587`, `lib/signal_map/eta_signal_map.mli:161-185`, `docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md:66-73`, `docs/wayfinder/eta-signal-direction/issues/01-complete-repository-evidence.md:59-70`) | **amend**. Tickets 15 and 16 |

## Non-HEAD Eta Crux V1 bundle

The branch at `2ecc4f2f` calls its `docs/design/eta-crux-v1/` directory the
implementation authority for that branch. It also says that the old Crux
requirements and map were removed there. Those files remain on current HEAD.
Treat this bundle as a separate design input. Do not treat it as an
implementation snapshot. (`docs/design/eta-crux-v1/README.md@2ecc4f2f:3-19`)

It has two direct Signal contradictions and one ambiguous seam statement:

1. Its package graph makes `eta_crux` depend on both Signal packages, and it
   claims a public `Eta_signal_map.Keyed_map` node. (`docs/design/eta-crux-v1/README.md@2ecc4f2f:48-66`)
   Current `Eta_signal_map.mli` publishes `Keyed(Order).mapi`, not
   `Keyed_map`. (`lib/signal_map/eta_signal_map.mli:118-126`) The current
   implementation calls a package-private kernel extension instead.
   (`lib/signal_map/api/eta_signal_map_api.ml:40-76`)
2. Its public `Assoc` sketch takes `Stdlib.Map.S` and `data_equal`.
   (`docs/design/eta-crux-v1/public-api.md@2ecc4f2f:79-85`) The completed Signal Map integration takes
   `Eta_signal_map.Map.Ordered_type`, uses the direct map type, and names the
   directed predicate `data_cutoff`. (`docs/wayfinder/eta-signal-keyed-map/issues/12-eta-crux-integration-boundary.md:35-60,77-87`)
3. It says that Eta Crux uses no private cross-package hook.
   (`docs/design/eta-crux-v1/README.md@2ecc4f2f:64-66`) This statement is
   compatible with the ADR only when it describes direct Eta Crux access. The
   current public Signal Map implementation still uses the package-private
   Signal kernel. (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:18-27`,
   `lib/signal_map/api/eta_signal_map_api.ml:40-76`)

These statements are not current Signal commitments. Ticket 12 owns the seam
choice. Ticket 14 owns the Crux contract that consumes it.

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
- The Crux current map defers the graph backend, while the first-principles
  map and the non-HEAD V1 bundle assume a private Signal graph in V1.
  (`docs/wayfinder/eta-crux/map.md:5-9,61-73`,
  `docs/wayfinder/eta-crux-first-principles/map.md:53-62`,
  `docs/design/eta-crux-v1/README.md@2ecc4f2f:23-32,48-66`)
- The first-principles keyed Crux issue still contains the old `Stdlib.Map.S`,
  `data_equal`, `Keyed_map.create`, and linear `M.merge` design. The completed
  Signal Map integration replaces all four choices. (`docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md:31-62,122-191`,
  `docs/wayfinder/eta-signal-keyed-map/issues/12-eta-crux-integration-boundary.md:15-22,35-87`,
  `docs/wayfinder/eta-signal-keyed-map/issues/14-package-and-documentation-boundary.md:153-170`)
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

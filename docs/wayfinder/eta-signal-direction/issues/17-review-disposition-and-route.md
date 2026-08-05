# Review disposition and implementation route

Type: grilling
Status: resolved
Blocked by: 01, 09, 10, 11, 12, 13, 14, 15, 16

## Question

What is the final disposition of every review finding and each adjacent gap that
this effort discovers?

For F1-F14 and N1-N5, record accepted, amended, rejected, or deferred. Give the
evidence, desired contract, design owner, implementation dependency, migration
effect, and verification gate. Apply the same format to each accepted adjacent
gap.

Record the external consumer value of each interface decision. Do not use the
absence of an internal repository consumer as evidence for rejection, omission,
or deletion.

Reconcile the complete claim census from
[Complete repository evidence](01-complete-repository-evidence.md). Every census
row must have its final disposition or a context pointer to the ticket that owns
that disposition. No row can remain unowned or unresolved.

Order implementation by invariant dependency, severity, reachability,
likelihood, and design leverage. The answer must leave no design decision for
implementation.

## Answer

The result is a redesign of Eta Signal internals and a focused correction of its
public surface. Eta keeps explicit stabilization, typed failures, scoped demand,
stable keyed identity, and graph-neutral Crux descriptions.

No implementation slice keeps a compatibility path. Each replacement deletes
its old behavior path in the same slice.

### Final review dispositions

| Finding | Disposition | Final contract, owner, and gate |
|---|---|---|
| F1 | Accepted with amendment | `Eta_signal_work`, scheduler, demand, and topology replace graph-wide scans. `@signal-economics` gates affected work. |
| F2 | Accepted | Domain and runtime ownership fail through the final typed graph contracts. Generated two-graph and two-runtime laws gate isolation. |
| F3 | Accepted | The final interfaces get claim-level registry rows. Blanket Signal debt is deleted when `@signal-laws` passes. |
| F4 | Amended | Value updates remain `Initialized` and `Changed`. Exactly-once `on_finish` owns disposal and invalid-scope lifecycle. |
| F5 | Accepted as an ownership concern | Each private module owns one named invariant. Universal two-use and closure-record bans are rejected. |
| F6 | Replaced and removed | All six graph functors leave after topology, scheduler, demand, observer, and transaction owners adopt their valid behavior. |
| F7 | Accepted | Unsafe extension identities are deleted. Graph-branded role-specific probes replace object casts. |
| F8 | Accepted in bounded form | `reduce_balanced` provides ordered associative reduction with logarithmic changed-leaf work. |
| F9 | Rejected | Repeated `Var.set` calls are the batch. `both` and parity convenience additions leave the surface. |
| F10 | Removed by construction | `Eta_signal.Make` is the sole graph factory. Signal Map adapts `Signal.Package`. |
| F11 | Rejected | `bind` always retires the old branch scope. V1 has no rescope mode. |
| F12 | Split | Immutable named cutoffs are accepted. Mutable cutoff state and reevaluation are rejected. |
| F13 | Accepted | Owner-local counters and independent manifests gate deterministic work. Wall time remains benchmark output. |
| F14 | Amended | The complete stream bridge moves to `eta_signal_stream`. Arithmetic stays with each semantic owner. |
| N1 | Confirmed and corrected | Physical transaction identity and one atomic phase assignment preserve `Idle` on allocation defects. |
| N2 | Confirmed and corrected | One closed invalidation frontier partitions every dynamic operation before a sealed total commit. |
| N3 | Confirmed and corrected | One deterministic topological observer plan replaces the cyclic pairwise comparator. |
| N4 | Amended | Wide construction and live-owner removal were quadratic. Indexed edge slots make affected edge work linear. |
| N5 | Confirmed and corrected | Planning can roll back. Delivery cannot roll back a committed snapshot. One finalizer returns the graph to `Idle`. |

### Accepted adjacent gaps

| Gap | Consumer value | Final owner and gate |
|---|---|---|
| Named immutable cutoffs | Callers can state suppression semantics without raw argument-order ambiguity. | `Eta_signal.Cutoff`; cutoff generated laws |
| Balanced scalar reduction | Consumers can aggregate wide static inputs without linear changed-leaf recomputation. | scheduler and reduction node; logarithmic gate |
| Observer finish | Resource adapters can distinguish value delivery from terminal lifecycle. | observer and delivery owners; finish race laws |
| Stable-family package protocol | Collection packages can add stable keyed operators to an existing graph without engine authority. | sealed `Package_graph`; typed package tests |
| Optional stream package | Core Signal installs no Eio stream dependencies. Stream users retain bounded delivery and acknowledgement. | `eta_signal_stream`; stream model laws |
| Bounded tombstone ring | Diagnostics remain value-free and bounded without insertion scans. | `Eta_signal_tombstone_index`; constant insertion gate |
| Crux root-frame integration | Crux keeps graph-neutral descriptions while each root gets one atomic committed frame. | Eta Crux root compiler; root advancement laws |
| Exact finish and economics registries | Maintainers can trace every public law and detect asymptotic regression without timing noise. | `LAWS.md` and `@signal-gates` |

Internal repository use did not select any public decision. External leverage,
semantic coherence, safety, package cost, and invariant depth selected the final
surface.

### Final implementation route

1. Add final requirement rows, law names, typed probes, fault slots, and
   owner-local counters. Run old-engine economics fixtures to establish their
   discriminators.
2. Add `Eta_signal_node`, physical transactions, cleanup linearity, sealed commit
   plans, and atomic-pass authority. Land N1 and N5 regressions. Delete old
   stabilization paths.
3. Add static edge arrays, indexed dynamic vectors, incremental demand, the work
   ledger, and necessary-stale scheduling. Land F1 and N4 gates. Delete graph
   algorithms and graph port records.
4. Move bind and stable-family edits into the closed frontier. Adapt Signal Map
   through `Signal.Package`. Land all five N2 regressions. Delete the second
   factory and unsafe testing tokens.
5. Add balanced reduction and immutable cutoffs. Update all direct callers and
   delete `both`, raw equality arguments, and stale reduction paths.
6. Add topological observer planning, durable cursors, fail-fast delivery,
   acknowledgement, and exactly-once finish. Delete the comparator and old
   lifecycle protocol.
7. Replace timer demand scans with queued reconciliation. Add final one-shot and
   interval laws. Delete `step`, `step_replay`, and polling deadline arguments.
8. Add committed diagnostics and the 1,024-slot tombstone ring. Rewrite Signal
   Map diagnostics requirements and registry rows.
9. Publish `eta_signal_stream`, move all bridge code and tests, and remove
   `eta_stream` from the core package.
10. Migrate Eta Crux to one private Signal graph, one Signal Map adapter, private
    model variables, and one committed root-frame signal. Delete its custom
    graph and `Owner_transaction`.
11. Delete empty support libraries, forwarding wrappers, copied private tests,
    stale requirements, and stale registry rows.
12. Run `@signal-gates`, full OxCaml tests, the shipped-package gate, and the
    existing benchmark as non-gating evidence.

Every slice is buildable and carries its replacement tests. Churn and migration
cost do not justify a temporary path.

### Package result

```text
eta_signal -> eta, eta_observability
eta_signal_map -> eta_signal (= same release)
eta_signal_stream -> eta_signal (= same release), eta_stream, eta_observability
eta_crux -> eta, eta_observability, eta_signal, eta_signal_map
```

`Eta_signal.Make` remains the only graph factory. Signal Map, Signal Stream, and
Crux receive only their sealed public capabilities.

### Completion criteria

The implementation route is complete only when:

- every final normative span has one exact registry row and executable
- all N1 through N5 regressions pass
- every applicable effectful law ends with an available empty fiber census
- `@signal-economics` passes at 1,000, 10,000, and 100,000 nodes or edges
- `@signal-gates` passes in the OxCaml shipped gate
- no deleted API, private protocol, unsafe token, second factory, or fallback
  bridge remains
- Eta Crux uses only the final Signal and Signal Map contracts

### Resolution spans

Line numbers refer to this issue.

| Census row | Resolution |
|---|---|
| SCP-013 | lines 80–126 |
| EXE-001 | lines 80–126 |
| EXE-005 | lines 80–126 |
| EXE-006 | lines 80–126 |
| EXE-007 | lines 80–126 |
| EXE-008 | lines 80–126 |
| EXE-017 | lines 80–126 |
| F01-001 | lines 39–61 |
| F04-004 | lines 39–61 |
| F07-001 | lines 39–61 |
| F08-001 | lines 39–61 |
| F09-001 | lines 39–61 |
| F09-012 | lines 39–61 |
| F10-001 | lines 39–61 |
| F11-001 | lines 39–61 |
| F12-001 | lines 39–61 |
| F13-001 | lines 39–61 |
| F14-001 | lines 39–61 |
| N01-001 | lines 39–61 |
| N01-025 | lines 80–126 |
| N02-001 | lines 39–61 |
| N02-038 | lines 80–126 |
| N03-001 | lines 39–61 |
| N04-001 | lines 39–61 |
| N05-001 | lines 39–61 |
| PLN-01-003 | lines 80–126 |
| PLN-02-003 | lines 80–126 |
| PLN-03-003 | lines 80–126 |
| PLN-06-003 | lines 80–126 |
| PLN-08-003 | lines 80–126 |
| PLN-09-002 | lines 80–126 |
| REC-001 | lines 39–126 |
| REC-002 | lines 39–126 |
| REC-003 | lines 39–126 |
| REC-004 | lines 39–126 |
| REC-005 | lines 39–126 |
| REC-006 | lines 39–126 |
| REC-007 | lines 39–126 |
| REC-013 | lines 39–126 |

### Implementation consequences

1. Implement the twelve slices in order.
2. Delete each old path with its replacement.
3. Preserve no compatibility layer.
4. Treat `@signal-gates` as the final executable acceptance gate.

# Independent review claim census

## Schema

The source is `independent-review.md`. A line span is inclusive and uses that file's line numbers.

Each row records one substantive claim. Repeated line spans mean that one source sentence contains independent claims.

The **class** column describes the claim. The **owner** column names exactly one Wayfinder ticket.

The **evidence status** column records the review's evidence basis. It does not accept the claim as repository fact.

The **ticket-01 disposition** column resolves traceability for ticket 01. An assignment sends a decision to the named owner.

The gist remains faithful to the review when its disposition rejects the
review's use-count premise. Repository use cannot establish external consumer
value for a library interface.

## 0. Scope, evidence standard, and limitations

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| SCP-001 | 5 | The requested review must assess F1-F14, parity claims, missed defects, and correction order. | scope | Ticket 01 | Review task statement | Retain as the census boundary. |
| SCP-002 | 9 | The review is a static trace of packed Eta and relevant Incremental sources. | limitation | Ticket 01 | Stated method | Retain and compare with complete repository evidence. |
| SCP-003 | 13 | The pack omits Signal tests, Signal Map tests, law tests, the registry, and reference tests. | limitation | Ticket 01 | Pack inventory statement | Retain and inspect the omitted repository files. |
| SCP-004 | 13 | Repository-wide use, registry, and named-test claims are only conditional in this review. | limitation | Ticket 01 | Consequence of omitted evidence | Retain as a limit on F3 and F6. |
| SCP-005 | 14 | The packed code revision is `4197be98`, but the audit and probes use `5694938a`. | fact | Ticket 01 | Conflicting revision metadata | Retain and record evidence against the authoritative revision. |
| SCP-006 | 14 | Raw probe timings only corroborate claims and do not measure the packed revision. | limitation | Ticket 05 | Revision mismatch | Amend with deterministic work counts on the selected revision. |
| SCP-007 | 16 | The reviewer did not compile or run the code. | limitation | Ticket 01 | Stated method | Retain and use repository tests plus focused prototypes. |
| SCP-008 | 16 | New correctness findings are static counterexample traces. | limitation | Ticket 01 | Static reasoning only | Retain until tickets 02-04 supply executable evidence. |
| SCP-009 | 16 | Each new defect needs an executable regression before its fix merges. | requirement | Ticket 16 | Proposed verification rule | Assign to owner for a gate decision. |
| SCP-010 | 5 | The requested task includes independent assessment of F1-F14. | scope | Ticket 01 | Review task statement | Retain as the finding boundary. |
| SCP-011 | 5 | The requested task includes challenges to semantic-parity claims. | scope | Ticket 01 | Review task statement | Retain as the S1-S17 boundary. |
| SCP-012 | 5 | The requested task includes a search for missed correctness defects. | scope | Ticket 01 | Review task statement | Retain as the N1-N5 boundary. |
| SCP-013 | 5 | The requested task includes a ranked correction plan. | scope | Ticket 17 | Review task statement | Assign to owner for final route. |
| SCP-014 | 9 | The review is not a restatement of the embedded audit. | method claim | Ticket 01 | Stated method | Retain and assess each claim independently. |
| SCP-015 | 9 | The review follows affected Eta paths and material Incremental sources. | method claim | Ticket 01 | Stated method | Retain and extend with complete repository evidence. |
| SCP-016 | 4 | The review targets `eta-signal-audit-gptpro-complete-20260804-100948.md`. | provenance | Ticket 01 | Review metadata | Retain as the packed-review identity. |

## 1. Executive verdict

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| EXE-001 | 20 | The audit has the correct broad architecture direction but overstates three conclusions. | verdict | Ticket 17 | Review synthesis | Assign to owner for final disposition. |
| EXE-002 | 22 | The keyed engine is embedded in the kernel. | fact | Ticket 12 | Static source trace | Retain for package-seam evidence. |
| EXE-003 | 22 | The production keyed package boundary is not `Obj`-typed. | fact | Ticket 12 | Static source trace | Retain and amend F2. |
| EXE-004 | 23 | Streams distinguish disposal from invalid-scope termination. | fact | Ticket 13 | Static source trace | Retain and amend F4. |
| EXE-005 | 24 | Two packed-code traces refute the audit's conclusion that there is no P0 defect. | verdict | Ticket 17 | Static counterexamples | Assign to owner after tickets 02 and 03. |
| EXE-006 | 28-32 | The review confirms F7, F8, F10, F12, and F13. | verdict | Ticket 17 | Review finding count | Assign to owner for final disposition. |
| EXE-007 | 28-32 | The review amends F1-F6, F11, and F14. | verdict | Ticket 17 | Review finding count | Assign to owner for final disposition. |
| EXE-008 | 28-32 | The review refutes F9 as framed. | verdict | Ticket 17 | Review finding count | Assign to owner for final disposition. |
| EXE-009 | 38 | N1 says transaction-ID overflow mutates phase state before allocation fails and wedges the graph. | counterexample | Ticket 02 | Static trace, rated P0 | Retain for executable reproduction. |
| EXE-010 | 39 | N2 says keyed removal can commit a nested bind switch after invalidating its owner. | counterexample | Ticket 03 | Static trace, rated P0 | Retain for executable reproduction. |
| EXE-011 | 40 | N3 says the observer comparator is not a total order on dynamic graphs. | counterexample | Ticket 04 | Static trace, rated P1 | Retain for executable reproduction. |
| EXE-012 | 41 | N4 says wide edge attachment and removal are quadratic. | complexity claim | Ticket 05 | Static algorithm analysis, rated P1 | Retain for deterministic measurement. |
| EXE-013 | 42 | N5 says one exception region spans pre-commit and post-commit work. | architecture claim | Ticket 09 | Static control-flow analysis, rated P2 | Assign to owner for model decision. |
| EXE-014 | 42 | N5 says the non-failing commit tail is implicit and not type-enforced. | invariant gap | Ticket 09 | Static type and control-flow analysis | Assign to owner for model decision. |
| EXE-015 | 44 | Static review found no other confirmed P0 in six named runtime protocols. | negative finding | Ticket 01 | Packed-code static review only | Retain as bounded negative evidence. |
| EXE-016 | 44 | The negative P0 finding is limited to packed code and static review. | limitation | Ticket 01 | Explicit qualification | Retain and do not generalize it. |
| EXE-017 | 20 | The audit gets the large architectural facts broadly right. | verdict | Ticket 17 | Review synthesis | Assign to owner for final disposition. |

## 2. Findings F1-F14

### F1

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F01-001 | 52 | F1's central claim is confirmed with amendments and remains P1. | verdict | Ticket 17 | Static review verdict | Assign to owner for final disposition. |
| F01-002 | 56 | Generation stamps avoid duplicate computation but not repeated traversal. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-003 | 58 | Current-generation caching reuses a node only after traversal reaches it. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-004 | 59 | Each reachability request allocates a new seen table and walks observer roots. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-005 | 60 | `necessary_ids` scans the weak registry before full root reachability. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-006 | 61 | `timer_demand` scans live nodes and performs a separate root-reachability pass. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-007 | 62 | `post_commit_necessary_timers` repeats registry pruning and root traversal. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-008 | 63 | Bind planning repeatedly collects all reachable binds until a fixed point. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-009 | 64 | Each observer-sort comparison can run a dependency search. | fact | Ticket 05 | Static source trace | Retain for work-count evidence. |
| F01-010 | 66 | Stabilization combines multiple full scans. | complexity claim | Ticket 05 | Static source synthesis | Retain for deterministic measurement. |
| F01-011 | 66 | Multiple observers and bind churn can add superlinear comparison and fixed-point work. | complexity claim | Ticket 05 | Static source synthesis | Retain for deterministic measurement. |
| F01-012 | 68 | The packed probe supports the qualitative work-scaling claim. | evidence claim | Ticket 05 | Non-deterministic probe on another revision | Amend with selected-revision operation counts. |
| F01-013 | 68 | The largest probe reports similar 259-276 ms costs for idle, no-op, and changing stabilization. | measurement | Ticket 05 | Single-run wall time on another revision | Retain only as supporting evidence. |
| F01-014 | 68 | One half-graph change reports 50,501 recomputations in a nominal 100k-node graph. | measurement | Ticket 05 | Probe output on another revision | Retain only as supporting evidence. |
| F01-015 | 70 | The probe starts a new Eio runtime for each set or stabilize call. | limitation | Ticket 05 | Probe source trace | Retain as a timing confounder. |
| F01-016 | 71 | The probe's printed node count omits watch nodes and two roots. | limitation | Ticket 05 | Probe source trace | Retain and correct future graph counts. |
| F01-017 | 72 | Probe timings are single-run wall times from a different revision. | limitation | Ticket 05 | Probe metadata | Retain and do not use as a gate. |
| F01-018 | 74 | The probe weaknesses prevent precise asymptotic fitting. | limitation | Ticket 05 | Evidence assessment | Retain. |
| F01-019 | 74 | The probe weaknesses do not explain graph-size growth in idle cost. | evidence claim | Ticket 05 | Static and probe synthesis | Retain for deterministic measurement. |
| F01-020 | 74 | The code trace independently establishes graph-size-dependent idle work. | evidence claim | Ticket 05 | Static source analysis | Retain for deterministic measurement. |
| F01-021 | 78 | Every stabilization performs graph-wide registry or reachability work. | amended finding | Ticket 10 | Static source synthesis | Assign to owner for scheduler design. |
| F01-022 | 78 | User-function recomputation can still be change-proportional. | amended finding | Ticket 10 | Static source synthesis | Assign to owner as a preserved property. |
| F01-023 | 78 | Bind planning and observer ordering can add repeated graph traversals. | amended finding | Ticket 10 | Static source synthesis | Assign to owner for scheduler design. |
| F01-024 | 82 | A fully quiescent stabilization must perform O(1) scheduler work. | complexity invariant | Ticket 10 | Proposed contract | Assign to owner for design decision. |
| F01-025 | 82 | A fully quiescent stabilization must not scan the registry or observer-root graph. | complexity invariant | Ticket 10 | Proposed contract | Assign to owner for design decision. |
| F01-026 | 84 | A clean-to-dirty transition must enqueue the node or affected frontier once until processing. | requirement | Ticket 10 | Proposed scheduler contract | Assign to owner for design decision. |
| F01-027 | 84 | Recomputation must settle each dependency before its consumer. | invariant | Ticket 10 | Proposed scheduler contract | Assign to owner for design decision. |
| F01-028 | 86 | Demand must update from incremental 0-to-1 and 1-to-0 reference transitions. | requirement | Ticket 10 | Proposed demand contract | Assign to owner for design decision. |
| F01-029 | 86 | Demand must not be reconstructed from all roots. | requirement | Ticket 10 | Proposed demand contract | Assign to owner for design decision. |
| F01-030 | 88 | The audit's source-cutoff-only condition for O(1) work is too broad. | correction | Ticket 10 | Static counterexamples | Amend the quiescence preconditions. |
| F01-031 | 88 | Timers, lifecycle changes, and failed pending delivery can create work without source changes. | fact | Ticket 10 | Runtime scenario analysis | Retain in the quiescence model. |
| F01-032 | 92 | Deterministic F13 work counters must land before the scheduler redesign. | sequencing | Ticket 16 | Proposed dependency order | Assign to owner for gate design. |
| F01-033 | 92 | The scheduler and necessity model need replacement after instrumentation. | recommendation | Ticket 10 | Proposed architecture route | Assign to owner for design decision. |
| F01-034 | 92 | The redesign affects graph state, dirty propagation, observers, dynamic edges, timers, diagnostics, and model tests. | blast radius | Ticket 10 | Static impact estimate | Retain for planning. |
| F01-035 | 92 | The F1 redesign does not require public signal type changes. | interface claim | Ticket 13 | Preliminary design assessment | Assign to owner to preserve if feasible. |
| F01-036 | 82 | Quiescence excludes dirty source, timer, and custom nodes. | scope condition | Ticket 10 | Proposed contract boundary | Assign to owner for design decision. |
| F01-037 | 82 | Quiescence excludes topology and demand transitions. | scope condition | Ticket 10 | Proposed contract boundary | Assign to owner for design decision. |
| F01-038 | 82 | Quiescence excludes observer registration and disposal transitions. | scope condition | Ticket 10 | Proposed contract boundary | Assign to owner for design decision. |
| F01-039 | 82 | Quiescence excludes pending callback delivery. | scope condition | Ticket 10 | Proposed contract boundary | Assign to owner for design decision. |
| F01-040 | 82 | Quiescence excludes pending cleanup. | scope condition | Ticket 10 | Proposed contract boundary | Assign to owner for design decision. |

### F2

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F02-001 | 98 | Engine embedding is confirmed. | verdict | Ticket 12 | Static review verdict | Retain for seam design. |
| F02-002 | 98 | The `Obj` causal claim is rejected. | verdict | Ticket 12 | Static review verdict | Retain and amend F2. |
| F02-003 | 98 | A mandatory public Expert correction is rejected and becomes an architecture decision. | verdict | Ticket 12 | Design assessment | Assign to owner for seam decision. |
| F02-004 | 102 | `incr_map` is a separate library built over `Incremental.Expert`. | reference fact | Ticket 06 | Reference source trace | Retain as reference evidence. |
| F02-005 | 102 | `incr_map` uses stale marking, dynamic edges, and invalidation for keyed updates. | reference fact | Ticket 06 | Reference source trace | Retain as reference evidence. |
| F02-006 | 104 | Eta's keyed engine lives inside `eta_signal_kernel`. | fact | Ticket 12 | Static source trace | Retain for seam design. |
| F02-007 | 104 | `eta_signal_map.Make` directly instantiates that kernel. | fact | Ticket 12 | Static source trace | Retain for seam design. |
| F02-008 | 104 | External libraries cannot add custom recompute node kinds through the current engine. | interface limitation | Ticket 12 | Static package and type trace | Assign to owner for seam decision. |
| F02-009 | 108 | Signal Map builds typed keyed operation records. | fact | Ticket 12 | Static source trace | Retain and reject the production-`Obj` framing. |
| F02-010 | 109 | Signal Map passes keyed operation records without `Obj`. | fact | Ticket 12 | Static source trace | Retain and reject the production-`Obj` framing. |
| F02-011 | 110 | Only `Keyed.Testing` re-exports the `Obj.t` token surface. | fact | Ticket 12 | Static source trace | Retain for testing-seam design. |
| F02-012 | 110 | Kernel test and introspection helpers implement the untyped token surface. | fact | Ticket 12 | Static source trace | Retain for testing-seam design. |
| F02-013 | 112 | The production keyed library boundary does not require `Obj`. | correction | Ticket 12 | Static source trace | Reject the contrary audit claim. |
| F02-014 | 112 | F7 is a private testing-token defect, not a production engine protocol defect. | correction | Ticket 12 | Static source trace | Retain and separate F7 from F2. |
| F02-015 | 116 | Eta has a closed graph engine. | amended finding | Ticket 12 | Static source synthesis | Assign to owner for architecture decision. |
| F02-016 | 116 | Signal Map works by instantiating a kernel that already contains keyed nodes. | amended finding | Ticket 12 | Static source synthesis | Retain for architecture decision. |
| F02-017 | 116 | The closed engine prevents independently linked custom-node libraries. | amended finding | Ticket 12 | Static source synthesis | Assign to owner for architecture decision. |
| F02-018 | 116 | The current production keyed path is type-safe. | amended finding | Ticket 12 | Static source synthesis | Retain as a required property. |
| F02-019 | 120 | Eta must not publish a broad Expert API now. | recommendation | Ticket 12 | Design recommendation | Assign to owner for architecture decision. |
| F02-020 | 120 | A public mutation API can expose phase, cycle, indexing, invalidation, demand, rollback, and ordering invariants. | risk claim | Ticket 12 | Static architecture analysis | Retain in the seam decision. |
| F02-021 | 120 | There is no evidence that more than one external node-kind implementation needs a mutation API. | evidence gap | Ticket 12 | Repository evidence cannot observe external demand | Reject repository absence as evidence against external usefulness. |
| F02-022 | 122 | Eta must choose between a closed engine and a narrow first-party SPI. | design fork | Ticket 12 | Proposed mutually exclusive choices | Assign to owner for architecture decision. |
| F02-023 | 124 | A closed-engine choice must amend the ADR to accept embedded keyed nodes. | requirement | Ticket 12 | Conditional design consequence | Assign to owner if it chooses the closed engine. |
| F02-024 | 124 | A closed-engine choice must reduce the private protocol and fix F7 separately. | requirement | Ticket 12 | Conditional design consequence | Assign to owner if it chooses the closed engine. |
| F02-025 | 125 | A second real node-kind package can justify a sealed typed first-party SPI. | decision rule | Ticket 12 | Conditional recommendation | Amend because external usefulness can justify a sealed SPI without an in-repository package. |
| F02-026 | 125 | A narrow SPI must leave phase, scheduling, rollback, demand, and invalidation inside the engine. | invariant | Ticket 12 | Proposed seam contract | Assign to owner for architecture decision. |
| F02-027 | 127 | Eta must not copy Jane Street's full Expert API for superficial similarity. | recommendation | Ticket 12 | Product-boundary principle | Retain as a design constraint. |
| F02-028 | 131 | The extension decision depends on stable scheduler and edge contracts. | sequencing | Ticket 12 | Proposed dependency order | Assign to owner for route planning. |
| F02-029 | 131 | A broad public API has a large permanent blast radius. | blast radius | Ticket 12 | Architecture assessment | Retain for decision evidence. |
| F02-030 | 131 | A private typed SPI affects the kernel, map API, package boundaries, and compile-fail tests. | blast radius | Ticket 12 | Static impact estimate | Retain for planning. |
| F02-031 | 106 | The production sibling-package path is typed. | fact | Ticket 12 | Static source trace | Retain and reject the production-`Obj` framing. |

### F3

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F03-001 | 137 | Signal's interface contains normative prose, but the review cannot decide the registry violation. | verdict | Ticket 16 | Conditional because the pack omits registry evidence | Retain and settle from the repository. |
| F03-002 | 141-147 | The interface states executable laws for observers, bind, stabilization, timers, and streams. | fact | Ticket 16 | Static interface census, not repository-complete | Retain and build exact registry mappings. |
| F03-003 | 149 | The pack omits `LAWS.md` and test files. | limitation | Ticket 01 | Pack inventory statement | Retain and inspect those files. |
| F03-004 | 149 | The review cannot reproduce the audit's law census. | limitation | Ticket 01 | Missing evidence | Retain until the repository census is complete. |
| F03-005 | 153 | Every normative interface span must have an exact registry entry. | policy requirement | Ticket 16 | Repository policy quoted by the review | Assign to owner for final law gate. |
| F03-006 | 153 | Each registry entry must name a test, property, or dated debt. | policy requirement | Ticket 16 | Repository policy quoted by the review | Assign to owner for final law gate. |
| F03-007 | 153 | Existing tests need registration instead of duplication. | recommendation | Ticket 16 | Proposed application of policy | Assign to owner for evidence mapping. |
| F03-008 | 155 | Maintainers must supply registry ranges and named tests before accepting F3. | evidence requirement | Ticket 01 | Missing pack evidence | Amend by reading the complete repository directly. |
| F03-009 | 155 | Until repository evidence exists, F3 is an unverified policy violation. | amended finding | Ticket 01 | Conditional review conclusion | Retain as the starting status. |
| F03-010 | 159 | F3 is documentation and registry work unless evidence reveals test gaps. | blast radius | Ticket 16 | Preliminary impact estimate | Assign to owner after evidence mapping. |
| F03-011 | 159 | New transaction laws and regression tests must register with the P0 fixes. | sequencing | Ticket 16 | Proposed dependency order | Assign to owner for gate design. |
| F03-012 | 143 | The interface states laws for observer initialization, cutoff, callback failure, and invalid-scope reads. | law-bearing fact | Ticket 16 | Static interface trace | Assign to owner for exact registry mapping. |
| F03-013 | 144 | The interface states laws for bind invalidation and rollback-visible purity. | law-bearing fact | Ticket 16 | Static interface trace | Assign to owner for exact registry mapping. |
| F03-014 | 145 | The interface states laws for transactions, delivery retry, and coalescing. | law-bearing fact | Ticket 16 | Static interface trace | Assign to owner for exact registry mapping. |
| F03-015 | 146 | The interface states laws for timer clocks and catch-up. | law-bearing fact | Ticket 16 | Static interface trace | Assign to owner for exact registry mapping. |
| F03-016 | 147 | The interface states laws for stream dropping and lifecycle. | law-bearing fact | Ticket 16 | Static interface trace | Assign to owner for exact registry mapping. |

### F4

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F04-001 | 165 | Eta's update type differs from Incremental's lifecycle type. | verdict | Ticket 13 | Static interface comparison | Retain as interface evidence. |
| F04-002 | 165 | The audit's stream-impact claim is wrong. | verdict | Ticket 13 | Static implementation trace | Reject the contrary claim. |
| F04-003 | 165 | A proposed `Unnecessary` event is wrong for active Eta observers. | verdict | Ticket 13 | Lifecycle analysis | Assign to owner for final API decision. |
| F04-004 | 165 | F4 is a P2 API choice rather than a correctness defect. | priority claim | Ticket 17 | Review assessment | Assign to owner for final disposition. |
| F04-005 | 169-177 | Eta exposes only `Initialized` and `Changed` observer updates. | interface fact | Ticket 13 | Static public-interface trace | Retain for API design. |
| F04-006 | 177 | Incremental node handlers expose necessary, changed, invalidated, and unnecessary events. | reference fact | Ticket 07 | Reference interface trace | Retain as reference evidence. |
| F04-007 | 179-184 | Eta stream consumers distinguish clean disposal from invalid scope. | fact | Ticket 13 | Static queue and stream trace | Retain and amend F4. |
| F04-008 | 186 | Incremental's `Unnecessary` event is not terminal. | reference fact | Ticket 07 | Reference semantic trace | Retain as reference evidence. |
| F04-009 | 186 | An Eta observer demands its root while registering or active. | fact | Ticket 13 | Static observer trace | Retain for lifecycle design. |
| F04-010 | 186 | An observed root cannot become unnecessary while its observer stays active. | semantic claim | Ticket 13 | Static demand reasoning | Assign to owner for contract decision. |
| F04-011 | 186 | Adding `Unnecessary` to observer updates will misstate Eta's lifecycle. | recommendation | Ticket 13 | Semantic comparison | Assign to owner for API decision. |
| F04-012 | 190 | Direct callbacks do not receive typed invalidation events. | amended finding | Ticket 13 | Static interface trace | Retain for API design. |
| F04-013 | 190 | Reads, internal finish hooks, and stream errors already expose invalidation. | amended finding | Ticket 13 | Static implementation trace | Retain for API design. |
| F04-014 | 190 | Active Eta observers have no meaningful `Unnecessary` event. | amended finding | Ticket 13 | Demand and lifecycle reasoning | Assign to owner for contract decision. |
| F04-015 | 194 | Eta only needs a public lifecycle surface if direct-callback consumers need it. | decision rule | Ticket 13 | Product-need condition | Assign to owner for API decision. |
| F04-016 | 194-207 | A separate finish callback is preferable to lifecycle values in ordinary updates. | recommendation | Ticket 13 | Proposed API shape | Assign to owner for API decision. |
| F04-017 | 209 | Disposal must not appear as an ordinary post-disposal update. | requirement | Ticket 13 | Proposed lifecycle contract | Assign to owner for API decision. |
| F04-018 | 209 | Eta must not add `Unnecessary` without node handlers whose demand can drop and return. | requirement | Ticket 13 | Conditional lifecycle contract | Assign to owner for API decision. |
| F04-019 | 213 | F4 is scheduler-independent but changes public APIs and stream adapters. | sequencing | Ticket 13 | Static impact estimate | Retain for planning. |
| F04-020 | 213 | Existing callers must change directly without a compatibility shim. | migration rule | Ticket 13 | Repository policy application | Assign to owner if the API changes. |
| F04-021 | 184 | `Stream.observe` connects the terminal finish hook to observer creation. | fact | Ticket 13 | Static implementation trace | Retain for lifecycle design. |

### F5

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F05-001 | 219 | Support-layer complexity is real, but the audit's universal abstraction rule is rejected. | verdict | Ticket 15 | Static architecture review | Assign to owner for module design. |
| F05-002 | 223 | The graph interface says one adapter exists and callback records are implementation protocol. | fact | Ticket 15 | Static interface trace | Retain for the deletion test. |
| F05-003 | 223 | The support layer has many multi-parameter records and one-constructor forwarding wrappers. | architecture fact | Ticket 15 | Static source inspection | Retain for module census. |
| F05-004 | 225 | Cross-module phase ordering is materially hard to review. | maintainability claim | Ticket 15 | N2-supported architecture analysis | Assign to owner for module design. |
| F05-005 | 225 | N2 spans kernel invalidation, graph staging, bind lifecycle, and pass orchestration. | architecture fact | Ticket 15 | Static ownership trace | Retain for invariant ownership. |
| F05-006 | 227 | A two-instantiation rule for every abstraction is unsound. | correction | Ticket 15 | Design reasoning | Reject the universal rule. |
| F05-007 | 227 | A ban on closure records is unsound. | correction | Ticket 15 | Design reasoning | Reject the universal rule. |
| F05-008 | 227 | Single-use abstractions are useful when they make illegal phase transitions unrepresentable. | design principle | Ticket 15 | Type-design reasoning | Retain as a deletion-test exception. |
| F05-009 | 227 | Transaction and stabilization modules deserve retention after exception-safety fixes. | recommendation | Ticket 15 | Preliminary module assessment | Assign to owner for module design. |
| F05-010 | 231 | A support abstraction must own a named invariant that direct code cannot express as clearly. | review invariant | Ticket 15 | Proposed deletion test | Assign to owner for module design. |
| F05-011 | 233-238 | Semantically empty wrappers and single-caller port records need deletion after core fixes. | recommendation | Ticket 15 | Proposed cleanup rule | Assign to owner after architecture settles. |
| F05-012 | 237 | Phase-typed state machines and pure timer-policy logic need retention. | recommendation | Ticket 15 | Proposed ownership rule | Assign to owner for module design. |
| F05-013 | 238 | Subsystem modules need movement instead of a merge into one kernel file. | recommendation | Ticket 15 | Deep-module principle | Assign to owner for module design. |
| F05-014 | 242 | F5 cleanup comes after architectural changes. | sequencing | Ticket 15 | Proposed dependency order | Assign to owner for route planning. |
| F05-015 | 242 | Early cleanup risks duplicate work and loss of useful correctness boundaries. | risk claim | Ticket 15 | Architecture reasoning | Retain for sequencing. |
| F05-016 | 235 | Inline one-constructor wrappers that only rename one call. | cleanup requirement | Ticket 15 | Proposed deletion rule | Assign to owner after architecture settles. |
| F05-017 | 236 | Collapse single-caller port records whose fields are always assembled and consumed together. | cleanup requirement | Ticket 15 | Proposed deletion rule | Assign to owner after architecture settles. |

### F6

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F06-001 | 248 | Five graph-algorithm functors appear dead, but confirmation is conditional. | verdict | Ticket 01 | Whole-repository use is now known | Amend to no production instantiation without a deletion conclusion. |
| F06-002 | 252 | Five named functors occur only in definitions, interfaces, and audit text inside packed production files. | fact | Ticket 01 | Whole-repository use confirms test-only instantiations | Retain as implementation inventory, not consumer-value evidence. |
| F06-003 | 252 | The live graph duplicates those five algorithms directly. | duplication claim | Ticket 15 | Static source comparison | Retain for module design. |
| F06-004 | 252 | `Make_edges` is the only production instantiation in the pack. | fact | Ticket 01 | Whole-repository use confirms the same production result | Retain as implementation inventory, not consumer-value evidence. |
| F06-005 | 254 | Missing tests prevent a repository-wide use conclusion. | limitation | Ticket 01 | Complete tests show test-only instantiations | Amend with the whole-repository result. |
| F06-006 | 254 | Test-only use does not justify duplicate production abstractions. | design claim | Ticket 15 | Architecture judgment | Assign retention, canonical adoption, replacement, or removal without a use-count shortcut. |
| F06-007 | 254 | Test-only use changes the deletion mechanics. | planning claim | Ticket 15 | Whole-repository use is now known | Retain as migration inventory only. |
| F06-008 | 258 | Delete all five functors and interface entries if repository use search finds no production consumer. | conditional requirement | Ticket 15 | Proposed cleanup based on use absence | Reject production-use absence as a deletion rule. |
| F06-009 | 258 | Tests that use the functors need redirection to live behavior or one canonical pure module. | conditional requirement | Ticket 15 | Conditional cleanup | Assign only after the owner chooses retention, canonical adoption, replacement, or removal. |
| F06-010 | 262 | F6 cleanup follows N1 and N2 but precedes broad F5 cleanup. | sequencing | Ticket 15 | Proposed dependency order | Assign to owner for route planning. |
| F06-011 | 262 | F6 has low semantic risk and affects support modules plus direct unit tests. | blast radius | Ticket 15 | Preliminary impact estimate | Retain for planning. |

### F7

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F07-001 | 268 | F7 is confirmed as an independent P2 defect. | verdict | Ticket 17 | Static review verdict | Assign to owner for final disposition. |
| F07-002 | 272 | `keyed_entry_identity` casts caller keys with `Obj.magic`. | fact | Ticket 12 | Static source trace | Retain for testing-seam design. |
| F07-003 | 272 | One `Obj.t` token represents five semantically different object kinds. | fact | Ticket 12 | Static source trace | Retain for testing-seam design. |
| F07-004 | 272 | `keyed_scope_valid` interprets any generic token as a scope. | fact | Ticket 12 | Static source trace | Retain for testing-seam design. |
| F07-005 | 272 | A wrong token causes representation confusion instead of a typed or loud error. | correctness claim | Ticket 12 | Static unsafe-cast analysis | Retain for testing-seam design. |
| F07-006 | 274 | Private test scope limits exposure but still permits undefined behavior. | impact claim | Ticket 12 | Static unsafe-cast analysis | Retain for seam risk. |
| F07-007 | 274 | The token surface violates Eta's fail-loudly rule. | standards claim | Ticket 12 | Repository-policy comparison | Retain for seam design. |
| F07-008 | 278-292 | Distinct opaque identity and scope token types can replace the universal token. | contract proposal | Ticket 12 | Proposed typed API | Assign to owner for seam design. |
| F07-009 | 294 | Source, data, and child identity checks need distinct opaque types or typed accessors. | requirement | Ticket 12 | Proposed type-safety rule | Assign to owner for seam design. |
| F07-010 | 294 | Eta must not use one universal testing token. | requirement | Ticket 12 | Proposed type-safety rule | Assign to owner for seam design. |
| F07-011 | 298 | F7 can land independently and only changes private testing signatures and fixtures. | sequencing | Ticket 12 | Preliminary impact estimate | Assign to owner for route planning. |
| F07-012 | 298 | F7 does not change production `Keyed.mapi`. | interface claim | Ticket 12 | Static API assessment | Retain as a migration constraint. |

### F8

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F08-001 | 304 | The fold-family gap is confirmed, but its correction needs amendment. | verdict | Ticket 17 | Static review verdict | Assign to owner for final disposition. |
| F08-002 | 308 | `All` computes all children and materializes a complete list after a considered change. | fact | Ticket 05 | Static source trace | Retain for economics evidence. |
| F08-003 | 308 | Eta has no public associative tree reduction or update-aware fold family. | interface gap | Ticket 13 | Static interface trace | Assign to owner for algebra decision. |
| F08-004 | 310 | Large fan-in aggregations have a real capability gap. | product claim | Ticket 13 | Interface and implementation analysis | Assign to owner for algebra decision. |
| F08-005 | 310 | An arbitrary fold cannot promise O(1) updates without a stronger algebra. | complexity constraint | Ticket 13 | Algorithmic reasoning | Retain as an API constraint. |
| F08-006 | 310 | O(1) fold updates need an inverse, replacement delta, or mutable accumulator law. | algebraic requirement | Ticket 13 | Algorithmic reasoning | Assign to owner for algebra decision. |
| F08-007 | 314-324 | A balanced associative reduction can promise O(log n) recomputation per child change. | contract proposal | Ticket 13 | Proposed API and law | Assign to owner for algebra decision. |
| F08-008 | 324 | Balanced reduction requires associative `combine` at Eta's observation boundary. | law proposal | Ticket 16 | Proposed executable law | Assign to owner for law design. |
| F08-009 | 326-336 | An update-aware delta fold can promise O(1) amortized accumulator work per changed child. | contract proposal | Ticket 13 | Proposed API and complexity contract | Assign to owner for algebra decision. |
| F08-010 | 340 | Fold implementation must follow F1 and N4 redesigns. | sequencing | Ticket 13 | Proposed dependency order | Assign to owner for route planning. |
| F08-011 | 340 | F8 affects public API, tests, complexity gates, and possibly a node kind. | blast radius | Ticket 13 | Preliminary impact estimate | Retain for planning. |

### F9

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F09-001 | 346 | F9 is not one coherent finding or correction batch. | verdict | Ticket 17 | Interface taxonomy analysis | Assign to owner for final disposition. |
| F09-002 | 348 | The F9 inventory contains many real absences. | fact | Ticket 13 | Interface comparison | Retain without treating absence as defect. |
| F09-003 | 350 | Some F9 items are trivial aliases or compositions. | classification | Ticket 07 | Reference interface inventory | Retain for algebra evidence. |
| F09-004 | 351 | Some F9 items are scheduler-sensitive convenience nodes. | classification | Ticket 13 | Semantic classification | Assign to owner for algebra decision. |
| F09-005 | 352 | Some F9 items are introspection-policy choices. | classification | Ticket 13 | Semantic classification | Assign to owner for algebra decision. |
| F09-006 | 353 | Some F9 items are major optional subsystems. | classification | Ticket 13 | Semantic classification | Assign to owner for algebra decision. |
| F09-007 | 354 | Dynamic cutoff work belongs under F12. | classification | Ticket 13 | Finding-boundary correction | Retain and merge into the F12 decision. |
| F09-008 | 356 | API-name parity and negative tests for every omission are not coherent product requirements. | correction | Ticket 13 | Product and test-design reasoning | Reject parity as a batch goal. |
| F09-009 | 356 | A smaller correct API is better than an approximate clone. | design principle | Ticket 13 | Product-boundary judgment | Retain as an algebra constraint. |
| F09-010 | 358 | `Var.value` already returns the latest set value before stabilization. | interface fact | Ticket 13 | Static public-interface trace | Retain and reject this claimed gap. |
| F09-011 | 358 | `Var.value` covers latest-source reads outside pure recomputation, but not Incremental's during-stabilization read. | parity assessment | Ticket 07 | Interface semantic comparison | Amend to external reads; reject full stabilization parity. |
| F09-012 | 362 | F9 must not remain a ranked defect. | recommendation | Ticket 17 | Review synthesis | Assign to owner for final disposition. |
| F09-013 | 362 | Separate RFCs need concrete workloads. | recommendation | Ticket 13 | Product-need rule | Assign to owner for algebra process. |
| F09-014 | 362 | Cheap aliases can enter when they improve readability without new semantics. | decision rule | Ticket 13 | Conditional recommendation | Assign to owner for algebra decision. |
| F09-015 | 362 | Major subsystems need separate contracts and performance models. | requirement | Ticket 13 | Product-scope rule | Assign to owner for algebra decision. |
| F09-016 | 362 | Dynamic cutoff work remains part of F12. | routing | Ticket 13 | Finding-boundary correction | Retain. |

### F10

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F10-001 | 368 | The two-graphs usability defect is confirmed at P2. | verdict | Ticket 17 | Static review verdict | Assign to owner for final disposition. |
| F10-002 | 372 | `Eta_signal_map.Make` creates and includes a fresh kernel instance. | fact | Ticket 12 | Static functor trace | Retain for package-seam design. |
| F10-003 | 372 | A separately applied `Eta_signal.Make` has a different generative signal type. | fact | Ticket 12 | OCaml generativity analysis | Retain for package-seam design. |
| F10-004 | 374 | Signal Map documentation does not warn consumers to use its functor as the application graph. | documentation gap | Ticket 12 | Static public-interface inspection | Retain for seam design. |
| F10-005 | 374 | The type error is safe, but discovery is poor. | impact claim | Ticket 12 | Interface usability assessment | Retain for seam design. |
| F10-006 | 378 | Documentation must say that Signal Map creates an independent graph and subsumes core Signal. | documentation requirement | Ticket 12 | Proposed public contract | Assign to owner for seam decision. |
| F10-007 | 378 | Keyed applications must use the map functor as their sole graph functor. | usage requirement | Ticket 12 | Proposed public contract | Assign to owner for seam decision. |
| F10-008 | 380 | Eta must not provide a shim or graph conversion. | migration rule | Ticket 12 | Repository policy application | Retain as a seam constraint. |
| F10-009 | 384 | The documentation correction is immediate and independent. | sequencing | Ticket 12 | Proposed route | Assign to owner for route planning. |
| F10-010 | 384 | A later F2 architecture choice can remove the two-graphs problem. | dependency claim | Ticket 12 | Conditional design assessment | Assign to owner for seam decision. |
| F10-011 | 384 | The current design needs the warning until its architecture changes. | requirement | Ticket 12 | Current-interface assessment | Assign to owner for seam decision. |

### F11

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F11-001 | 390 | Eta lacks bind rescoping, but the parity and priority argument is weak. | verdict | Ticket 17 | Static and reference review | Assign to owner for final disposition. |
| F11-002 | 394 | Eta always detaches and invalidates the old branch before attaching the new branch. | fact | Ticket 13 | Static bind trace | Retain for dynamic-composition design. |
| F11-003 | 394 | Eta exposes no rescope mode. | interface absence | Ticket 13 | Static interface trace | Retain without treating absence as defect. |
| F11-004 | 396 | Incremental calls non-invalidating bind behavior a compatibility hack. | reference fact | Ticket 07 | Reference configuration trace | Retain as reference evidence. |
| F11-005 | 396 | Incremental invalidates the old RHS by default. | reference fact | Ticket 07 | Reference configuration trace | Retain as reference evidence. |
| F11-006 | 396 | Eta lacks a nondefault optimization mode rather than baseline parity. | amended finding | Ticket 13 | Semantic comparison | Assign to owner for algebra decision. |
| F11-007 | 398 | The semantic table must route the rescope delta to F11, not F13. | correction | Ticket 01 | Internal review cross-reference | Amend the row mapping in this census. |
| F11-008 | 402 | Eta must reject near-term bind rescoping. | recommendation | Ticket 13 | Risk and priority assessment | Assign to owner for algebra decision. |
| F11-009 | 402 | Rescoping affects scope ownership, captures, keyed children, timers, observers, rollback, and N2. | risk claim | Ticket 13 | Static lifecycle analysis | Retain in the algebra decision. |
| F11-010 | 402 | Rescoping needs a benchmarked branch-flapping workload and a separate semantics RFC. | evidence requirement | Ticket 13 | Conditional product rule | Assign to owner for algebra decision. |
| F11-011 | 406 | Rescoping follows P0, scheduler, and extension-scope decisions. | sequencing | Ticket 13 | Proposed dependency order | Assign to owner for route planning. |
| F11-012 | 406 | Rescoping can have large public configuration and lifecycle-test impact. | blast radius | Ticket 13 | Preliminary impact estimate | Retain for planning. |

### F12

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F12-001 | 412 | Static, structurally weak cutoffs are confirmed and need a two-phase correction. | verdict | Ticket 17 | Static and reference review | Assign to owner for final disposition. |
| F12-002 | 416 | Eta stores one fixed equality function per node and exposes only `?equal`. | interface fact | Ticket 13 | Static source and interface trace | Retain for cutoff design. |
| F12-003 | 416 | Incremental has named cutoff variants and runtime replacement. | reference fact | Ticket 07 | Reference source trace | Retain as reference evidence. |
| F12-004 | 418 | A cutoff ADT improves semantics and diagnostics without runtime mutation. | design claim | Ticket 13 | Interface reasoning | Assign to owner for algebra decision. |
| F12-005 | 418 | Runtime cutoff mutation affects scheduling and needs separate semantics. | design risk | Ticket 13 | Scheduler reasoning | Assign to owner for algebra decision. |
| F12-006 | 422-435 | Phase 1 proposes a named `Cutoff` type with five constructor functions. | contract proposal | Ticket 13 | Proposed public API | Assign to owner for algebra decision. |
| F12-007 | 438 | Constructors need `?cutoff` instead of raw `?equal`. | requirement | Ticket 13 | Proposed public API | Assign to owner for algebra decision. |
| F12-008 | 438 | The old equality path needs deletion and all callers need direct updates. | migration rule | Ticket 13 | Repository no-shim policy | Assign to owner if it accepts the ADT. |
| F12-009 | 442-444 | Pure-phase `set_cutoff` must fail with a documented typed error before mutation. | unwanted-behavior requirement | Ticket 13 | Conditional contract proposal | Assign to owner if it accepts mutation. |
| F12-010 | 446 | The RFC must decide immediate reevaluation versus future-only comparison. | open design decision | Ticket 13 | Explicit semantic gap | Assign to owner for design decision. |
| F12-011 | 446 | `set_cutoff` is underspecified without a scheduling decision. | correction | Ticket 13 | Semantic analysis | Retain as a publication blocker. |
| F12-012 | 450 | Named cutoffs can land independently. | sequencing | Ticket 13 | Proposed dependency order | Assign to owner for route planning. |
| F12-013 | 450 | Runtime mutation must follow F1 scheduling work. | sequencing | Ticket 13 | Proposed dependency order | Assign to owner for route planning. |
| F12-014 | 450 | The cutoff change affects all public constructors and callers. | blast radius | Ticket 13 | Static API impact estimate | Retain for planning. |

### F13

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F13-001 | 456 | Missing core-engine scale gates are confirmed at P2 and precede F1. | verdict | Ticket 17 | Static benchmark review | Assign to owner for final disposition. |
| F13-002 | 460 | The current core benchmark covers a small diamond and one dynamic bind workload. | fact | Ticket 01 | Static benchmark inspection | Retain and compare with complete tests. |
| F13-003 | 460 | The benchmark repeats each workload 10k times and compares against mutable references. | fact | Ticket 01 | Static benchmark inspection | Retain as existing evidence. |
| F13-004 | 460 | The benchmark does not bound seven named graph-work dimensions. | evidence gap | Ticket 16 | Static benchmark inspection | Retain for gate design. |
| F13-005 | 462 | The raw scale probe is not deterministic enough for a gate. | limitation | Ticket 16 | Probe design assessment | Retain and reject wall time as a gate. |
| F13-006 | 462 | The raw scale probe targets a different revision. | limitation | Ticket 01 | Revision metadata | Retain and rerun selected evidence. |
| F13-007 | 466-475 | Private instrumentation needs counters for compute, edges, registries, observers, sorting, binds, demand, and timers. | requirement | Ticket 05 | Proposed measurement set | Assign to owner for prototype evidence. |
| F13-008 | 477-484 | Gates need six scenarios from quiescence through wide construction and invalidation. | requirement | Ticket 16 | Proposed gate set | Assign to owner for final gate design. |
| F13-009 | 477 | Gate scenarios need 1k, 10k, and 100k node scales. | requirement | Ticket 16 | Proposed size classes | Assign to owner for final gate design. |
| F13-010 | 486 | Deterministic operation counts must decide pass or fail. | gate requirement | Ticket 16 | Proposed verification policy | Assign to owner for final gate design. |
| F13-011 | 486 | Wall time can appear only as a non-gating artifact. | gate requirement | Ticket 16 | Proposed verification policy | Assign to owner for final gate design. |
| F13-012 | 490 | F13 instrumentation must precede F1 and N4 redesigns. | sequencing | Ticket 16 | Proposed dependency order | Assign to owner for route planning. |
| F13-013 | 490 | F13 mostly affects tests, benchmarks, and private instrumentation. | blast radius | Ticket 16 | Preliminary impact estimate | Retain for planning. |
| F13-014 | 490 | Public statistics must not grow unless consumers need the counters. | interface constraint | Ticket 13 | Deep-interface principle | Assign to owner for public API control. |
| F13-015 | 468 | Instrumentation must count nodes reached by compute. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-016 | 469 | Instrumentation must count dependency-edge checks. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-017 | 470 | Instrumentation must count weak-registry cells scanned. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-018 | 471 | Instrumentation must count observer roots scanned. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-019 | 472 | Instrumentation must count comparator dependency-search visits. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-020 | 473 | Instrumentation must count bind passes and candidates. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-021 | 474 | Instrumentation must count necessity traversal visits. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-022 | 475 | Instrumentation must count timer registry and reachability visits. | measurement requirement | Ticket 05 | Proposed counter | Assign to owner for prototype evidence. |
| F13-023 | 479 | Gates must cover quiescent stabilization. | gate scenario | Ticket 16 | Proposed deterministic gate | Assign to owner for gate design. |
| F13-024 | 480 | Gates must cover one narrow source change. | gate scenario | Ticket 16 | Proposed deterministic gate | Assign to owner for gate design. |
| F13-025 | 481 | Gates must cover one half-graph source change. | gate scenario | Ticket 16 | Proposed deterministic gate | Assign to owner for gate design. |
| F13-026 | 482 | Gates must cover a nested bind switch. | gate scenario | Ticket 16 | Proposed deterministic gate | Assign to owner for gate design. |
| F13-027 | 483 | Gates must cover a keyed child-only change. | gate scenario | Ticket 16 | Proposed deterministic gate | Assign to owner for gate design. |
| F13-028 | 484 | Gates must cover wide `all` construction and invalidation. | gate scenario | Ticket 16 | Proposed deterministic gate | Assign to owner for gate design. |

### F14

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| F14-001 | 496 | F14 needs amendment rather than wholesale helper centralization. | verdict | Ticket 17 | Static architecture review | Assign to owner for final disposition. |
| F14-002 | 498 | `Stream_bridge` is a coherent queue, lifecycle, drop, and metrics subsystem. | architecture claim | Ticket 15 | Static source inspection | Assign to owner for module design. |
| F14-003 | 498 | Extracting `Stream_bridge` improves ownership and reviewability. | recommendation | Ticket 15 | Architecture judgment | Assign to owner for module design. |
| F14-004 | 500 | Repeated arithmetic helper names do not prove identical semantics. | correction | Ticket 15 | Law-boundary analysis | Retain in the deletion test. |
| F14-005 | 500 | Deadlines, diagnostic counters, and identifiers have different laws and error boundaries. | architecture fact | Ticket 15 | Semantic comparison | Retain for module ownership. |
| F14-006 | 500 | One generic arithmetic helper can hide those differences. | risk claim | Ticket 15 | N1-supported design analysis | Retain for module ownership. |
| F14-007 | 500 | N1 shows why counter policy needs explicit ownership. | evidence claim | Ticket 15 | Static counterexample linkage | Retain for module ownership. |
| F14-008 | 504 | Move `Stream_bridge` into a private implementation and interface module. | requirement | Ticket 15 | Proposed refactor | Assign to owner after architecture settles. |
| F14-009 | 505 | Deduplicate helpers only when semantics, names, overflow policy, and boundaries match. | review invariant | Ticket 15 | Proposed deletion test | Assign to owner for module design. |
| F14-010 | 506 | Keep identifier checks, diagnostic saturation, and time caps separate and documented. | requirement | Ticket 15 | Proposed ownership rule | Assign to owner for module design. |
| F14-011 | 510 | F14 cleanup follows correctness and scheduler changes. | sequencing | Ticket 15 | Proposed dependency order | Assign to owner for route planning. |
| F14-012 | 510 | F14 changes private modules, Dune, and tests without public behavior changes. | blast radius | Ticket 15 | Preliminary impact estimate | Retain as a refactor constraint. |

## 3. New findings N1-N5

### N1

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| N01-001 | 516 | N1 classifies transaction-ID overflow phase corruption as P0. | verdict | Ticket 17 | Static review priority | Assign to owner after executable evidence. |
| N01-002 | 520-522 | N1 locates the defect in stabilization, transaction allocation, and pass orchestration. | location | Ticket 02 | Exact source pointers | Retain for prototype construction. |
| N01-003 | 526-530 | `begin_pure` sets phase and active status before constructing the transaction. | counterexample fact | Ticket 02 | Static write-order trace | Retain for executable reproduction. |
| N01-004 | 532 | The module-global transaction allocator raises at `max_int`. | counterexample fact | Ticket 02 | Static allocator trace | Retain for executable reproduction. |
| N01-005 | 532 | Transaction construction occurs before the pass's `try` block. | counterexample fact | Ticket 02 | Static evaluation-order trace | Retain for executable reproduction. |
| N01-006 | 532 | Allocation failure escapes without rollback after phase mutation. | counterexample | Ticket 02 | Static counterexample trace | Retain for executable reproduction. |
| N01-007 | 534-538 | The escaped failure leaves `Pure`, active status, and no transaction. | counterexample state | Ticket 02 | Static state trace | Retain for executable reproduction. |
| N01-008 | 540 | Each later stabilization returns `Reentrant_stabilization`. | counterexample effect | Ticket 02 | Static state-machine trace | Retain for executable reproduction. |
| N01-009 | 540 | The public API has no recovery operation. | impact claim | Ticket 02 | Static public-interface trace | Retain for executable reproduction. |
| N01-010 | 540 | The overflow path contradicts the public no-partial-publication overflow statement. | law conflict | Ticket 16 | Static interface and implementation comparison | Assign to owner for law disposition. |
| N01-011 | 542 | Production reachability is remote, but fault injection can exercise the defect. | reachability claim | Ticket 02 | Counter-bound and harness reasoning | Retain for prototype design. |
| N01-012 | 542 | The path causes permanent state-machine corruption. | impact claim | Ticket 02 | Static state trace | Retain for executable reproduction. |
| N01-013 | 546 | One graph becomes permanently unusable. | impact | Ticket 02 | Static state trace | Retain for executable reproduction. |
| N01-014 | 546 | The defect bypasses the typed error channel. | impact | Ticket 02 | Static control-flow trace | Retain for executable reproduction. |
| N01-015 | 546 | The defect breaks the internal phase invariant. | impact | Ticket 09 | Static state trace | Assign to owner for phase-model design. |
| N01-016 | 550 | `Pure` must imply a live transaction and active pure status at each observation boundary. | invariant | Ticket 09 | Proposed phase contract | Assign to owner for design decision. |
| N01-017 | 550 | No raising operation can occur between establishment of the pure-phase fields. | invariant | Ticket 09 | Proposed atomicity contract | Assign to owner for design decision. |
| N01-018 | 552 | Allocation failure must return typed `Counter_overflow "transaction id"`. | unwanted-behavior requirement | Ticket 09 | Proposed error contract | Assign to owner for design decision. |
| N01-019 | 552 | Allocation failure must leave the graph idle. | unwanted-behavior requirement | Ticket 09 | Proposed atomicity contract | Assign to owner for design decision. |
| N01-020 | 554-558 | A graph-owned fresh physical token can replace the global integer identity. | recommendation | Ticket 09 | Proposed representation | Assign to owner for design decision. |
| N01-021 | 560 | A retained integer needs allocation before phase mutation and graph-local ownership. | conditional requirement | Ticket 09 | Proposed safe alternative | Assign to owner for design decision. |
| N01-022 | 560 | Module-global identifiers can race across independent graphs on different domains. | concurrency risk | Ticket 09 | Static shared-state analysis | Assign to owner for domain-safe design. |
| N01-023 | 562 | `begin_pure` must return a valid token or preserve the prior idle state exactly. | exception-safety invariant | Ticket 09 | Proposed atomicity contract | Assign to owner for design decision. |
| N01-024 | 566-569 | Tests need forced overflow, typed error, successful retry, and a two-domain case if globals remain. | test requirement | Ticket 16 | Proposed regression set | Assign to owner for final gate design. |
| N01-025 | 573 | N1 is the first correction. | sequencing | Ticket 17 | Severity and dependency assessment | Assign to owner for final route. |
| N01-026 | 573 | N1 changes private identity and stabilization code plus the overflow harness. | blast radius | Ticket 09 | Preliminary impact estimate | Retain for planning. |
| N01-027 | 573 | Public success types do not need change. | interface claim | Ticket 13 | Preliminary type assessment | Assign to owner to preserve if feasible. |
| N01-028 | 573 | The graph-error taxonomy can represent or add a named counter-overflow path. | interface claim | Ticket 13 | Preliminary error-type assessment | Assign to owner for error algebra decision. |
| N01-029 | 566 | A regression must force the next transaction ID to overflow. | test requirement | Ticket 02 | Proposed fault injection | Retain for executable reproduction. |
| N01-030 | 567 | A regression must observe a typed counter-overflow result. | test requirement | Ticket 16 | Proposed regression assertion | Assign to owner for gate design. |
| N01-031 | 568 | A regression must observe successful stabilization after the failure. | test requirement | Ticket 16 | Proposed regression assertion | Assign to owner for gate design. |
| N01-032 | 569 | A retained global allocator needs a two-domain regression. | conditional test requirement | Ticket 16 | Proposed concurrency gate | Assign to owner if the design retains a global allocator. |

### N2

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| N02-001 | 577 | N2 classifies the keyed-removal and nested-bind defect as P0. | verdict | Ticket 17 | Static review priority | Assign to owner after executable evidence. |
| N02-002 | 581-585 | N2 spans bind planning, keyed planning, keyed commit, bind commit, and transaction order. | location | Ticket 03 | Exact source pointers | Retain for prototype construction. |
| N02-003 | 589-599 | A public keyed child builder can create a bind inside the child scope. | reachability claim | Ticket 03 | Public API construction | Retain for executable reproduction. |
| N02-004 | 601-605 | One cycle can switch the nested bind and remove its keyed owner before stabilization. | counterexample setup | Ticket 03 | Public operation sequence | Retain for executable reproduction. |
| N02-005 | 609 | Bind planning first sees the still-committed keyed child and stages a new branch. | counterexample step | Ticket 03 | Static execution trace | Retain for executable reproduction. |
| N02-006 | 610 | Keyed computation later records removal without computing the child. | counterexample step | Ticket 03 | Static execution trace | Retain for executable reproduction. |
| N02-007 | 611 | Keyed removal extends the invalidation view. | counterexample step | Ticket 03 | Static execution trace | Retain for executable reproduction. |
| N02-008 | 611 | That invalidation view does not discard or partition staged binds. | counterexample step | Ticket 03 | Static execution trace | Retain for executable reproduction. |
| N02-009 | 612 | Keyed commit detaches and invalidates the child before staged-cell commit. | counterexample step | Ticket 03 | Static commit-order trace | Retain for executable reproduction. |
| N02-010 | 612 | Child invalidation sees only the old bind snapshot. | counterexample step | Ticket 03 | Static snapshot trace | Retain for executable reproduction. |
| N02-011 | 612 | The provisional new branch scope remains outside that invalidation. | counterexample step | Ticket 03 | Static snapshot trace | Retain for executable reproduction. |
| N02-012 | 613 | Staging commits every staged bind without a validity predicate. | counterexample step | Ticket 03 | Static commit-loop trace | Retain for executable reproduction. |
| N02-013 | 614 | `commit_switch` attaches the staged inner to an already-invalid owner. | counterexample step | Ticket 03 | Static topology trace | Retain for executable reproduction. |
| N02-014 | 615 | Ordinary invalid-node snapshots are discarded, but the bind snapshot still commits. | counterexample step | Ticket 03 | Static transaction trace | Retain for executable reproduction. |
| N02-015 | 615 | The new inner retains an invalid owner in its dependents list. | counterexample state | Ticket 03 | Static topology trace | Retain for executable reproduction. |
| N02-016 | 617 | A top-scope new branch strongly retains the invalid bind. | retained-topology claim | Ticket 03 | Static ownership trace | Retain for executable reproduction. |
| N02-017 | 617 | Later dirty propagation skips the invalid owner and does not remove the edge. | retained-topology claim | Ticket 03 | Static propagation trace | Retain for executable reproduction. |
| N02-018 | 617 | The invalid edge and node persist in all-node diagnostics. | observable impact | Ticket 03 | Static diagnostics trace | Retain for executable reproduction. |
| N02-019 | 621 | Successful stabilization can attach an invalid dependent to a valid signal. | impact | Ticket 03 | Static counterexample trace | Retain for executable reproduction. |
| N02-020 | 622 | Dynamic-scope invalidation is not closed over staged bind state. | invariant failure | Ticket 09 | Static counterexample synthesis | Assign to owner for invalidation design. |
| N02-021 | 623 | The defect can retain invalid nodes and provisional scopes. | impact | Ticket 03 | Static topology trace | Retain for executable reproduction. |
| N02-022 | 624 | Later topology algorithms receive lists with invalid parents. | impact | Ticket 03 | Static topology trace | Retain for executable reproduction. |
| N02-023 | 625 | The public keyed transaction law does not describe the resulting hybrid state. | law gap | Ticket 16 | Interface and counterexample comparison | Assign to owner for law disposition. |
| N02-024 | 627 | N2 requires no impure callback, exception, or timer creation. | reachability claim | Ticket 03 | Pure public counterexample | Retain for executable reproduction. |
| N02-025 | 631 | Commit planning must compute one fixed invalidation frontier before topology mutation. | invariant | Ticket 09 | Proposed invalidation contract | Assign to owner for design decision. |
| N02-026 | 631 | The frontier must include staged bind switches, keyed removals, and future extension plans. | requirement | Ticket 09 | Proposed invalidation contract | Assign to owner for design decision. |
| N02-027 | 631 | No staged operation owned by the frontier can commit. | invariant | Ticket 09 | Proposed invalidation contract | Assign to owner for design decision. |
| N02-028 | 633 | An invalidated staged-bind owner must cause staged snapshot discard. | event requirement | Ticket 09 | Proposed transaction contract | Assign to owner for design decision. |
| N02-029 | 633 | Discard processing must invalidate the provisional new scope without `commit_switch`. | event requirement | Ticket 09 | Proposed cleanup contract | Assign to owner for design decision. |
| N02-030 | 635 | Each committed staged bind must have a valid owner outside the frozen frontier. | commit invariant | Ticket 09 | Proposed commit contract | Assign to owner for design decision. |
| N02-031 | 635 | The engine must decide staged-bind validity before keyed or bind topology mutation. | sequencing invariant | Ticket 09 | Proposed commit contract | Assign to owner for design decision. |
| N02-032 | 637-645 | An explicit commit-or-discard plan can encode staged-bind partitioning. | recommendation | Ticket 09 | Proposed internal plan shape | Assign to owner for design decision. |
| N02-033 | 645 | The commit phase can consume only commit decisions. | commit invariant | Ticket 09 | Proposed plan contract | Assign to owner for design decision. |
| N02-034 | 645 | The discard phase must invalidate provisional scopes and clear pending bind cells before commit. | rollback requirement | Ticket 09 | Proposed plan contract | Assign to owner for design decision. |
| N02-035 | 647 | Preflight can check and build an immutable plan but must not mutate topology. | phase invariant | Ticket 09 | Proposed phase contract | Assign to owner for design decision. |
| N02-036 | 647 | One non-failing commit phase must execute frozen topology actions. | commit invariant | Ticket 09 | Proposed phase contract | Assign to owner for design decision. |
| N02-037 | 651-655 | Regression coverage needs five keyed-bind, cleanup, retention, and callback-failure scenarios. | test requirement | Ticket 16 | Proposed regression set | Assign to owner for final gate design. |
| N02-038 | 659 | N2 follows N1 and precedes scheduler redesign. | sequencing | Ticket 17 | Severity and dependency assessment | Assign to owner for final route. |
| N02-039 | 659 | N2 affects commit planning, invalidation, discard, cleanup, diagnostics, and Signal Map models. | blast radius | Ticket 09 | Preliminary impact estimate | Retain for planning. |
| N02-040 | 659 | N2 does not require public type changes. | interface claim | Ticket 13 | Preliminary type assessment | Assign to owner to preserve if feasible. |
| N02-041 | 651 | A regression must combine keyed removal with a nested bind switch. | test requirement | Ticket 03 | Proposed counterexample | Retain for executable reproduction. |
| N02-042 | 652 | A top-scope new branch regression must show that no invalid dependent edge remains. | test requirement | Ticket 16 | Proposed topology assertion | Assign to owner for gate design. |
| N02-043 | 653 | A child-scope branch regression must show cleanup of its provisional scope. | test requirement | Ticket 16 | Proposed cleanup assertion | Assign to owner for gate design. |
| N02-044 | 654 | Repeated add, remove, and switch cycles need a bounded-node regression. | test requirement | Ticket 16 | Proposed retention gate | Assign to owner for gate design. |
| N02-045 | 655 | Callback failure after snapshot commit needs a topology-coherence regression. | test requirement | Ticket 16 | Proposed failure-path gate | Assign to owner for gate design. |

### N3

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| N03-001 | 663 | N3 classifies the non-total observer comparator as P1. | verdict | Ticket 17 | Static review priority | Assign to owner after executable evidence. |
| N03-002 | 667-669 | N3 locates comparator, collection, and observer-order code. | location | Ticket 04 | Exact source pointers | Retain for prototype construction. |
| N03-003 | 673-678 | The comparator uses dependency reachability first and signal ID for unrelated nodes. | fact | Ticket 04 | Static comparator trace | Retain for executable reproduction. |
| N03-004 | 680 | Reachability plus unrelated-ID fallback is not transitive. | counterexample claim | Ticket 04 | Static order analysis | Retain for executable reproduction. |
| N03-005 | 682-688 | A dynamic bind can create IDs `A < C < B` while `A` depends on `B`. | counterexample setup | Ticket 04 | Constructive static example | Retain for executable reproduction. |
| N03-006 | 690-695 | The three pairwise comparisons form `A < C < B < A`. | counterexample | Ticket 04 | Static comparator evaluation | Retain for executable reproduction. |
| N03-007 | 696 | `List.sort` requires a total order. | algorithm precondition | Ticket 04 | Standard library contract | Retain for executable reproduction. |
| N03-008 | 696 | Sort output can violate dependency-before-parent order. | impact | Ticket 04 | Consequence of invalid comparator | Retain for executable reproduction. |
| N03-009 | 696 | The output is not stable across implementations or input arrangements. | impact | Ticket 04 | Sorting-contract analysis | Retain for executable reproduction. |
| N03-010 | 698 | The S9 claim that Eta is stronger is unsupported. | parity correction | Ticket 11 | Static counterexample | Assign to owner for observer contract. |
| N03-011 | 702 | Callback order can be inconsistent on dynamic-bind graphs. | impact | Ticket 11 | Static counterexample | Assign to owner for observer contract. |
| N03-012 | 702 | Pairwise dependency searches also contribute to F1 cost. | complexity link | Ticket 05 | Static algorithm analysis | Retain for work-count evidence. |
| N03-013 | 706-709 | Eta must choose identity order or one explicit topological order. | design fork | Ticket 11 | Proposed mutually exclusive choices | Assign to owner for design decision. |
| N03-014 | 708 | Identity order needs documentation that callbacks have no dependency order. | conditional requirement | Ticket 11 | Proposed contract consequence | Assign to owner if it chooses identity order. |
| N03-015 | 709 | Dependency order needs one topological plan with observer ID tie-breaking. | conditional requirement | Ticket 11 | Proposed contract consequence | Assign to owner if it chooses topological order. |
| N03-016 | 709 | Dependency order must not use pairwise reachability comparisons. | requirement | Ticket 11 | Proposed algorithm constraint | Assign to owner for design decision. |
| N03-017 | 711 | Callback ordering must be a deterministic total order. | invariant | Ticket 11 | Proposed public contract | Assign to owner for design decision. |
| N03-018 | 711 | A topological promise requires every dependency before each transitive consumer. | conditional invariant | Ticket 11 | Proposed public contract | Assign to owner if it chooses topological order. |
| N03-019 | 715 | Tests need the exact dynamic graph across observer registration permutations. | test requirement | Ticket 04 | Proposed prototype matrix | Retain for executable reproduction. |
| N03-020 | 719 | The observer-order decision must precede F1's scheduler rewrite. | sequencing | Ticket 11 | Proposed dependency order | Assign to owner for route planning. |
| N03-021 | 719 | N3 can change observable traces, documentation, and model behavior. | blast radius | Ticket 11 | Preliminary impact estimate | Retain for planning. |

### N4

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| N04-001 | 723 | N4 classifies quadratic wide fan-in edge work as P1. | verdict | Ticket 17 | Static review priority | Assign to owner after deterministic evidence. |
| N04-002 | 727-729 | N4 locates edge operations, node construction, and public `all`. | location | Ticket 05 | Exact source pointers | Retain for counter instrumentation. |
| N04-003 | 733 | Edge attachment scans both adjacency lists before insertion. | fact | Ticket 05 | Static algorithm trace | Retain for deterministic measurement. |
| N04-004 | 733 | Edge detachment rebuilds adjacency lists with filtering. | fact | Ticket 05 | Static algorithm trace | Retain for deterministic measurement. |
| N04-005 | 733 | Wide node construction attaches each dependency separately. | fact | Ticket 05 | Static construction trace | Retain for deterministic measurement. |
| N04-006 | 733 | Building `n` dependencies performs O(n²) parent-list scans. | complexity claim | Ticket 05 | Static summation | Retain for deterministic measurement. |
| N04-007 | 733 | Wide-parent teardown also repeats list filtering. | complexity claim | Ticket 05 | Static algorithm analysis | Retain for deterministic measurement. |
| N04-008 | 735 | Public `all` reaches the wide-node behavior directly. | reachability claim | Ticket 05 | Public API trace | Retain for deterministic measurement. |
| N04-009 | 737 | N4 is independent of graph-wide stabilization work. | finding boundary | Ticket 10 | Algorithmic separation | Assign to owner for topology design. |
| N04-010 | 737 | A perfect dirty scheduler still leaves quadratic wide construction and teardown. | complexity claim | Ticket 10 | Algorithmic separation | Assign to owner for topology design. |
| N04-011 | 741 | Large consumer fan-in can spend disproportionate time before stabilization. | impact | Ticket 05 | Workload extrapolation | Retain for scenario design. |
| N04-012 | 745 | Static node creation and invalidation with `n` distinct dependencies must take O(n) adjacency work. | complexity invariant | Ticket 10 | Proposed topology contract | Assign to owner for design decision. |
| N04-013 | 747-751 | Static arrays, indexed dynamic edges, and small-edge specialization are candidate representations. | design options | Ticket 10 | Proposed representations | Assign to owner for design decision. |
| N04-014 | 753 | Eta must not copy Incremental's intrusive layout without analysis. | recommendation | Ticket 10 | Reference-use constraint | Retain as a design constraint. |
| N04-015 | 753 | Dynamic rewiring needs O(1) or amortized O(1) edge identity and removal. | complexity requirement | Ticket 10 | Proposed topology contract | Assign to owner for design decision. |
| N04-016 | 757 | Tests need operation counts for wide `all` and wide-parent scope invalidation at three scales. | test requirement | Ticket 16 | Proposed gate | Assign to owner for final gate design. |
| N04-017 | 761 | N4 edge storage needs co-design with F1 scheduling. | sequencing | Ticket 10 | Proposed dependency order | Assign to owner for route planning. |
| N04-018 | 761 | N4 affects node records, dynamic rewiring, DOT, invalidation, and construction tests. | blast radius | Ticket 10 | Preliminary impact estimate | Retain for planning. |
| N04-019 | 749 | Static child dependencies can use immutable arrays or small vectors. | representation option | Ticket 10 | Proposed design option | Assign to owner for topology design. |
| N04-020 | 750 | Dynamic removal can use indexed parent slots or a hash index. | representation option | Ticket 10 | Proposed design option | Assign to owner for topology design. |
| N04-021 | 751 | Edge storage can specialize zero, one, and two edges before widening. | representation option | Ticket 10 | Proposed design option | Assign to owner for topology design. |

### N5

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| N05-001 | 765 | N5 classifies the shared rollback region as P2. | verdict | Ticket 17 | Static review priority | Assign to owner for final disposition. |
| N05-002 | 769-770 | N5 locates the exception region and graph commit code. | location | Ticket 09 | Exact source pointers | Retain for transaction-model design. |
| N05-003 | 774-782 | One `try` region covers planning, commit, pending events, demand, cleanup, and delivery transition. | fact | Ticket 09 | Static control-flow trace | Retain for transaction-model design. |
| N05-004 | 784 | Any exception in that region calls `rollback_current`. | fact | Ticket 09 | Static exception-flow trace | Retain for transaction-model design. |
| N05-005 | 784 | Rollback becomes illegal after staging commits and clears its token. | invariant gap | Ticket 09 | Static state and control-flow trace | Assign to owner for transaction design. |
| N05-006 | 784 | Current safety relies on every post-commit operation being non-raising. | architecture claim | Ticket 09 | Static control-flow analysis | Assign to owner for transaction design. |
| N05-007 | 784 | Types and control flow do not localize the non-raising post-commit invariant. | architecture gap | Ticket 09 | Static type analysis | Assign to owner for transaction design. |
| N05-008 | 786 | N1 and N2 demonstrate related phase-boundary weaknesses. | evidence synthesis | Ticket 09 | Cross-finding analysis | Retain for transaction-model design. |
| N05-009 | 790 | A future post-commit failure can trigger illegal rollback and stick the phase. | risk claim | Ticket 09 | Static future-change counterexample | Assign to owner for transaction design. |
| N05-010 | 790 | The current exception structure hides the commit boundary from reviewers. | maintainability claim | Ticket 15 | Static architecture assessment | Assign to owner for module ownership. |
| N05-011 | 794-799 | The pass needs explicit planning, commit, delivery transition, and post-commit phases. | requirement | Ticket 09 | Proposed phase model | Assign to owner for design decision. |
| N05-012 | 796 | Planning and preflight can return errors while rollback remains legal. | phase requirement | Ticket 09 | Proposed phase model | Assign to owner for design decision. |
| N05-013 | 797 | Commit can contain no callbacks, fallible validation, or allocation-dependent planning. | commit invariant | Ticket 09 | Proposed phase model | Assign to owner for design decision. |
| N05-014 | 798 | State must transition to committed or delivering immediately after commit. | phase requirement | Ticket 09 | Proposed phase model | Assign to owner for design decision. |
| N05-015 | 799 | Post-commit failures must preserve the snapshot and never roll back. | exception-safety invariant | Ticket 09 | Proposed phase model | Assign to owner for design decision. |
| N05-016 | 801 | Rollback is legal only with both an open transaction and active staging token. | invariant | Ticket 09 | Proposed rollback authority | Assign to owner for design decision. |
| N05-017 | 801 | Phase-specific tokens need to encode rollback authority. | requirement | Ticket 09 | Proposed type design | Assign to owner for design decision. |
| N05-018 | 805 | N5 needs resolution with N1 and N2. | sequencing | Ticket 09 | Proposed dependency order | Assign to owner for route planning. |
| N05-019 | 805 | N5 changes private orchestration and fault-injection tests. | blast radius | Ticket 09 | Preliminary impact estimate | Retain for planning. |
| N05-020 | 805 | N5 makes existing public semantics more faithful instead of changing them. | interface claim | Ticket 13 | Preliminary semantic assessment | Assign to owner to preserve if feasible. |
| N05-021 | 776 | The shared exception region includes generation, staging, and pending work. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |
| N05-022 | 777 | The shared exception region includes bind planning and event collection. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |
| N05-023 | 778 | The shared exception region includes transaction and topology commit. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |
| N05-024 | 779 | The shared exception region includes pending observer-event marking. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |
| N05-025 | 780 | The shared exception region includes necessity update. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |
| N05-026 | 781 | The shared exception region includes timer-context cleanup. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |
| N05-027 | 782 | The shared exception region includes transition to delivery. | phase fact | Ticket 09 | Static control-flow trace | Retain for transaction design. |

## 4. Semantic-parity challenges S1-S17

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| S01-001 | 813 | Retain S1 glitch freedom because caching and dependency-first pull evaluation support it. | parity assessment | Ticket 16 | Static support with no found counterexample | Assign to owner for an executable law decision. |
| S02-001 | 814 | Amend S2 because stabilization has more work than one necessary-node traversal. | parity assessment | Ticket 10 | Static graph-work trace | Assign to owner for scheduler design. |
| S02-002 | 814 | Registry scans, reachability scans, bind fixed points, and pairwise searches enlarge the S2 gap. | complexity claim | Ticket 05 | Static source synthesis | Retain for deterministic measurement. |
| S03-001 | 815 | Retain S3 user recomputation parity within static nodes and version vectors. | bounded parity assessment | Ticket 16 | Static support with an explicit boundary | Assign to owner for an executable law decision. |
| S04-001 | 816 | Retain S4 bind-switch-condition parity. | parity assessment | Ticket 16 | Review conclusion without new qualification | Assign to owner for an executable law decision. |
| S05-001 | 817 | Amend S5 to reference F11 instead of F13. | cross-reference correction | Ticket 01 | Internal table comparison | Retain the corrected routing. |
| S05-002 | 817 | Default Incremental invalidates old bind branches. | reference fact | Ticket 07 | Reference semantic trace | Retain as reference evidence. |
| S05-003 | 817 | Bind rescoping is nondefault compatibility behavior. | parity assessment | Ticket 13 | Reference semantic trace | Assign to owner for algebra decision. |
| S06-001 | 818 | Retain S6 only for bind-only cascade convergence. | bounded parity assessment | Ticket 16 | Static support with an explicit boundary | Assign to owner for an executable law decision. |
| S06-002 | 818 | S6 does not cover N2's mixed keyed-removal and staged-bind case. | limitation | Ticket 03 | Static counterexample | Retain for executable reproduction. |
| S07-001 | 819 | Retain S7 only for selector or validation failure before commit. | bounded parity assessment | Ticket 16 | Static support with an explicit boundary | Assign to owner for an executable law decision. |
| S08-001 | 820 | Retain S8 parity for variable sets during stabilization. | parity assessment | Ticket 16 | Review conclusion without new qualification | Assign to owner for an executable law decision. |
| S09-001 | 821 | Refute S9 because the observer comparator is non-total. | parity correction | Ticket 11 | Static N3 counterexample | Assign to owner for observer contract. |
| S10-001 | 822 | Retain S10 richer delivery coalescing. | parity assessment | Ticket 11 | Static semantic review | Assign to owner for observer contract. |
| S10-002 | 822 | S10 remains subject to documented at-least-once behavior after callback failure or interruption. | limitation | Ticket 11 | Public contract qualification | Assign to owner for observer contract. |
| S11-001 | 823 | Amend S11 because direct callbacks lack invalidation events but streams distinguish terminal outcomes. | parity assessment | Ticket 13 | Static interface and implementation trace | Assign to owner for lifecycle decision. |
| S11-002 | 823 | `Unnecessary` has no valid meaning for an active Eta observer. | semantic claim | Ticket 13 | Demand and lifecycle reasoning | Assign to owner for lifecycle decision. |
| S12-001 | 824 | Refute universal S12 rollback superiority because N1 and N2 expose boundary failures. | parity correction | Ticket 09 | Static counterexamples | Assign to owner for transaction design. |
| S12-002 | 824 | N2 leaves hybrid topology after a successful mixed transaction. | counterexample link | Ticket 03 | Static N2 trace | Retain for executable reproduction. |
| S12-003 | 824 | N1 corrupts phase state before a transaction exists. | counterexample link | Ticket 02 | Static N1 trace | Retain for executable reproduction. |
| S13-001 | 825 | Narrow S13 because Probe A covers one shape, runtime, and apparently few observers. | evidence limitation | Ticket 05 | Probe-scope assessment | Amend with broader deterministic scenarios. |
| S13-002 | 825 | Probe A does not cover pairwise searches with many observers. | evidence gap | Ticket 05 | Probe-scope assessment | Retain for scenario design. |
| S13-003 | 825 | Probe A does not measure the exact packed revision. | evidence gap | Ticket 01 | Revision mismatch | Retain and rerun on the selected revision. |
| S14-001 | 826 | Refute universal S14 overflow superiority because transaction-ID overflow escapes typed failure and wedges state. | parity correction | Ticket 02 | Static N1 counterexample | Retain for executable reproduction. |
| S15-001 | 827 | Retain S15 as a dynamic-cutoff delta under F12. | parity assessment | Ticket 13 | Static interface comparison | Assign to owner for cutoff design. |
| S16-001 | 828 | Retain S16 cross-domain safety as a feature difference. | parity assessment | Ticket 09 | Review conclusion with hardening condition | Assign to owner for domain-safe design. |
| S16-002 | 828 | N1 hardening needs removal of module-global transaction and state identifiers. | requirement | Ticket 09 | Static shared-state analysis | Assign to owner for domain-safe design. |
| S17-001 | 829 | Amend S17's explanation of Incremental cycle behavior. | parity correction | Ticket 06 | Interface and edge-addition trace | Amend: detection follows active necessary-parent edge insertion and does not provide atomic rejection. |
| S17-002 | 829 | The review claims that Incremental documents cycles from bind and Expert edges. | reference fact | Ticket 06 | Interface and Expert implementation trace | Amend: the interface documents bind cycles; active necessary Expert edges use the same cycle-checked parent path. |
| S17-003 | 829 | Incremental height adjustment detects those cycles. | reference fact | Ticket 06 | Reference interface documentation | Retain as reference evidence. |
| S17-004 | 829 | The S17 parity conclusion remains reasonable despite the wrong explanation. | parity assessment | Ticket 16 | Static semantic comparison | Assign to owner for an executable law decision. |

## 5. Ranked correction plan

### Rank 1: N1

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-01-001 | 835-837 | First, make transaction allocation precede phase mutation or use guaranteed rollback. | ranked requirement | Ticket 09 | Proposed correction plan | Assign to owner for phase-model design. |
| PLN-01-002 | 837 | Overflow must use typed failure and leave the graph idle. | ranked requirement | Ticket 09 | Proposed correction plan | Assign to owner for phase-model design. |
| PLN-01-003 | 839 | Rank 1 has no design dependency. | dependency | Ticket 17 | Proposed route | Assign to owner for final route. |
| PLN-01-004 | 840 | Rank 1 affects private transaction code, stabilization code, and the overflow harness. | blast radius | Ticket 09 | Preliminary impact estimate | Retain for planning. |
| PLN-01-005 | 841 | The gate is forced overflow followed by a successful retry. | gate | Ticket 16 | Proposed regression gate | Assign to owner for final gate design. |

### Rank 2: N2

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-02-001 | 843-845 | Second, merge bind switches, keyed removals, and extension invalidations into one frozen frontier. | ranked requirement | Ticket 09 | Proposed correction plan | Assign to owner for invalidation design. |
| PLN-02-002 | 845 | Discard staged binds whose owners enter that frontier. | ranked requirement | Ticket 09 | Proposed correction plan | Assign to owner for invalidation design. |
| PLN-02-003 | 847 | Rank 2 depends on N1's reliable phase and rollback boundary. | dependency | Ticket 17 | Proposed route | Assign to owner for final route. |
| PLN-02-004 | 848 | Rank 2 affects keyed planning, bind planning, commit plans, invalidation, and Signal Map tests. | blast radius | Ticket 09 | Preliminary impact estimate | Retain for planning. |
| PLN-02-005 | 849 | The gate combines keyed removal, nested bind switching, and bounded retained-node count. | gate | Ticket 16 | Proposed regression gate | Assign to owner for final gate design. |

### Rank 3: N5

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-03-001 | 851-853 | Third, make rollback callable only before commit. | ranked requirement | Ticket 09 | Proposed correction plan | Assign to owner for phase-model design. |
| PLN-03-002 | 853 | Post-commit failures must never invoke rollback. | ranked requirement | Ticket 09 | Proposed correction plan | Assign to owner for phase-model design. |
| PLN-03-003 | 855 | Rank 3 depends on the N1 and N2 designs. | dependency | Ticket 17 | Proposed route | Assign to owner for final route. |
| PLN-03-004 | 856 | Rank 3 affects private pass orchestration and fault injection. | blast radius | Ticket 09 | Preliminary impact estimate | Retain for planning. |

### Rank 4: F13

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-04-001 | 858-860 | Fourth, gate deterministic work counts across six core workload classes. | ranked requirement | Ticket 16 | Proposed correction plan | Assign to owner for gate design. |
| PLN-04-002 | 862 | Non-invasive instrumentation can start in parallel with P0 work. | dependency | Ticket 16 | Proposed route | Assign to owner for route planning. |
| PLN-04-003 | 863 | Rank 4 affects tests, benchmarks, and private counters. | blast radius | Ticket 16 | Preliminary impact estimate | Retain for planning. |

### Rank 5: N3

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-05-001 | 865-867 | Fifth, choose a deterministic total observer order. | ranked requirement | Ticket 11 | Proposed correction plan | Assign to owner for observer design. |
| PLN-05-002 | 867 | A dependency promise requires one topological plan instead of pairwise searches. | ranked requirement | Ticket 11 | Proposed correction plan | Assign to owner for observer design. |
| PLN-05-003 | 869 | Rank 5 needs a product decision and coordination with F1. | dependency | Ticket 11 | Proposed route | Assign to owner for route planning. |
| PLN-05-004 | 870 | Rank 5 changes callback traces and documentation. | blast radius | Ticket 11 | Preliminary impact estimate | Retain for planning. |

### Rank 6: F1

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-06-001 | 872-874 | Sixth, provide O(1) quiescence and change-proportional downstream scheduling. | ranked requirement | Ticket 10 | Proposed correction plan | Assign to owner for scheduler design. |
| PLN-06-002 | 874 | Sixth, update necessity and timer demand incrementally. | ranked requirement | Ticket 10 | Proposed correction plan | Assign to owner for demand design. |
| PLN-06-003 | 876 | Rank 6 depends on F13 and preferably the N3 decision. | dependency | Ticket 17 | Proposed route | Assign to owner for final route. |
| PLN-06-004 | 877 | Rank 6 affects the engine, timers, topology, diagnostics, and model tests. | blast radius | Ticket 10 | Preliminary impact estimate | Retain for planning. |

### Rank 7: N4

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-07-001 | 879-881 | Seventh, make wide construction and invalidation linear with efficient dynamic edge removal. | ranked requirement | Ticket 10 | Proposed correction plan | Assign to owner for topology design. |
| PLN-07-002 | 883 | Rank 7 needs co-design with F1. | dependency | Ticket 10 | Proposed route | Assign to owner for route planning. |
| PLN-07-003 | 884 | Rank 7 affects node representation and all topology operations. | blast radius | Ticket 10 | Preliminary impact estimate | Retain for planning. |

### Rank 8: F7

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-08-001 | 886-888 | Eighth, remove unsafe casts from package and testing boundaries. | ranked requirement | Ticket 12 | Proposed correction plan | Assign to owner for seam design. |
| PLN-08-002 | 888 | Testing boundaries need distinct opaque token types. | ranked requirement | Ticket 12 | Proposed correction plan | Assign to owner for seam design. |
| PLN-08-003 | 890 | Rank 8 has no dependency. | dependency | Ticket 17 | Proposed route | Assign to owner for final route. |
| PLN-08-004 | 891 | Rank 8 affects the private test API and fixtures. | blast radius | Ticket 12 | Preliminary impact estimate | Retain for planning. |

### Rank 9: F10

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-09-001 | 893-895 | Ninth, document Signal Map as the sole graph functor for keyed applications. | ranked requirement | Ticket 12 | Proposed correction plan | Assign to owner for seam design. |
| PLN-09-002 | 897 | Rank 9 has no dependency. | dependency | Ticket 17 | Proposed route | Assign to owner for final route. |
| PLN-09-003 | 898 | Rank 9 changes documentation only. | blast radius | Ticket 12 | Preliminary impact estimate | Retain for planning. |

### Rank 10: F3

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-10-001 | 900-902 | Tenth, give each normative span a registry row plus a test or dated debt. | ranked requirement | Ticket 16 | Proposed correction plan | Assign to owner for law design. |
| PLN-10-002 | 904 | Rank 10 needs omitted repository files and includes new N1 and N2 laws. | dependency | Ticket 01 | Missing pack evidence | Amend by inspecting the complete repository. |
| PLN-10-003 | 905 | Rank 10 affects the registry and tests. | blast radius | Ticket 16 | Preliminary impact estimate | Retain for planning. |

### Rank 11: F12

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-11-001 | 907-909 | Eleventh, replace optional equality with a named cutoff type. | ranked requirement | Ticket 13 | Proposed correction plan | Assign to owner for algebra design. |
| PLN-11-002 | 909 | Add `set_cutoff` only after its scheduling semantics are complete. | deferred requirement | Ticket 13 | Proposed correction plan | Assign to owner for design decision. |
| PLN-11-003 | 911 | Runtime mutation depends on F1 scheduling. | dependency | Ticket 13 | Proposed route | Assign to owner for route planning. |
| PLN-11-004 | 912 | Rank 11 affects public constructors and all callers. | blast radius | Ticket 13 | Preliminary impact estimate | Retain for planning. |

### Rank 12: F8

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-12-001 | 914-916 | Twelfth, add balanced associative reduction with O(log n) updates. | ranked requirement | Ticket 13 | Proposed correction plan | Assign to owner for algebra design. |
| PLN-12-002 | 916 | O(1) amortized accumulation needs explicit delta algebra. | ranked requirement | Ticket 13 | Proposed correction plan | Assign to owner for algebra design. |
| PLN-12-003 | 918 | Rank 12 depends on F1 and N4. | dependency | Ticket 13 | Proposed route | Assign to owner for route planning. |
| PLN-12-004 | 919 | Rank 12 affects public API, node kinds, and complexity tests. | blast radius | Ticket 13 | Preliminary impact estimate | Retain for planning. |

### Rank 13: F4

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-13-001 | 921-923 | Thirteenth, expose a separate observer finish event only if consumers demand it. | optional requirement | Ticket 13 | Proposed correction plan | Assign to owner for lifecycle decision. |
| PLN-13-002 | 923 | Eta must not add a misleading `Unnecessary` value update. | ranked requirement | Ticket 13 | Proposed correction plan | Assign to owner for lifecycle decision. |
| PLN-13-003 | 925 | Rank 13 depends on demonstrated product need. | dependency | Ticket 13 | Proposed route | Assign to owner for product decision. |
| PLN-13-004 | 926 | Rank 13 affects observer APIs and adapters. | blast radius | Ticket 13 | Preliminary impact estimate | Retain for planning. |

### Rank 14: F5, F6, and F14

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| PLN-14-001 | 928-930 | Last, remove dead functors and semantically empty wrappers. | ranked requirement | Ticket 15 | Proposed correction plan | Amend to decide retention, canonical adoption, replacement, or removal from invariant and consumer value. |
| PLN-14-002 | 930 | Last, extract `Stream_bridge`. | ranked requirement | Ticket 15 | Proposed correction plan | Assign to owner for module design. |
| PLN-14-003 | 930 | Retain phase-typed state machines and pure policy modules. | ranked requirement | Ticket 15 | Proposed correction plan | Assign to owner for module design. |
| PLN-14-004 | 932 | Rank 14 follows N1, N2, F1, and N4. | dependency | Ticket 15 | Proposed route | Assign to owner for route planning. |
| PLN-14-005 | 933 | Rank 14 affects private modules, Dune, and tests. | blast radius | Ticket 15 | Preliminary impact estimate | Retain for planning. |

### Explicitly rejected or deferred corrections

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| DEF-001 | 937 | Do not publish broad Expert without a second external node-kind consumer and stable invariants. | rejected correction | Ticket 12 | Mixed consumer-count and safety rationale | Reject the consumer-count prerequisite and retain the stable-invariant requirement. |
| DEF-002 | 938 | Do not pursue F9 interface parity as one batch. | rejected correction | Ticket 13 | Product-scope recommendation | Reject the parity batch. |
| DEF-003 | 938 | Split F9 candidates by concrete use case. | deferred correction | Ticket 13 | Product-scope recommendation | Assign to owner for algebra decisions. |
| DEF-004 | 939 | Do not add bind rescoping without a benchmarked workload. | deferred correction | Ticket 13 | Evidence condition | Assign to owner for product decision. |
| DEF-005 | 939 | Bind rescoping also needs a complete scope and lifecycle RFC. | deferred correction | Ticket 13 | Design condition | Assign to owner for design decision. |

## 6. Open questions for maintainers

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| Q01-001 | 945 | Which revision is authoritative, packed `4197be98` or probe baseline `5694938a`? | open question | Ticket 01 | Conflicting review metadata | Retain and answer from repository history and ticket scope. |
| Q01-002 | 945 | Deterministic work-count gates need a rerun on the selected revision. | evidence request | Ticket 05 | Revision mismatch | Assign to owner for prototype evidence. |
| Q02-001 | 946 | Which registry spans and named Signal tests settle F3 and repository-wide F6 use? | open question | Ticket 01 | Evidence omitted from pack | Retain and answer from the complete repository. |
| Q03-001 | 947 | Is dependency-ordered callback delivery a public law? | open question | Ticket 11 | Public prose appears weaker than implementation intent | Assign to owner for observer decision. |
| Q03-002 | 947 | The answer chooses topological scheduling or simple identity order for N3. | design consequence | Ticket 11 | Explicit design fork | Assign to owner for observer decision. |
| Q04-001 | 948 | Does a test combine nested bind switching with removal of the same keyed child? | open question | Ticket 03 | Packed tests omitted | Retain for executable evidence search. |
| Q04-002 | 948 | Existing output-only assertions can miss retained invalid topology. | evidence warning | Ticket 03 | Static N2 trace | Retain for prototype observations. |
| Q05-001 | 949 | Is `Keyed.Testing` intended for packages outside this repository? | open question | Ticket 12 | Package intent not established | Assign to owner for seam decision. |
| Q05-002 | 949 | If not external, can local typed assertions replace the generic CMI-visible token? | design option | Ticket 12 | Proposed narrower test seam | Assign to owner for seam decision. |
| Q06-001 | 950 | Does ADR 0004 reject all first-party SPIs or only broad application Expert APIs? | open question | Ticket 12 | ADR omitted from pack | Assign to owner after ticket 08 evidence. |
| Q06-002 | 950 | The ADR distinction materially changes F2. | design consequence | Ticket 12 | Architecture assessment | Retain in the seam decision. |
| Q07-001 | 951 | Must cutoff mutation reevaluate now or affect only later candidates? | open question | Ticket 13 | Runtime semantics unspecified | Assign to owner for cutoff design. |
| Q07-002 | 951 | Eta must decide cutoff reevaluation before exposing `set_cutoff`. | publication requirement | Ticket 13 | Explicit semantic blocker | Assign to owner for cutoff design. |

## 7. Binding recommendation

| ID | Review lines | Gist | Class | Owner | Evidence status | Ticket-01 disposition |
|---|---:|---|---|---|---|---|
| REC-001 | 957 | Do not start with interface parity. | binding recommendation | Ticket 17 | Review synthesis | Assign to owner for final route. |
| REC-002 | 957 | Do not start by publishing Expert. | binding recommendation | Ticket 17 | Review synthesis | Assign to owner for final route. |
| REC-003 | 959 | First repair N1, N2, and N5 at the transaction and topology boundary. | binding recommendation | Ticket 17 | Severity and dependency synthesis | Assign to owner for final route. |
| REC-004 | 959 | Instrument F13 graph work after or alongside boundary repair. | binding recommendation | Ticket 17 | Dependency synthesis | Assign to owner for final route. |
| REC-005 | 959 | Then redesign F1 scheduling, N3 ordering, and N4 edge storage. | binding recommendation | Ticket 17 | Dependency synthesis | Assign to owner for final route. |
| REC-006 | 959 | Core changes determine stable laws for extensions, folds, cutoffs, and cleanup. | dependency claim | Ticket 17 | Architecture synthesis | Assign to owner for final route. |
| REC-007 | 961 | Eta Signal is ambitious and often carefully engineered. | assessment | Ticket 17 | Review synthesis | Retain as context, not evidence of correctness. |
| REC-008 | 961 | Its correctness argument is spread across too many phase adapters. | architecture verdict | Ticket 15 | Static architecture synthesis | Assign to owner for module design. |
| REC-009 | 961 | The immediate design needs one explicit immutable commit plan. | binding recommendation | Ticket 09 | Review synthesis | Assign to owner for transaction design. |
| REC-010 | 961 | The immediate design needs one closed invalidation frontier. | binding recommendation | Ticket 09 | Review synthesis | Assign to owner for invalidation design. |
| REC-011 | 961 | The immediate design needs an atomic phase machine. | binding recommendation | Ticket 09 | Review synthesis | Assign to owner for phase-model design. |
| REC-012 | 961 | The immediate design needs measurable dirty-driven work. | binding recommendation | Ticket 10 | Review synthesis | Assign to owner for scheduler design. |
| REC-013 | 961 | All other work is downstream from those core design results. | sequencing | Ticket 17 | Review synthesis | Assign to owner for final route. |

## Coverage summary

This census includes each top-level source section from section 0 through section 7.

The census has 548 claim rows. Scope has 16 rows, and the executive verdict has 17 rows.

F1-F14 have 252 rows. N1-N5 have 146 rows. Each named finding has at least one row.

S1-S17 have 31 rows. The ranked plan has 55 rows across all 14 ranks.

The rejected or deferred group has 5 rows. The seven maintainer questions have 13 rows because independent consequences use separate rows.

The binding recommendation has 13 rows. Every row has one ticket owner and a resolved ticket-01 disposition.

No claim has an out-of-scope owner. The planning map gives every substantive review topic to tickets 01-17.

# Executable laws and reference model

Type: prototype
Status: resolved
Blocked by: 08, 11, 12, 13, 14, 15, 16, 17, 18

## Question

Which executable laws and deterministic reference model prove the selected
spatiotemporal component contract?

Build a small pure lifecycle model and compare implementation traces with it.
Cover recovery, at-most-once cleanup, provider ordering, committed-view
coherence, cycle behavior, progress, schedule independence, reconciliation
normal forms, and HMR rollback.

For each law, state its generated class, observation boundary, discriminating
case, and counterexample output.

## Answer

Use one observation-factored deterministic model with focused algebraic
oracles. Do not build one model that copies production runtime internals.

The user reviewed and approved this verification design.

### Reference-model seam

The pure model owns only semantic facts:

- desired dependency edges and accepted snapshots.
- lifecycle phases and activation generations.
- provider episodes and complete committed views.
- direct leases, cleanup counts, and settlement outcomes.
- context integrity, causes, replacement state, and normalized terminal state.

The model does not contain Eta fibers, supervisors, Eio switches, loader
handles, or mutable component values.

A private production test driver accepts semantic commands and returns trusted
atomic observations. The model and driver use separate state representations.
They share only command and observation types.

The harness compares every selected lifecycle command prefix. It also compares
each quiescent reconciliation prefix with a separate direct oracle.

The comparison maintains a growing bijection between model and runtime
identities. It checks identity reuse and freshness before terminal
alpha-normalization.

### Law structure

Each generated law names these four facts:

1. The generated class.
2. The observation boundary.
3. A constructed discriminating case.
4. The complete counterexample output.

Structural generators construct their discriminating cases. They do not depend
on random sampling to find a required branch.

Each finite outcome matrix contains every branch in every generated sample.
Rotation and reversal vary only the branch order.

The production matrix has 23 named law families. It covers:

- recovery, cleanup cardinality, generation fences, causes, retry, children,
  quarantine, and failure locality.
- provider ordering, committed views, lease cardinality, duplicate providers,
  equal-value replacement, cycles, isolation, and interception.
- desired-state admission, preparation revisions, simultaneous updates,
  reconciliation normal forms, and identity rules.
- replacement staging, atomic publication, rollback, restoration, and native
  residency.
- independence, shared-key commutation, metadata laws, and caller-defined
  equivalence.
- diagnostic revisions, change waits, settlement reports, failure rendering,
  and telemetry neutrality.
- static interface rejection, Eta-test model conformance, and Eio adversarial
  lifecycle tests.

The executable-law registry must cite each normative public-interface span.
The public interface and registry must name each property in the same change.

### Progress and failure boundary

Progress properties generate a finite acyclic graph, paused orchestration input,
terminating activation, and successful cleanup. They use controlled fair
schedules instead of wall-clock timing.

Failure properties remove the successful-cleanup condition. They compare
complete causes, quarantine, retained leases, blocked provider settlement, and
terminal-report eligibility.

A completed cleanup failure produces a degraded terminal outcome. A
nonterminating cleanup keeps settlement pending and preserves any known primary
cause.

### Runtime verification layers

The production gate has four layers:

1. Pure QCheck laws run the deterministic model and algebraic oracles.
2. `Eta_test` compares controlled runtime traces with every model prefix.
3. `Eta_eio` repeats cancellation and cleanup races under adversarial schedules.
4. Compiler and process suites cover static rejection and native-code residency.

The `Eta_test` driver exposes exact causes through a private trusted interface.
Production diagnostics continue to expose opaque failures.

Every effect-backed law classifies legitimate background work. Successful,
failed, cancelled, rejected, rollback, and shutdown exits require an available
empty fiber census.

A controlled nonterminating cleanup can retain owned work while its settlement
is pending. After the test releases that cleanup, shutdown must produce an
available empty census.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-executable-laws` at commit `d36ac61f`. See the
[prototype source](https://github.com/ribelo/eta/tree/d36ac61f5347109633b0d575b524e8e352747373/.scratch/eta-component-runtime-executable-laws)
and its
[law catalog](https://github.com/ribelo/eta/blob/d36ac61f5347109633b0d575b524e8e352747373/.scratch/eta-component-runtime-executable-laws/LAW_CATALOG.md).

The prototype runs 16 QCheck properties. It compares every lifecycle command
prefix with a separately represented runtime simulator.

The traces cover recovery, repeated successful and failed disposal, provider
ordering, committed-view coherence, cycle rejection, progress, confluence,
reconciliation, identity, HMR, causes, quarantine, independence, and metadata
laws.

An independent high-tier review required three correction rounds. Its final
verdict was `ready for human review`, and the user approved the design.

# Cordis semantic contract for Eta

## Research question

This report identifies the Cordis semantics that transfer to an Eta component
runtime. It does not design an Eta interface.

The primary source is *A Programming Paradigm for Spatiotemporal
Composability*, pages 1–88. The supplied PDF is the authority for all citations.

The Eta destination fixes these constraints:

- Eta keeps `Effect.t` as `('a, 'err) Effect.t`.
- The component runtime owns requirements, provisions, and component
  lifecycles.
- The design does not add an environment channel, `Layer`, or `provide`
  operation to Eta effects.
- In this report, **component instance** replaces the paper's term **fiber**.

These constraints come from the Wayfinder map. They are project constraints,
not claims from the paper.

## Decision summary

Eta can transfer the Cordis contract as a component-runtime protocol. It does
not need to transfer the paper's recursive context representation or its
TypeScript API.

The transferable contract has three levels:

1. An atomic acquisition returns a witnessed inverse.
2. A component instance declares requirements and provisions.
3. The runtime orders activation, withdrawal, recovery, and reconciliation.

Recovery means observational equivalence at a declared observation boundary.
It does not mean equality of physical state. Global recovery also needs
independence between effects of different component instances. The paper
derives this independence when all shared state uses coeffect keys and shared
key operations commute. [Cordis, pp. 23–27, §3.3.2, Definitions 33–41 and
Theorem 42]

The runtime must keep a committed provider view for each live component
instance. It must stop a departing provider from serving new consumers before
it runs recovery. It must then wait for existing consumers to finish
deactivation. [Cordis, pp. 34–35, §4.3.1, Definition 50 and rules L-Leave and
L-Unload]

Configuration reconciliation and hot replacement sit above this lifecycle
contract. They are not properties of `Effect.t`. [Cordis, pp. 61–66, §5.2]

## Terms and observation model

### Component model

A Cordis component declares requirements, declares possible provisions, and
supplies a witnessed effect computation. The computation installs the
component's contribution and returns its inverse. [Cordis, p. 28, §4.1,
Definition 43]

A component instance adds identity, a parent, an owned provision table, a
retirement flag, and lifecycle state. The paper records the providers used at
activation in a committed view. [Cordis, pp. 28–29, §4.1, Definition 44]

The running dependency context is the union of provision tables from active
component instances. The base calculus requires disjoint provisions, so each
key has one provider. [Cordis, pp. 29–30, §4.1, Definition 45]

The paper later scopes this rule by isolation realm. Two component instances
can provide one logical key when their realms differ. [Cordis, pp. 20–21,
§3.2.3, Definitions 28–29]

### Observational equivalence

Physical recovery is not the contract. Allocation, deallocation, and generated
names cannot restore the exact prior representation. The paper therefore reads
state equality through observational equivalence. [Cordis, p. 23, §3.3.2]

Two coeffect contexts are equivalent when they have the same key domain and
equivalent values at each key. State equivalence observes the coeffect
projection. Unbound representation state is not observable by this relation.
[Cordis, pp. 23–24, §3.3.2, Definition 33]

Each key defines its value equivalence and its permitted operations. An
admissible value equivalence cannot distinguish more states than those
operations distinguish. [Cordis, pp. 18, 23–24, §3.2.1, Definition 24, and
§3.3.2, Definitions 34–35]

An effect must respect the equivalence. Its inverse must also respect the
equivalence and recover the input up to that equivalence. [Cordis, pp. 24–25,
§3.3.2, Definitions 36–37 and Lemma 38]

The calculus uses a second relation for recovery exactness. This relation
forgets lifecycle control fields but compares effect-owned tables and ambient
state. The two relations have different purposes and neither contains the
other. [Cordis, pp. 38–39, §4.4, Definition 53]

### Eta observation boundary

The transferred contract must name its observers. The minimum observer set is:

- typed operations published by provision keys
- operation outcomes
- dependency presence
- provider identity where replacement is observable
- component lifecycle and diagnostics
- state explicitly placed inside the component-runtime boundary

This boundary follows the paper's context equivalence, operation tests, and
provider views. [Cordis, pp. 23–25, §3.3.2, Definitions 33–39, and p. 30,
§4.2, Definition 46]

External emissions are not part of recovered state. Network sends, file
writes visible to others, and similar emissions cross the system boundary.
[Cordis, pp. 67–68, §6.1]

## Semantic contracts

## Local temporal contract

### Atomic effect

An atomic tracked effect transforms context state and returns an inverse. The
inverse is selected at the application state. It only needs to recover that
application, not every possible state. [Cordis, pp. 11–12, §3.1.2,
Definition 8]

The inverse is a left inverse. The contract requires `inverse (forward state)`
to recover `state`. It does not require the forward operation to reverse the
inverse. [Cordis, p. 9, §3.1.1, Definition 1, and p. 12, §3.1.2, Definition 8]

Sequential composition accumulates inverses in reverse execution order.
Witnessed effects remain witnessed under composition. [Cordis, pp. 12–13,
§3.1.2, Definitions 9–12 and Theorems 10–13]

### Component-local recovery

A component activation can contain many iterations. Each successful iteration
returns its inverse and optional continuation. The accumulated inverse recovers
successful iterations in last-in-first-out order. [Cordis, pp. 35–36, §4.3.2,
Definitions 51–52]

A reverse-order teardown recovers each preceding state and preserves the
recovery target. This result does not require independence from other effects.
[Cordis, pp. 14–15, §3.1.2, Theorems 15–16]

An activation can stop at an iteration boundary after its target changes. The
runtime then recovers only the iterations that completed. [Cordis, p. 36,
§4.3.2, rules L-Divert and L-Iter]

An in-flight asynchronous iteration has inertia. It lands before recovery,
even after the target changes. Its returned inverse joins the recovery
accumulator. [Cordis, p. 37, §4.3.3]

### Assumptions

Local temporal recovery needs all of these assumptions:

- Each successful atomic effect supplies a valid inverse.
- Each inverse respects the selected observational equivalence.
- All component-owned mutations use tracked operations.
- The runtime retains the accumulator until recovery completes.
- Recovery runs accumulated inverses in last-in-first-out order.
- An asynchronous operation that lands after diversion still returns an
  inverse.

The paper makes the witness an author obligation in Cordis. The runtime does
not prove it. [Cordis, pp. 55–56, §5.1.1]

### Observation boundary

The local guarantee compares state before activation with state after
recovery. It includes tracked state and provision tables. It excludes
lifecycle bookkeeping and external emissions. [Cordis, pp. 43–45, §4.4.2,
Theorem 61 and Corollary 62, and pp. 67–68, §6.1]

## Local spatial contract

### Typed requirements and provisions

The dependency context is a finite typed partial map. Each key determines its
value type. Provision of an existing key and withdrawal of an absent key are
errors with no state transition. [Cordis, pp. 18–19, §3.2.1, Definitions
22–23]

A requirement is satisfied only when every declared key is present. Every
context transition is classified as activating, deactivating, or neutral
against that predicate. [Cordis, pp. 19–20, §3.2.2, Definitions 25–26]

A component activates only when all requirements are satisfied. A loss of
satisfaction is detected at the transition that causes it. [Cordis, p. 20,
§3.2.2]

Requirement satisfaction alone gives only half of withdrawal ordering. A
notification cannot keep a dependency readable during consumer teardown.
Global lifecycle machinery supplies that guarantee. [Cordis, p. 20, §3.2.2]

### Provider identity

The target view maps every required key to its provider instance. An active
component instance stores the view used for activation. Equal values from
different providers do not make the views equal. [Cordis, p. 30, §4.2,
Definition 46]

A provider replacement therefore causes deactivation and reactivation. An
in-place value update from the same provider does not cause replacement unless
the provision contract adds separate change semantics. [Cordis, p. 60,
§5.1.3]

### Isolation

Isolation changes key resolution for a derived context. A logical key first
resolves to a realm and then to a value in that realm. [Cordis, pp. 20–21,
§3.2.3, Definitions 27–29]

Isolation does not mutate the inherited shared table in the formal model.
Recovery discards the derived context. [Cordis, pp. 20–21, §3.2.3,
Definition 27]

The observation boundary is realm-sensitive. A consumer only relies on the
provider selected in its realm. A same-key provider in another realm does not
block withdrawal. [Cordis, pp. 34–35, §4.3.1]

### Interception

Interception changes how a provision is used, not whether that provision is
present. Each key has a metadata monoid. Component metadata and context
metadata combine before the provider creates the value. [Cordis, pp. 21–22,
§3.2.3, Definitions 30–31]

Context metadata has priority in the paper's right-biased merge. This rule
lets an enclosing context constrain access without changing the component.
[Cordis, p. 22, §3.2.3, Definition 31]

Interception is a derived-context operation in the formal model. It does not
need a tracked inverse when the derived context owns its lifetime. [Cordis,
pp. 20–22, §3.2.3, Definitions 27 and 31]

### Assumptions

Local spatial safety needs all of these assumptions:

- Every dependency access uses the component-runtime mediation point.
- Every requirement is declared before activation.
- Every provision uses a typed key.
- Every dependency change passes through an observed transition boundary.
- Resolution uses the committed provider view during teardown.

The TypeScript proxy rejects undeclared and inactive property access. That
proxy is one implementation of the mediation assumption, not the semantic
contract. [Cordis, p. 61, §5.1.4, Algorithm 6]

### Observation boundary

The local spatial guarantee observes key presence, provider resolution,
declared operation behavior, and operation outcomes. It does not observe an
undeclared ambient object or direct host access. [Cordis, pp. 23–25, §3.3.2,
Definitions 33–39, and pp. 69–70, §6.3–§6.4]

## Global lifecycle contract

### Lifecycle states

The complete lifecycle has inactive, activating, active, and deactivating
states. Inactive state can also retain an activation error. [Cordis, p. 33,
§4.3, Definition 49]

The orchestrator inserts, retires, and removes component instances. Retirement
requests deactivation. Removal is legal only after the instance is inactive
and has no children. [Cordis, pp. 30–31, §4.2, rules O-Insert, O-Retire, and
O-Remove]

Child registration is itself tracked. Its inverse retires the child instead
of removing it. This rule preserves the child's opportunity to deactivate and
recover. [Cordis, pp. 31–32, §4.2, Definition 47]

### Withdrawal ordering

Activation starts only after all providers are active. A provider episode
starts before every consumer episode that resolves to it. [Cordis, pp. 45–46,
§4.4.3, Theorem 63]

Departure has two phases. First, L-Leave marks the provider as deactivating and
removes it from new resolution. Second, L-Unload runs recovery only after no
installed consumer retains a committed reference to that provider. [Cordis,
pp. 34–35, §4.3.1, Definition 50]

The consumer keeps its committed provider view throughout deactivation.
Therefore, it can use the dependency during teardown. The provider's binding
stays unchanged until that consumer episode ends. [Cordis, pp. 45–46, §4.4.3,
Theorem 63]

The provider episode outlives each consumer episode that resolved to it. This
ordering applies to dependency edges. Parent-child edges alone do not impose
the same teardown order. [Cordis, p. 35, §4.3.1, and pp. 45–46, §4.4.3,
Theorem 63]

### Resolution coherence

An activation records one provider view. Each later iteration proceeds only
while the current target matches that view. A changed target diverts the
activation into recovery. [Cordis, pp. 45–47, §4.4.3, Theorem 64]

An iteration already in flight can land against a stale view. The runtime must
then recover its contribution instead of exposing the component as active.
[Cordis, pp. 37, 46–47, §4.3.3 and §4.4.3, Theorem 64]

This is component-level coherence, not reactive glitch freedom. Cordis has no
global propagation turn. [Cordis, pp. 78–79, §7.4]

### Failure

An activation failure carries no inverse for the failing iteration. The
runtime still recovers all earlier successful iterations. [Cordis, pp. 37–38,
§4.3.4, Definition 49 and rule L-Raise]

After recovery, the component instance becomes inactive with the error
recorded. It does not retry against the unchanged environment. [Cordis, p. 38,
§4.3.4]

Failure is local to the component instance. The paper does not propagate it to
the parent. Sibling component instances remain active. [Cordis, p. 38,
§4.3.4]

A failed instance has no committed view and blocks no provider withdrawal.
[Cordis, p. 38, §4.3.4]

Confluence excludes failed terminal states. Different schedules can make an
activation fail or succeed. Recovery still removes the failed instance's state
contribution. [Cordis, p. 53, §4.4.5, Theorem 73 discussion]

This paper-specific failure policy transfers as a candidate contract, not as a
necessary consequence of temporal recovery. Eta design work must decide error
retention, diagnostics, and retry authority.

### Global temporal recovery

Effects from different component instances can interleave. Exact recovery of
one instance requires its transformations to commute with transformations from
other instances. Foreign transformations must also preserve the inverses and
continuations that its iterator yields. [Cordis, pp. 43–44, §4.4.2,
Definition 60]

Under pairwise independence, applying one instance's accumulator removes its
contribution and preserves all foreign contributions, apart from control
fields. Terminal recovery gives the same result for success, diversion, and
failure. [Cordis, pp. 43–45, §4.4.2, Theorem 61 and Corollary 62]

The paper derives independence for context-mediated effects when:

- all shared locations are represented by provision keys
- operations at distinct keys touch only their own binding
- each key used by multiple instances has commutative operations
- key operations preserve each other's outcomes, inverses, and continuations

[Cordis, pp. 24–27, §3.3.2, Definitions 39–41 and Theorems 40–42]

Ordered middleware is a counterexample. Registration order changes behavior,
so such a key is not commutative. The ordering must move into a component
accumulator or an explicit dependency edge. [Cordis, pp. 25–26, §3.3.2]

### Progress

The withdrawal guard does not deadlock under the paper's assumptions. A
deactivating provider chain ends because the dependency precedence relation is
acyclic and the registry is finite. [Cordis, pp. 47–48, §4.4.4, Definition 65
and Theorem 66]

Every maximal lifecycle-only sequence reaches quiescence when:

- the dependency precedence relation is acyclic
- every effect iterator has a finite uniform length bound
- the total set of component-instance names is finite

[Cordis, pp. 47–48, §4.4.4, Theorem 66]

The theorem gives a finite step bound. It does not require a scheduler fairness
assumption. Orchestration must stop during the lifecycle-only sequence.
[Cordis, pp. 47–48, §4.4.4, Theorem 66]

The finite-name assumption excludes unbounded recursive component
registration. A finite program set, bounded iterator length, and an acyclic
registration relation can establish the assumption. [Cordis, p. 48, §4.4.4]

### Confluence

At quiescence, the supported set equals the active set under two conditions.
No component instance failed. Each component installs every key that it
declares as a possible provision. [Cordis, pp. 49–50, §4.4.5, Definitions 67
and 69, Lemma 70]

Under acyclic dependencies, pairwise independence, total provisions, and no
failures, lifecycle schedules with the same orchestration inputs reach one
normal form. Name generation is compared up to renaming. [Cordis, pp. 49–53,
§4.4.5, Lemmas 68–72 and Theorem 73]

The normal form is equivalent to one static assembly of the final active
components in dependency order. Intermediate activation and deactivation
history leaves no recovered state behind. [Cordis, pp. 49, 52–53, §4.4.5,
Theorem 73]

This guarantee concerns final state. It does not erase external emissions from
the history. [Cordis, p. 53, §4.4.5, and pp. 67–68, §6.1]

## Configuration reconciliation contract

A declarative entry records stable identity, component module, isolation,
interception, component configuration, and administrative disablement.
Entries form the authoritative desired-state tree. [Cordis, pp. 61–62,
§5.2.1, Definition 74]

Reconciliation translates entry changes into instance operations. The paper
uses these field policies:

- Identity or module changes rebuild the entry.
- Isolation changes reassign realms.
- Interception changes update metadata without replacement.
- Component configuration changes go to the component.
- Disablement retires or reloads the component instance.

[Cordis, pp. 62–63, §5.2.1]

The semantic contract is narrower than these policies. Reconciliation must:

- preserve stable entry identity across tree diffs
- issue insertions, retirements, and replacements through the lifecycle
- wait for lifecycle quiescence before it reports completion
- converge to the same observable normal form as a fresh load of final desired
  state, under the confluence assumptions

The paper connects these requirements to progress, ordering, recovery, and
confluence. [Cordis, pp. 62–63, §5.2.1, Theorem 66, Corollary 62, Theorem 63,
and Theorem 73]

The paper allows modules to load concurrently. Dependency order constrains
activation, not module fetch or evaluation. [Cordis, p. 63, §5.2.1]

Managed-realm reassignment preserves a binding for contexts that move with
their provider. It notifies only consumers whose visibility changes.
[Cordis, pp. 63–64, §5.2.1, Algorithm 7 and Equation 65]

## Hot replacement contract

Hot replacement uses component-instance replacement. It recovers the old
instance and creates a new instance from the reloaded module. [Cordis,
pp. 64–66, §5.2.2, Algorithms 8–10]

The paper classifies changed module graphs into accepted and declined sets.
Import cycles that remain undecided are declined. It then detects entries whose
accepted dependency subgraph is stale. [Cordis, pp. 64–65, §5.2.2,
Algorithms 8–9]

The intended transactional property is all-or-rollback for stale entries. If a
module import fails, the loader restores module caches and rebuilds every stale
entry from its backup. [Cordis, pp. 65–66, §5.2.2, Algorithm 10]

The transferable semantic requirement is:

- classify a replacement set before mutation
- keep the old module artifacts until the replacement commits
- route every old and new instance through normal lifecycle operations
- restore the old observable composition when replacement fails
- expose no terminal state that mixes selected old and new component versions

The paper does not preserve component-local state. State survives replacement
only when a longer-lived context or coeffect owns it. [Cordis, pp. 76–77,
§7.3]

## Assumption register

The following assumptions define the validity envelope for the complete
contract.

| Assumption | Needed result | Source |
|---|---|---|
| Each successful effect has a valid left inverse. | Local and global recovery. | p. 12, Definition 8 |
| Effects and inverses respect observational equivalence. | Quotient recovery and rule invariance. | pp. 24–25, Definitions 36–37 and Lemma 38 |
| All shared mutations use the mediated context. | Attribution and independence derivation. | pp. 22–27, §3.3 |
| Operations at shared keys commute and preserve outcomes. | Cross-instance independence. | pp. 24–26, Definitions 39–42 |
| Provisions are disjoint within one realm. | Unique provider and well-formed registry. | pp. 28–30, Definitions 43–45 |
| Effect computations are confined to their own instance. | Complete rule-write inventory. | pp. 31–32, Definition 48 |
| The dependency precedence relation is acyclic. | Guard release, progress, and confluence. | pp. 47–53, Definition 65 and Theorems 66 and 73 |
| Iterator length has a finite uniform bound. | Termination. | pp. 47–48, Theorem 66 |
| The run creates finitely many instance names. | Termination and canonical reduction. | pp. 47–53, Theorems 66 and 73 |
| Components are total on declared provisions. | Active set equals desired support and confluence. | pp. 49–50, Definition 69 and Lemma 70 |
| No terminal component instance failed. | Unique normal form. | pp. 49–53, Lemma 70 and Theorem 73 |
| Orchestration inputs stop while the lifecycle settles. | Lifecycle termination. | pp. 47–48, Theorem 66 |

These are not optional proof details. A design claim that omits one of these
assumptions is stronger than the paper.

## Mechanisms versus semantic requirements

### Transferable mechanisms

The following mechanisms encode semantic information:

- a witnessed inverse for each successful atomic effect
- one recovery accumulator per component instance
- explicit inactive, activating, active, and deactivating phases
- a committed provider view
- target recomputation after dependency changes
- the two-phase provider departure fence
- a dependency-sensitive withdrawal guard
- tracked child registration
- stable identity for reconciliation

The paper's theorems refer directly to these mechanisms. Replacing one requires
an equivalent proof obligation. [Cordis, pp. 28–53, §4]

### Realization choices

The following mechanisms are TypeScript or Cordis realization choices:

- a recursive `ctx` object as the representation of the unified context
- symbol-keyed `@@store`, `@@isolate`, and `@@intercept` slots
- `ctx.effect`, `ctx.get`, `ctx.set`, and `ctx.use` method names
- JavaScript generators for effect iterators
- promises and task handles for inertia
- a JavaScript `Proxy` for mediated property access
- `fiber.uid` as provider identity
- hashes or tuples inside `fiber.target`
- Node.js module-cache invalidation
- YAML and JSON configuration adapters
- delimiter symbols and tags for managed realm movement

The theory-to-implementation table and Algorithms 1–10 identify these
realizations. [Cordis, pp. 54–66, §5.1–§5.2]

The paper's recursive fixed-point context type is also a formal construction,
not an Eta representation requirement. The contract only needs attributable
state, typed provisions, accumulators, hierarchy, and mediated observation.
[Cordis, pp. 22–23, §3.3.1, Definition 32]

In-place and derived realization are interchangeable only when they preserve
the same effect denotation. Isolation and interception use derived contexts in
the paper. [Cordis, pp. 20–22, §3.2.3, Definition 27]

## Limits

### System boundary

The runtime can recover only locations that it controls exclusively and can
restore. Other operations act outside the tracked context. [Cordis, pp. 67–68,
§6.1]

Acquisition can be revertible while later emission is irreversible. Closing a
socket can recover the acquisition. It cannot retract bytes already delivered.
[Cordis, pp. 67–68, §6.1]

Withholding and compensation can address emissions. Compensation uses a
different application equivalence, so the paper's independence and
metatheory do not transfer without new proofs. [Cordis, p. 68, §6.1]

### Security

Declared access and interception constrain mediated provision access. They do
not sandbox hostile native code. Untrusted code needs an external isolation
boundary. [Cordis, pp. 69–70, §6.3]

### Dependency model

Cycles leave all members inactive. The progress theorem assumes acyclicity.
Finer component decomposition can remove cycles, but it increases component
count and configuration complexity. [Cordis, pp. 47–48, §4.4.4, and p. 71,
§6.5]

Key identity and a local type family do not solve compatibility across
independently compiled packages. Interface drift, key collision, behavioral
compatibility, and version coexistence remain outside the model. [Cordis,
pp. 72–73, §6.6]

The base calculus permits one provider per key in one realm. Service
multiplexing needs exclusive switching or a broker component. [Cordis,
pp. 68–69, §6.2]

### Recovery and replacement

Component-local state does not survive replacement. The paper names
DSU-style migration above revertible effects as future work. [Cordis,
pp. 76–77, §7.3]

Confluence excludes activation failures and external emissions. It also needs
total provisions and pairwise independence. [Cordis, pp. 49–53, §4.4.5,
Theorem 73]

The Koishi evidence is one TypeScript ecosystem. It is observational, not a
controlled or quantitative evaluation. [Cordis, pp. 66–67, §5.3]

## Open problems for the Eta design package

The paper leaves these semantic questions open:

1. **Equivalence ownership.** The design must assign ownership of each key's
   observational equivalence and executable operation laws.
2. **Independence evidence.** The design must state how a provider proves or
   tests commutativity, outcome stability, inverse stability, and continuation
   stability.
3. **Noncommutative keys.** The design needs an explicit ordering model for
   middleware chains and other noncommutative provisions.
4. **Failure authority.** The design must decide who can clear a retained
   activation error and request another activation.
5. **Cancellation.** The paper models asynchronous inertia but does not define
   host cancellation, interruption masks, or cancellation errors.
6. **Recovery failure.** The paper assumes that accumulated inverses complete.
   It does not define an inverse that fails, raises, or hangs.
7. **Concurrent orchestration.** Progress applies after orchestration inputs
   stop. The paper does not give convergence bounds for an endless desired-state
   stream.
8. **Transactional replacement.** The paper does not define the visibility
   boundary or commit point for multi-entry hot replacement.
9. **Provider versions.** The paper leaves namespace, version, and structural
   compatibility as an open combined model.
10. **State migration.** The paper does not migrate component-local state
    between versions.
11. **External emissions.** The design needs separate contracts for withholding
    or compensation where recovery must cover emissions.
12. **Sandboxing.** The component protocol does not isolate untrusted native
    code.

The paper states items 9–12 directly. [Cordis, pp. 67–73, §6.1, §6.3, and
§6.6, and pp. 76–77, §7.3]

Items 4–8 are gaps in the operational model. Failure only covers activation
iterations, and the calculus gives no failure result for L-Unload. [Cordis,
pp. 34–38, §4.3.1–§4.3.4]

## Source problems

### Inverse composition in Algorithm 1

The formal semantics is clear that recovery is last-in-first-out. Definition
52 accumulates inverses so that the newest inverse runs first. [Cordis,
pp. 35–36, §4.3.2, Definition 52]

Algorithm 1 defines `f ∘ g` as running `f` after `g`. It then updates
`inverse ← value ∘ inverse`. Under that stated convention, the oldest inverse
runs first. This conflicts with the text that calls the update LIFO. [Cordis,
pp. 55–56, §5.1.1, Algorithm 1, lines 3–7]

This report treats the formal definitions and theorems as authoritative. The
Eta design must not copy Algorithm 1's composition order without resolving
this inconsistency.

### Hot replacement transaction

Algorithm 10 catches module import and swap errors, restores caches, and
rebuilds old entries. The paper then claims that no half-reloaded state is
entered. [Cordis, pp. 65–66, §5.2.2, Algorithm 10]

The algorithm disposes and recreates entries sequentially. The paper does not
define a visibility fence, a commit point, recovery failure, or asynchronous
activation failure for this transaction. External emissions also remain
outside rollback. Therefore, the stated transaction is underspecified.

The Eta design package must define transactional hot replacement separately
from lifecycle confluence.

## Transfer decision for Eta

Eta must transfer the semantic layers, proof assumptions, and observation
boundaries in this report. Eta must not transfer the TypeScript object model as
an implied interface.

The component runtime can interpret ordinary Eta effects during activation and
recovery while `Effect.t` remains `('a, 'err) Effect.t`. Requirements and
provisions remain metadata and state of the component runtime. They do not
become an environment parameter on Eta effects.

This report does not select public types, module names, schedulers, or storage
representations. Later design work must preserve the contracts before it
selects those mechanisms.

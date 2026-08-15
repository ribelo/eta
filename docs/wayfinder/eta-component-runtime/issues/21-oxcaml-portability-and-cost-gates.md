# OxCaml portability and cost gates

Type: prototype
Status: resolved
Blocked by: 06, 15, 18

## Question

Which OxCaml mechanisms improve the selected design, and what portability and
cost gates prevent accidental regressions?

Probe context access, typed-key lookup, inverse registration, notification, and
component-state transitions. Check domain portability, capsule compatibility,
allocation, stack eligibility, and zero-allocation opportunities where the
selected interface permits them.

Optimization cannot change the semantic contract. Record quantitative gates
only after the baseline exists.

## Prototype for review

The comparison prototype is on branch
`prototype/eta-component-oxcaml-cost-gates` at commit `65d0c627`. See the
[prototype source](https://github.com/ribelo/eta/tree/65d0c6273a736e6a1cd472f7011ff738e03f9ae0/.scratch/eta-component-runtime-oxcaml-cost-gates)
and its
[findings](https://github.com/ribelo/eta/blob/65d0c6273a736e6a1cd472f7011ff738e03f9ae0/.scratch/eta-component-runtime-oxcaml-cost-gates/FINDINGS.md).

The compiler probes cover portability, contention, abstraction, local escape,
capsule access, and zero-allocation helpers. The runtime probe records one
allocation baseline for the five named operations.

The provisional recommendation keeps lifecycle authorities owner-domain and
abstract. It uses private zero-allocation checks and package benchmarks. It does
not add public modes, capsules, or unboxed types.

An independent high-tier review found no remaining material fault. Its final
verdict was `ready for human review`.

## Answer

Keep the selected public interface owner-domain and mode-neutral. Use OxCaml
inside the implementation for targeted static and allocation gates.

The user reviewed the prototype and approved this decision.

### Portability and contention

Keep `Context.t`, `Activation.t`, `Coeffect.t`, `Component.t`, diagnostics
authority, and settlement fences abstract without portable mode bounds.

Keep the private `Type.Id` key portable. A provider value is portable only when
its own type permits that use.

Retain the dynamic owner-domain check. A concrete mutable context can cross the
portability axis through mode crossing. The abstract interface rejects that
crossing for safe callers.

Use contention modes only at a real domain adapter seam. The selected design has
no such seam.

Contention modes do not provide atomic transactions, lifecycle ordering,
cancellation, or release.

### Capsules and ownership modes

Do not add capsules to `eta_component`. The installed preview capsule package
permits unique isolated mutation.

It rejects mutation through aliased shared access. Cross-domain mutation needs a
separate synchronization adapter.

The package's blocking synchronization module is deprecated. Its replacement
also introduces a synchronization model that the selected owner-domain runtime
does not need.

Do not add public `unique` or `once` modes. These affine modes can prevent a
second use, but they do not require release.

Eta scope settlement remains the exactly-once release authority.

### Locality and representation

Use local allocation only for synchronous private temporary values. A local
value must not enter:

- an activation effect
- a requirement or provision value that an effect captures
- an Eta scope registration
- a waiter
- a context, snapshot, fence, or loader value.

Do not expose local modes in the public component interface.

Store the internal phase tag separately from its generation identifier. This
representation permits a zero-allocation state transition.

Construct the public diagnostic phase only when the runtime creates an immutable
snapshot.

Do not add unboxed public types. The selected identifiers and counters already
use immediate integers.

### Verification gates

Run the semantic law and reference-model gates before cost gates. An optimization
fails when it changes a trace, cause, settlement result, or fiber census.

Keep compiler probes for these facts:

- The private typed key crosses portability.
- A full coeffect does not cross portability.
- An abstract context authority does not cross portability.
- A contended mutable context does not permit unsynchronized mutation.
- A synchronous temporary permits stack allocation.
- A local activation input does not escape through an effect closure.
- A local release resource does not enter persistent scope storage.
- A capsule permits unique isolated mutation.
- A capsule rejects mutation through aliased shared access.

Add `[@zero_alloc]` to the private owner check, context access, and core state
transition. Do not add `[@zero_alloc assume]`.

When production code exists, add these package benchmark rows:

- `eta_component.context_access`
- `eta_component.key_lookup.hit`
- `eta_component.activation_own.register`
- `eta_component.notification.one_waiter`
- `eta_component.transition`

Require zero allocated words for context access, successful typed-key lookup,
and the core state transition.

Record clean production baselines before setting limits for inverse
registration, notification, or wall time.

Each comparison uses the same machine fingerprint, compiler, profile, and
workload. Three baseline runs define the wall-time noise range.

The prototype allocation counts show feasibility. They are not production
limits for complete Eta effects or scheduler operations.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-oxcaml-cost-gates` at commit `65d0c627`. See the
[prototype source](https://github.com/ribelo/eta/tree/65d0c6273a736e6a1cd472f7011ff738e03f9ae0/.scratch/eta-component-runtime-oxcaml-cost-gates)
and its
[findings](https://github.com/ribelo/eta/blob/65d0c6273a736e6a1cd472f7011ff738e03f9ae0/.scratch/eta-component-runtime-oxcaml-cost-gates/FINDINGS.md).

The prototype records zero allocated words for context access, typed-key lookup,
and component-state transition. It also records the expected heap lifetime for
scope registrations and waiters.

The independent review ended with `ready for human review`. The user then
approved the design.

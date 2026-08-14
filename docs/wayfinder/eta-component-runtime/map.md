# Eta component runtime map

## Destination

A decision-ready Eta-native design package for spatiotemporal components. The
package specifies public interfaces, semantics, laws, package ownership,
prototype evidence, and an implementation sequence for the complete Cordis
system.

## Notes

This effort adapts Cordis semantics to Eta. It does not port the TypeScript
implementation or reproduce its public interface.

`Effect.t` remains `('a, 'err) Effect.t`. Requirements and provisions belong to
the component-runtime seam. This effort does not add an environment channel,
`Layer`, or `provide` operation to Eta effects.

The core belongs in the optional `eta_component` package. Configuration loading
and hot module replacement belong in a separate optional package. The final
package split remains a named decision because source and dependency evidence
can refine these package names.

Keys and values remain statically typed. The design uses the strongest practical
static representation for requirements and provisions that the prototypes
support. Provider availability remains dynamic.

Eta scopes own lexical resources. A component context tracks long-lived
acquisitions, registrations, and child components. Recovery uses observational
equivalence, not physical-state equality.

`Component` means a reusable declaration. `Component instance` means one live
installation. Do not use the paper's term `fiber` for a component instance,
because Eta uses `fiber` for concurrent execution.

The configuration authority is a typed desired-state tree. Serialization and
module-resolution formats use separate adapters. Component-local state does not
survive replacement. State survives only when a longer-lived context or
coeffect owns it.

The semantics remain backend-neutral. Eio is the reference adapter. OxCaml
supplies possible representation and optimization mechanisms. The verification
target includes executable laws, property tests, adversarial lifecycle tests,
and a deterministic reference model.

Primary Cordis sources are:

- `.reference/cordis/paper.pdf`, titled *A Programming Paradigm for
  Spatiotemporal Composability*.
- `.reference/cordis`, the TypeScript implementation at commit
  `8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4`.

Use `$wayfinder`, `$simple-english`, `$codebase-design`, and `$domain-modeling`
for all decision work. Use `$research` for research tickets. Use `$prototype`
for throwaway logic probes. Use `$eio` and `$oxcaml` for their named tickets.

Planning and throwaway prototypes are in scope. Production implementation is
not in scope.

## Decisions so far

- [Cordis semantic contract](issues/01-cordis-semantic-contract.md) — Transfer witnessed recovery, committed provider views, guarded withdrawal, and convergence assumptions, not the recursive context or TypeScript interface.
- [Cordis TypeScript implementation](issues/02-cordis-typescript-implementation.md) — Cordis demonstrates the lifecycle mechanisms, but it does not enforce the paper's inverse, independence, typing, cycle, or rollback laws.
- [Eta substrate and no-R boundary](issues/03-eta-substrate-and-no-r-boundary.md) — Reuse Eta scopes, supervisors, causes, runtime coordination, and observability behind a separate component context.
- [Eio lifetime transfer](issues/04-eio-lifetime-transfer.md) — Eio owns each activation's lexical lifetime, while the component context adds generations, publication, admission fences, and dependency-safe withdrawal.
- [Typed coeffect representations](issues/05-typed-coeffect-representations.md) — Retain portable generative `Type.Id` keys and existential GADT storage, then prototype stronger typed declaration forms.
- [OxCaml lifecycle mechanisms](issues/06-oxcaml-lifecycle-mechanisms.md) — OxCaml modes add static lifetime, ownership, and race checks, but runtime semantics still own lifecycle and cleanup.
- [Native loading and HMR](issues/07-native-loading-and-hmr.md) — Native HMR loads immutable private code generations and replaces declarations transactionally. Only process restart reclaims code.
- [Eta semantic adoption](issues/08-eta-semantic-adoption.md) — Eta adopts conditional observational recovery and confluence with typed total provisions, generation fences, safe withdrawal, cycle rejection, and cause-preserving failure.
- [Component language and seams](issues/09-component-language-and-seams.md) — Public coeffects and four external seams separate component authoring, desired state, context control, and runtime-owned lifecycle coordination.
- [Typed key and coeffect contract](issues/10-typed-key-and-coeffect-contract.md) — Typed schemas over generative `Type.Id` keys bind activation inputs and outputs before existential `Component.t` hides their types.
- [Temporal ownership and recovery](issues/11-temporal-ownership-and-recovery.md) — A public tracked-effect operation adds generation admission while one Eta activation scope owns LIFO recovery and settlement.
- [Component lifecycle and failure](issues/12-component-lifecycle-and-failure.md) — Inertial generations retain complete causes; clean failures retry explicitly, while recovery failures quarantine one instance and degrade its context.
- [Reactive resolution and withdrawal](issues/13-reactive-resolution-and-withdrawal.md) — Immutable provider views and direct episode leases permit dependent-first withdrawal and distinct-provider handoff behind one discoverable slot.
- [Isolation and interception](issues/14-isolation-and-interception.md) — Typed derived contexts combine live interception snapshots with transactional, episode-preserving realm reassignment.
- [Backend-neutral runtime and Eio adapter](issues/15-backend-neutral-runtime-and-eio-adapter.md) — One lexical Eta effect owns private supervisor children. Eio interprets it, normal stop handles deactivation, and cancellation handles interruption.
- [Desired state and reconciliation](issues/16-desired-state-and-reconciliation.md) — Typed stable-ID trees use whole-snapshot admission, global provider fencing, and order-independent reconciliation.

## Not yet specified

- The final public names for loader adapters depend on the module-loading
  decision.

## Out of scope

- An environment parameter on `Effect.t`, Eta layers, or dynamic effect
  provisioning.
- Production implementation of the selected design.
- Automatic or callback-based migration of component-local state.
- Source compatibility with the TypeScript Cordis interface.
- Distributed service brokers, RPC transparency, and cross-process components.
- Sandboxing untrusted native code and operating-system co-design.
- Compensation for irreversible emissions outside the component context.
- Mechanized proofs of the complete paper metatheory.
- Provider package versioning and structural interface compatibility.
- A production JavaScript adapter or JavaScript verification gate.

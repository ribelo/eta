# Public interface alternatives

Type: prototype
Status: resolved
Blocked by: 09, 10, 11, 12, 13, 14, 15, 16, 17, 23

## Question

Which public interface gives Eta the deepest component, context, coeffect,
loader, and HMR modules?

Produce several materially different OCaml interface sketches. Include one
ordinary-value design, one typed declarative design, and the strongest viable
phantom-indexed design from the typed-key prototype.

Compare interface size, compiler errors, inference, separate compilation,
portability, testing, and how much lifecycle knowledge callers must retain.
Use the deletion test and select no interface until the user has reviewed the
alternatives.

## Prototype for review

The comparison prototype is on branch
`prototype/eta-component-public-interface-alternatives` at commit `46077cc0`.
See the
[prototype source](https://github.com/ribelo/eta/tree/46077cc0a51ffe355212e35f93f62ce7367109f3/.scratch/eta-component-runtime-public-interface)
and its
[comparison](https://github.com/ribelo/eta/blob/46077cc0a51ffe355212e35f93f62ce7367109f3/.scratch/eta-component-runtime-public-interface/COMPARISON.md).

The prototype contains three compiling interface sketches:

- Ordinary values with runtime declaration checks.
- Typed requirement and provision schemas.
- Generative modules with declaration rows and context phantoms.

The provisional recommendation prefers typed schemas without public row or
context indices. It keeps explicit context operations and a native-only HMR
adapter seam. This recommendation is not selected.

A high-tier review found no remaining material fault. The review verdict was
`ready for human review`.

## Answer

Select the typed-declaration shape. Use typed requirement and provision schemas
without public declaration rows or context phantoms.

The user reviewed the alternatives and approved this selection.

### Component authoring

`'value Coeffect.t` remains an ordinary typed descriptor with generative key
identity, value equivalence, and optional typed interception.

`'input Requirement.t` resolves one complete activation input. Its public
constructors are `none`, `one`, `intercepted`, `both`, and `map`.

`'output Provision.t` stages one complete activation output. Its public
constructors are `none`, `one`, `both`, and `contramap`.

`'config Component.t` retains only its configuration type. Requirement,
provision, and activation-error types become existential after
`Component.make`.

`Component.make` binds these values while all relationships remain visible:

- A stable typed component family.
- Configuration equivalence.
- One requirement schema.
- One provision schema.
- One activation-error renderer.
- An activation function from configuration, resolved input, and
  `Activation.t` to the complete provision effect.

`Activation.t` exposes only tracked ownership. It exposes no registry, dynamic
lookup, publication operation, context authority, runtime token, or lifecycle
handle.

### Desired state and context control

A typed desired-state entry pairs one component with matching configuration.
Conversion to a tree node hides that type for heterogeneous storage.

Desired-state construction remains pure. It performs no loading, admission,
effect execution, or reconciliation.

`Context.run` owns one lexical context lifetime. It supplies separate context
authority and read-only diagnostics values to its body.

Keep explicit context operations:

- `Context.reconcile`
- `Context.retry`
- `Context.replace`
- `Context.shutdown`

Each accepted operation returns one settlement fence. Each rejected admission
returns a detailed typed error and creates no fence.

Do not combine these operations behind one public `Change.t` sum. That sum
moves names without hiding lifecycle complexity or improving error locality.

### Diagnostics, loading, and HMR

Diagnostics retain the selected snapshot, change-wait, and settlement-report
interface from [Operational lifecycle diagnostics](23-operational-lifecycle-diagnostics.md).

The component core owns replacement admission, fencing, staging, publication,
rollback, and restoration.

A loader orchestration remains outside the component core. It owns source
supersession, immutable operation reports, pre-admission failures, build
revisions, and native artifact residency.

Loader adapters prepare desired state or replacement candidates. The adapter
itself receives no component-context authority.

Native HMR is an adapter package, not a second lifecycle authority. It owns
manifest reading, dependency classification, immutable private loading, and
per-artifact residency.

After native mutation starts, the adapter records each failure and all known
artifact residency in one immutable loader report.

### Static boundary

The selected interface gives compile-time checks for:

- Requirement input types.
- Complete provision output types.
- Component configuration.
- Interception metadata.
- Acquisition and release resource agreement.
- Configuration agreement during static replacement construction.

The selected interface does not claim static provider availability, unique
desired-state IDs, acyclic provider graphs, current candidate freshness, or
successful recovery.

Dynamic replacement still checks stable component identity and the expected
runtime instance incarnation before lifecycle mutation.

### Rejected alternatives

Reject ordinary activation lookup and publication. That design moves
undeclared access, duplicate publication, and incomplete provisions into
asynchronous activation.

It also requires component authors to combine access, acquisition, and
publication errors into one activation-error type.

Reject public requirement rows and six-index component contracts. Heterogeneous
desired-state storage erases the rows before provider resolution.

Reject public context phantoms. They give valid cross-context checks in safe
code, but their index spreads through diagnostics, loading, settlement, and
replacement.

The context still checks dynamic lifetime state because a context can close
while asynchronous work or retained observations remain.

### Depth and caller knowledge

`Component`, `Context`, `Diagnostics`, and `Replacement` pass the deletion test.
Deleting any one moves an Eta-owned protocol into every application and test.

A loader module passes only when it owns source revisions, supersession,
repeatable reports, failures, artifacts, and admission linkage.

A generic core HMR wrapper fails the deletion test. The native adapter package
earns its interface through platform-specific loading and residency behavior.

A component author retains four lifecycle facts:

1. Activation receives one fixed requirement value.
2. `Activation.own` tracks long-lived work.
3. Successful activation returns every provision.
4. Component-local state ends with the generation.

Applications retain lexical context lifetime, admission rejection, settlement
fences, explicit retry, and the possibility of pending shutdown.

Callers do not coordinate provider leases, dependency order, generation
serialization, recovery order, staging, rollback, or cause combination.

### Prototype evidence

The prototype compiled all three interface sketches with OxCaml
`5.2.0+ox`. The selected typed-declaration sketch contains 510 lines.

The ordinary-value sketch contains 492 lines. The phantom-indexed sketch
contains 675 lines. These counts provide orientation only and do not measure
module depth.

The high-tier review ended with `ready for human review`. The user then selected
the typed-declaration shape.

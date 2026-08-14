# OxCaml lifecycle mechanisms

Date: 2026-08-14

## Scope

This report assesses mechanisms in the Eta repository compiler. It does not
select a component interface.

The lifecycle contract remains independent of OxCaml. A backend must still
implement acquisition, ownership transfer, cancellation, rollback, and
exactly-once release.

The repository pins OxCaml source commit
[`7d714cf`](https://github.com/oxcaml/oxcaml/tree/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7).
The Nix shell reports `5.2.0+ox`, `amd64`, `multidomain: true`, and
`stack_allocation: true`.

## Decision summary

OxCaml can reject some lifetime, aliasing, and cross-domain race errors. It
cannot define the component lifecycle or replace its dynamic state machine.

| Mechanism | Classification | Useful scope | Main limit |
| --- | --- | --- | --- |
| `portable` | static safety | Cross-domain callbacks and worker inputs | It does not start, join, cancel, or release work. |
| `contended` and `shared` | static safety | Access to values that domains share | They do not provide atomicity or lifecycle ordering. |
| `local` | static safety | Synchronous temporary views and non-escaping helpers | A component instance or context cannot remain local after its region ends. |
| Stack allocation | optimization only | Short-lived setup data and temporary traversal state | Long-lived contexts, fibers, and domain transfers need heap lifetime. |
| `unique` | static safety | One-owner handoff tokens and destructive terminal operations | A unique value can be dropped, so it does not require release. |
| `once` | static safety | At-most-once callbacks that capture unique values | A once callback can be dropped, so it is not exactly-once cleanup. |
| Capsules | unresolved | Possible isolation of mutable state across domains | The API is external, work in progress, and absent from Eta dependencies. |
| Kinds and modal bounds | static safety | State representation and explicit mode-crossing bounds | Kinds classify types. They do not run lifecycle actions. |
| Mode crossing | static safety | Safe removal of irrelevant mode restrictions | Crossing can make an annotation vacuous for a concrete type. |

No assessed mechanism is **semantic support** for the required lifecycle.
Each backend still needs the same observable transitions and cleanup results.

## Findings

### Portability and contention

`portable` means thread or domain portability. It does not mean serializable or
process-portable data.

The repository compiler provides `Domain.Safe.spawn`. Its argument is a
`portable once` closure. The compiler source says that this closure cannot use
unsynchronized mutable data from the source domain
([`stdlib/domain.mli`, lines 207-268](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/stdlib/domain.mli#L207-L268)).

`contended` tracks mutable data that another domain can access. The compiler
rejects reads and writes that require an `uncontended` value. `shared` permits
reads but rejects unprotected writes. The pinned compiler tests record these
rules
([`portable-contend.ml`, lines 15-90](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/testsuite/tests/typing-modes/portable-contend.ml#L15-L90)).

These modes can protect a cross-domain adapter. They do not protect a logical
transaction that spans multiple atomic operations. A lock, atomics, or
owner-domain protocol must still provide that semantic guarantee.

A `portable` annotation has no special value for ordinary same-domain fibers.
Its cross-domain value appears only when an adapter moves a closure or value
between domains. A value must also meet the receiving API's locality
requirements.

### Locality and stack allocation

`local` is a region lifetime. The type checker rejects a local value that
escapes its region. The pinned compiler test shows this exact rejection for a
returned local reference
([`typing-local/local.ml`, lines 5-16](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/testsuite/tests/typing-local/local.ml#L5-L16)).

Locality does not guarantee stack allocation. It gives the compiler permission
to use the allocation stack. `stack_` requires the marked allocation to use
that stack. Each allocation dies with its region. `exclave_` can allocate a
local result in the caller's region
([stack-allocation reference](https://oxcaml.org/documentation/stack-allocation/reference/)).

A component instance, its context, registrations, and child ownership can
survive the installation call. These values cannot use a callee-local
representation. They also cannot cross a domain through a global closure while
they remain local.

Local allocation can still reduce temporary setup cost. Examples include a
synchronous lookup view or traversal accumulator. The temporary value must not
enter a stored closure, suspended fiber, registration, or long-lived context.

### Uniqueness and once-use values

`unique` tracks the absence of another reference. A consuming function can
reject a second use. A closure that captures a unique value can use the `once`
mode
([pinned uniqueness tests, lines 27-55](https://github.com/oxcaml/oxcaml/blob/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7/testsuite/tests/typing-unique/unique_documentation.ml#L27-L55)).

These modes are affine, not linear. The compiler accepts a function that
discards a `unique` value. It also accepts a function that discards a `once`
closure. Thus, neither mode proves that cleanup runs at least once.

Uniqueness can strengthen an ownership-transfer token. It can also protect a
terminal operation from a second static use. Dynamic aliases, existential
storage, exception paths, cancellation, and backend callbacks still require a
runtime ownership protocol.

`once` is suitable for at-most-once callbacks. It is not suitable as the only
proof for exactly-once release. The lifecycle must handle callback loss,
exceptions, interruption, and races independently.

### Capsules

The official capsule documentation describes branded mutable-state partitions.
An access uses contention safety. A local password uses locality safety. A
unique key uses uniqueness safety. A capsule mutex provides dynamic exclusive
access across domains
([capsule documentation](https://oxcaml.org/documentation/parallelism/capsules/)).

The same documentation calls the expert API current and calls
`Portable.Capsule` work in progress. The capsule API is an external package,
not a compiler `Stdlib` module. Its package metadata describes it as an API for
partitioning mutable data into shareable locations
([Jane Street capsule package](https://github.com/janestreet/capsule)).

The current development switch contains `capsule`, but Eta does not declare
that package as a dependency. A plain repository-compiler probe therefore
reports `Unbound module "Capsule"`.

Capsules remain unresolved for the component runtime. A future design can
assess them for an optional cross-domain backend. That design must include the
package boundary, API maturity, Eio interaction, and lock cancellation
behavior.

Capsules cannot replace lifecycle semantics. A capsule can prevent a data race
while the program still leaks a registration, releases in the wrong order, or
fails to roll back.

### Kinds and mode crossing

Kinds classify runtime layouts and record modal bounds. A bound such as
`value mod portable` states that values of the type can cross the portability
axis. With-bounds propagate restrictions from stored element types
([kind-system documentation](https://oxcaml.org/documentation/kinds/intro/)).

Mode crossing removes a restriction when a type makes that restriction
irrelevant. Data without functions can cross portability. Deeply immutable
data can cross contention. Immediate data can cross locality. The mode-system
documentation gives the complete axis definitions
([mode-system introduction](https://oxcaml.org/documentation/modes/intro/)).

This behavior requires care for component APIs. A plain immutable identifier
can cross many axes, so its strong-looking mode annotation can add no ownership
fact. An abstract type with a conservative kind can prevent unwanted crossing.

Kinds can improve representation and can expose cross-domain constraints in a
signature. They do not give state transitions, cleanup order, failure
aggregation, or cancellation behavior.

## Lifetime and domain matrix

| Value | Same call region | Stored after return | Same-domain fiber | Other domain |
| --- | --- | --- | --- | --- |
| Local temporary | yes | no | only without escape or suspension | no through a global transfer closure |
| Global component context | yes | yes | yes, with runtime synchronization as required | only through a safe transfer protocol |
| `portable` closure | yes | yes if global | yes | yes, with captured values treated by contention rules |
| `unique` token | yes | yes if global | yes, if ownership moves once | one destination can consume the token |
| Capsule password | yes | no, because it is local | only within its dynamic local use | no |
| Capsule key | yes | yes | yes | one destination can receive it uniquely |
| Capsule mutex | yes | yes | yes | yes, with dynamic locking |

The capsule rows describe the current official API model. They do not approve
that API for Eta.

## Compiler probes

The probes ran in the repository Nix shell with `ocamlc 5.2.0+ox`.
The durable [compiler-probe bundle](06-oxcaml-lifecycle-mechanisms/README.md)
contains the sources, runner, exact results, and toolchain output.

The recorded bundle command is:

```sh
env XDG_CACHE_HOME=/tmp/eta-nix-cache nix develop -c bash \
  .scratch/research/eta-component-runtime/06-oxcaml-lifecycle-mechanisms/run.sh
```

The positive probe compiled:

```ocaml
type context = { mutable state : int }
let consume : context @ unique -> unit = fun _ -> ()
let delayed (x @ unique) : (unit -> unit) @ once =
  fun () -> consume x
let cross_portable (type a : value mod portable)
    (x : a @ nonportable) : a @ portable = x
let local_read n =
  let local_ r = ref n in
  !r
let spawn f = Domain.Safe.spawn f
```

Negative probes produced these diagnostics:

| Probe | Diagnostic |
| --- | --- |
| Return `let local_ r = ref n` | `This value is "local" ... because it is a function return value.` |
| Mark a closure that mutates a captured ref `portable` | `This value is "nonportable" ... expected to be "portable".` |
| Mutate a record argument at `contended` | `This value is "contended" ... expected to be "uncontended".` |
| Consume one `unique` abstract value twice | `it has already been used as unique` |
| Call one `once` closure twice | `it is defined as once and has already been used` |
| Use `Capsule.create` without an external package | `Unbound module "Capsule"` |

This probe compiled and shows the exactly-once limit:

```ocaml
type context
let drop_unique (_x : context @ unique) = ()
let drop_once (_f : (unit -> unit) @ once) = ()
```

## Consequences for later design work

1. Specify lifecycle states and laws without OxCaml modes.
2. Apply `portable` and contention constraints only at a real domain boundary.
3. Keep component instances and contexts global.
4. Use local allocation only for proven synchronous temporary data.
5. Treat `unique` and `once` as extra static checks, not cleanup semantics.
6. Reassess capsules only after the runtime seam and package boundary exist.
7. Use kind bounds to state representation facts, not lifecycle laws.

## Unresolved questions

- Will the selected runtime have a cross-domain adapter, or only same-domain
  Eio fibers?
- Can a useful ownership token remain unique through existential registries and
  effect descriptions?
- Which capsule package version matches the pinned compiler and the future Eta
  package boundary?
- How does capsule locking report interruption and poisoning to typed Eta
  failures?
- Which temporary setup paths are hot enough to justify stack-allocation
  constraints?

These questions do not block backend-neutral lifecycle specification.

## Sources

- OxCaml source pinned by `flake.lock`, commit
  [`7d714cf`](https://github.com/oxcaml/oxcaml/tree/7d714cfb3f1c79c9b1e2a9c40ac60ba0c44cafd7).
- OxCaml, [Introduction to the Mode System](https://oxcaml.org/documentation/modes/intro/),
  accessed 2026-08-14.
- OxCaml, [Modes Reference](https://oxcaml.org/documentation/modes/reference/),
  accessed 2026-08-14.
- OxCaml, [Stack Allocation Reference](https://oxcaml.org/documentation/stack-allocation/reference/),
  accessed 2026-08-14.
- OxCaml, [Introduction to Uniqueness](https://oxcaml.org/documentation/uniqueness/intro/),
  accessed 2026-08-14.
- OxCaml, [The Kind System](https://oxcaml.org/documentation/kinds/intro/),
  accessed 2026-08-14.
- OxCaml, [Capsules](https://oxcaml.org/documentation/parallelism/capsules/),
  accessed 2026-08-14.
- Jane Street, [`capsule`](https://github.com/janestreet/capsule), accessed
  2026-08-14.

# Typed coeffect representations

Status: complete

## Question

Which OCaml and OxCaml representations can give Eta statically typed coeffect
keys and practical component declarations?

This report narrows the candidates. It does not select the final public
interface.

## Constraints

The following constraints are binding:

- `Effect.t` remains `('a, 'err) Effect.t`.
- A key and its value type must have a static relation.
- Provider availability remains a runtime fact.
- Requirement and provision declarations must preserve as much static
  information as later prototypes can use.
- A key representation must not prevent use across OxCaml domains.

Eta already passes application dependencies as ordinary values. Runtime
services do not form an application environment [E1, E2]. The no-`R` evidence
also rejects object-row environments because they are nonportable [E2, E3].

## Result

Retain these candidates for prototypes:

1. Use a generative typed key with the shape `'a key`.
2. Back each key with `Type.Id.t`, or with an equivalent private witness.
3. Store a binding as an existential GADT that keeps one key beside one value.
4. Use a GADT for typed declaration entries and heterogeneous internal storage.
5. Consider functors or module signatures only at a static assembly boundary.

This family keeps value typing static and provider availability dynamic.
Lookup has the shape `'a key -> store -> 'a option` or a typed installation
error. It does not add an environment parameter to `Effect.t`.

`Type.Id` is the strongest existing base candidate. Its public API supplies a
fresh identifier, a runtime identifier, and a proof of type equality [O1].
The standard-library example implements the required heterogeneous dictionary
without `Obj` [O1]. Eta already uses this exact pattern for runtime-local and
service bindings [E4].

Do not retain object rows or polymorphic-variant rows as the key system.
They identify requirements by structural names, not by generative identity.
Object values also fail the current OxCaml portable boundary [P4].

Do not use first-class modules as the primary stored key. They add package and
unpack syntax without improving lookup. Current OxCaml also rejects an
unconstrained first-class module at a portable boundary [P5].

## Required distinction

Three properties are separate:

- **Value typing:** a key of type `'a key` accepts only values of type `'a`.
- **Key identity:** two key values can be different, even when both carry the
  same value type.
- **Availability:** a provider for a key can be absent at runtime.

`Type.Id.make ()` creates the second property [O1]. The type parameter gives
the first property. An `option` or typed installation error gives the third
property.

The key does not prove that a provider exists. This limit is intentional.
Dynamic component installation cannot preserve a closed, compile-time provider
set without changing the problem into static module assembly.

## Requirement and provision declarations

The prototypes must not start with an untyped name map. They must compare three
levels of static declaration:

1. An existential entry list preserves the type of each key and provision
   value. Packaging then hides the complete set type.
2. A typed GADT spine can preserve a phantom type for the complete declaration.
   A provision spine can relate each key to its value.
3. A module signature can preserve an exact static subsystem contract.

The GADT spine is the strongest candidate for a dynamic component declaration.
It can enter a mixed runtime registry through one controlled existential
package. The prototype must determine whether its extra set type improves
diagnostics without making declaration inference impractical.

The module signature is stronger for a fully static subsystem. It is not a
replacement for runtime provider checks. Structural object or variant rows
also retain set information, but their key identity violates the constraints.

This ticket does not select one declaration level. Later prototypes must use
the strongest level that passes the inference and diagnostic gates.

## Comparison

The “declaration strength” column measures retained static information.
It does not mean that the compiler proves runtime availability.

| Representation | Typed key and value | Dynamic heterogeneous lookup | Separate compilation | Identity | Inference and errors | Domain portability | Declaration strength | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Generative typed key | Yes, through `'a key` | Yes, with an existential binding | Good. A library exports a typed key value | Fresh value identity. Equal payload types can use different keys | Local key/value mismatches. A key definition needs a payload annotation [P2] | The `Type.Id` key crosses portability [P3]. Stored values remain type-dependent | Each entry remains typed. The whole dynamic set stays open | Retain as the primary candidate |
| GADT | Yes. A constructor can fix its result type [O2] | Yes. Existentials hide each payload and matching restores constraints [O2] | Good for a closed GADT. Open extension needs an extensible GADT | Constructor identity is nominal. A plain closed GADT is not generative per key value | Recursive consumers often need locally abstract types. GADT inference needs annotations [O2] | A data-only GADT can cross. A packed payload follows its payload type [X1] | Can encode typed entries and heterogeneous lists | Retain as a support mechanism |
| Extensible variant or extensible GADT | Yes when the extension constructor fixes the index | Possible, but equality logic must recognize later constructors | Good for adding constructors in other units [O3] | Nominal constructor identity. A normal declaration is not fresh per value | Unknown constructors require a default case, which moves misses to runtime [O3] | Constructor payloads remain type-dependent. Package interaction has an OxCaml warning [X3] | Open declaration vocabulary, but no closed satisfaction proof | Retain only for a prototype comparison |
| First-class module | Yes when a package exposes a type and related values | Yes after existential packing and unpacking | Good with named package types and explicit constraints [O4] | An abstract package type is nominal. Package values are not fresh identities | Package constraints are verbose. OCaml 5.2 functions cannot return a type that depends on a runtime package [O4] | An unconstrained package fails the current portable boundary [P5] | Strong inside one package. Packing hides relationships from a mixed collection | Do not use as the primary key |
| Object and object row | A method name can return a typed value | An object can expose a structural requirement row | Structural rows compose across units | Structural method names are global identities, not generative identities | Rows infer well in small code. Missing methods can produce large row errors [E3, O5] | Object values fail the current portable boundary [P4] | Strong structural requirement sets | Reject under the no-`R` constraint |
| Polymorphic variant row | A tag can carry one declared payload type | A tagged existential protocol is possible, but lookup still needs witnesses | Rows compose across units without a central declaration | Tags use structural names. They are not fresh key identities [O6] | Flexible inference can admit misspelled tags until an annotation [O6] | Data-only values can cross, subject to their payloads [X1] | Strong structural tag sets, but weak nominal key discipline | Reject as the key system |
| Functor | A signature can relate abstract types and values | The resulting runtime still needs another lookup representation | Excellent. OCaml modules are static composition units [O7] | `Make ()` creates fresh result types [O8] | Errors occur at application. Signatures improve locality but add module syntax | Portable functor interfaces need explicit OxCaml treatment. Module-mode support is not ready for broad use [X2] | Strongest static assembly contract | Retain only at a static boundary |
| Existential package | Yes inside `Binding : 'a key * 'a -> binding` | Yes. This is the standard heterogeneous-store technique [O1, O2] | Good when constructors stay private behind typed operations | It preserves the identity supplied by the enclosed key | Internal consumers need locally abstract types. Public callers see simple operations | The package is portable only when its hidden payload is portable [X1] | Preserves each entry, but hides the set after packing | Retain as the storage mechanism |
| Type witness | Yes. Matching an equality witness refines two types [O1, O2] | Yes when the witness also has runtime identity | Depends on witness construction. A closed witness universe is not extensible | A singleton witness names a type, not necessarily one key instance | Equality matching is local. Witness construction can require annotations | A data-only witness can cross portability [X1] | Good for typed codecs and diagnostics. It does not model availability | Retain inside the key implementation |

## Representation details

### Generative typed keys

A practical core has these conceptual types:

```ocaml
type 'a key
type binding = Binding : 'a key * 'a -> binding

val create : unit -> 'a key
val find : 'a key -> store -> 'a option
```

The implementation compares runtime identity. A successful comparison returns
a type-equality proof. Pattern matching on that proof makes the stored value
available at the requested type [O1].

This representation gives local errors. `add database_key logger store` fails
at the call when `database_key` and `logger` have different payload types.
An unavailable provider still fails during installation or lookup.

Two calls to `create` can produce two keys for the same payload type. Therefore,
the payload type does not become the key identity. This property prevents
same-shape service collisions.

The standard-library key value is immutable data in OxCaml [O9]. The compiler
probe also accepts its conversion from `nonportable` to `portable` [P3].
This result applies to the key. It does not apply to an arbitrary provider
value stored beside the key.

### GADTs, existential packages, and type witnesses

These three representations solve related parts of one problem.

- A GADT relates a constructor to a result type.
- An existential package hides different payload types in one collection.
- An equality witness safely restores a hidden type after identity comparison.

The OCaml manual documents all three operations [O2]. `Type.Id` combines them
with a fresh runtime identity [O1, O9].

A GADT alone does not create fresh key identities. For example, one
`Database : database key` constructor gives one nominal key. A key factory
needs a generative witness or a generative module.

An extensible GADT permits independent units to add key constructors [O3].
However, the central equality function cannot enumerate future constructors.
It must use attached witness logic or another generative identity mechanism.
Thus, extensibility does not replace `Type.Id`.

### First-class modules and functors

First-class modules can pack a key, its payload type, and operations as one
runtime value [O4]. Unpacking introduces a fresh abstract type unless the
package carries an explicit type equation.

This abstraction is useful for plugins with several related operations.
It is excessive for one typed key. A mixed collection hides the payload type
again, so lookup still needs an existential and an equality witness.

Generative functors produce fresh abstract result types for each `Make ()`
application [O8]. This property gives strong static isolation. It also makes
key sharing require shared module paths or explicit module transport.

Functor signatures can describe complete static requirements and provisions.
They cannot prove availability for components selected at runtime. A prototype
can use them around a static subsystem, but not as the only component registry.

### Objects and object rows

An object type is a structural record of methods. An open object type contains
a row variable for additional methods [O5]. This feature can express a static
requirement set with concise projections.

It does not give generative key identity. Independent libraries that select the
same method name and type silently select the same structural slot. Different
names for the same service require adapters.

The representation also conflicts with accepted Eta evidence. The no-`R`
experiments found weak variables, dense row errors, and nonportable objects
[E2, E3]. The current compiler probe reproduces the portability error [P4].

### Polymorphic variants

Polymorphic variant tags do not belong to one declared type. The compiler
infers a row independently from each use [O6]. This gives convenient open
requirement sets.

The same feature weakens key discipline. A tag is a structural name, not a
fresh identity. The manual also shows that a misspelled tag can type-check
until a closed annotation exposes the error [O6].

Polymorphic variants remain suitable for Eta's typed error channel. They are
not suitable as the primary coeffect-key identity.

## Separate compilation

The retained key design works across compilation units:

1. A provider library exports `val key : service key`.
2. A consumer imports that exact value and requests `service`.
3. The registry stores `Binding (key, value)` existentially.
4. Lookup compares the imported key with the stored key.

OCaml compiles each implementation against its interface [O7]. The interface
fixes the payload type and hides the key representation.

A bare definition `let key = Type.Id.make ()` does not compile as a unit.
The application result has a weak payload variable [P1]. A declaration must
fix the payload type, as `let key : service Type.Id.t = Type.Id.make ()` does
[P2]. This annotation is desirable because it puts an incorrect key type at
the key declaration.

First-class package constraints also cross units, but package syntax exposes
more module machinery [O4]. Structural rows cross units, but they do not solve
nominal identity.

## Inference, errors, and the value restriction

The retained public operations permit ordinary local inference:

```ocaml
val provide : 'a key -> 'a -> provision
val require : 'a key -> requirement
val get : 'a key -> context -> 'a option
```

The key fixes `'a` at each call. Internal GADT consumers need an explicit
locally abstract type. This annotation remains inside the registry.

The value restriction affects generated key values. Function application can
leave weak type variables, and weak variables cannot escape a compilation unit
[O10]. The negative compiler probe confirms this behavior [P1].

The fix is a payload annotation, not eta-expansion. Eta-expansion creates a new
identity on each call. That behavior is wrong for a stable exported key.

Objects and row variants infer wider structural requirements. Their error can
occur only when a later closed annotation rejects the inferred row [O6].
GADT errors can mention generated existential names [O2]. A small public
surface must keep these forms behind `provide`, `require`, and `get`.

## Domain portability

OxCaml permits only portable values to cross domain boundaries. Portability is
deep, and most data types without functions cross the portability axis [X1].

The following boundaries are important:

- A `Type.Id.t` key is immutable data and crosses portability [O9, P3].
- An object value does not cross portability in the current compiler [P4].
- A general first-class module does not cross portability in the current
  compiler [P5].
- An existential binding with an arbitrary payload cannot promise portability.
- A binding can cross only when its payload meets the required mode or kind.
- Registry ownership can remain on one domain while portable keys cross to
  domain workers.

These facts do not require every service value to be portable. They require
the API to state the boundary. A later prototype must compare an owner-domain
registry with a registry that restricts provider payloads to portable kinds.

OxCaml states that support for module modes is not ready for broad use [X2].
Its mode reference also reports a current soundness problem for extension
constructors inside first-class modules [X3]. Do not use that combination for
a portability guarantee.

## Prototype gates

Later prototypes must compare at least these candidates:

1. `Type.Id` keys with private existential GADT bindings.
2. An extensible GADT key vocabulary.
3. A module-signature or functor declaration at a static assembly boundary.

Each prototype must make sure that:

- A key cannot accept a value of the wrong type.
- Two keys for the same payload type remain distinct.
- Independent compilation units can share one key.
- Missing providers produce a local installation diagnostic.
- A heterogeneous registry returns a value without public `Obj`.
- Requirement and provision declarations retain their typed key values.
- Key values pass the OxCaml portable boundary.
- provider values either pass that boundary or stay owner-domain values.

The prototypes must also measure declaration error size. They must not add an
environment parameter to `Effect.t`.

## Unresolved compiler questions

The sources leave these questions for later prototypes:

1. Can a useful first-class package receive a stable portable signature after
   OxCaml module-mode support becomes ready?
2. Which public kind bound best expresses a registry restricted to portable
   provider values in Eta's pinned compiler?
3. Does an extensible-GADT design remain portable when an extension carries
   diagnostic functions or codecs?
4. Can a typed heterogeneous declaration preserve useful tuple or list
   inference without exposing existential annotations?

These questions affect candidate ergonomics and domain placement. They do not
change the current no-`R` constraint.

## Compiler probes

The probe bundle is in
[`05-typed-coeffect-representations/`](05-typed-coeffect-representations/README.md).
The repository Nix shell ran all probes with OCaml `5.2.0+ox`.

- [P1] `type_id_value_restriction.ml` fails with a non-generalizable weak
  variable.
- [P2] `type_id_annotated.ml` compiles.
- [P3] `portability_type_id.ml` compiles.
- [P4] `portability_object.ml` fails because the object is nonportable.
- [P5] `portability_package.ml` fails because the package is nonportable.

## Sources

### OCaml and standard library

- [O1] OCaml 5.2 library, [`Type.Id`](https://ocaml.org/manual/5.2/api/Type.Id.html).
  This page specifies fresh keys, equality proofs, and a heterogeneous
  dictionary.
- [O2] OCaml manual,
  [Generalized algebraic datatypes](https://ocaml.org/manual/5.4/gadts-tutorial.html).
  This chapter specifies constraints, existentials, equality witnesses,
  inference limits, and error names.
- [O3] OCaml manual,
  [Extensible variant types](https://ocaml.org/manual/5.4/extensiblevariants.html).
  This section specifies independent extensions and required default cases.
- [O4] OCaml 5.2 manual,
  [First-class modules](https://ocaml.org/manual/5.2/firstclassmodules.html).
  This section specifies package constraints and runtime unpacking limits.
- [O5] OCaml manual,
  [Object types](https://ocaml.org/manual/5.4/types.html#ss:object-types).
  This section defines open object rows and their structural method sets.
- [O6] OCaml manual,
  [Polymorphic variants](https://ocaml.org/manual/5.4/polyvariant.html).
  This chapter specifies inferred rows and documents weaker error discipline.
- [O7] OCaml manual,
  [Compilation units](https://ocaml.org/manual/5.4/compunit.html).
  This chapter specifies interfaces and separate compilation.
- [O8] OCaml manual,
  [Generative functors](https://ocaml.org/manual/5.4/generativefunctors.html).
  This section specifies fresh result types from unit functors.
- [O9] OxCaml standard-library source,
  `stdlib/type.mli` and `stdlib/type.ml` in compiler package
  `oxcaml-compiler.5.2.0minus31`. The interface declares `Type.Id.t` as
  `immutable_data` and portable. The implementation uses a private extensible
  GADT constructor.
- [O10] OCaml manual,
  [The value restriction](https://ocaml.org/manual/5.4/polymorphism.html#ss:valuerestriction).
  This section specifies weak variables and compilation-unit rejection.

### OxCaml

- [X1] OxCaml,
  [Modes introduction](https://oxcaml.org/documentation/modes/intro/).
  This page specifies deep portability and mode crossing.
- [X2] OxCaml,
  [Mode syntax](https://oxcaml.org/documentation/modes/syntax/).
  This page states the current status of module-mode support.
- [X3] OxCaml,
  [Mode reference](https://oxcaml.org/documentation/modes/reference/).
  This page documents the first-class-module extension-constructor warning.

### Eta evidence

- [E1] [`docs/wayfinder/eta-component-runtime/map.md`](../../../docs/wayfinder/eta-component-runtime/map.md).
- [E2] [`docs/zio-boundaries.md`](../../../docs/zio-boundaries.md).
- [E3] [No-`R` verdict](../envless-verdict-2026-07-26.md).
- [E4] `lib/eta/runtime_contract.ml` and `lib/eta/runtime_contract.mli`.
  These files use `Type.Id`, existential bindings, and equality proofs for
  current runtime services.

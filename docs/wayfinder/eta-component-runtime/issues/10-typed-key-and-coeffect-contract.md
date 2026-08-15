# Typed key and coeffect contract

Type: prototype
Status: resolved
Blocked by: 05, 08, 09

## Question

Which typed-key and declaration model gives Eta statically typed values,
generative key identity, useful compiler errors, and practical dynamic lookup?

Build small competing OCaml or OxCaml prototypes. Include separate compilation,
heterogeneous storage, provider registration, consumer access, existential
component storage, and a missing or mismatched dependency. Show compiler
rejections where the contract is static.

The prototype must determine how requirements and provisions appear in
`Component.t`. It can reject the three-parameter sketch from the original idea.

## Answer

Use generative `Type.Id` keys, typed requirement and provision schemas, and an
existential `Component.t`.

### Coeffect contract

`'a Coeffect.t` is the owner-domain contract descriptor for values of type
`'a`. It contains:

- one fresh `'a Coeffect.Key.t` identity backed by `Type.Id`.
- one diagnostic name that does not participate in identity.
- one equivalence function for values of type `'a`.

The value type defines the observable operations. The equivalence function
defines when two results from those operations are equal for recovery laws.

`Coeffect.Key.t` is immutable and portable. The full `Coeffect.t` stays on the
owner domain because its equivalence function is a closure. Provider values
remain portable only when their own types permit this.

`Coeffect.create` creates one fresh identity. An exported coeffect definition
must fix its payload type:

```ocaml
let coeffect : logger Coeffect.t =
  Coeffect.create ~name:"logger" ~equivalent ()
```

Two coeffects can have the same payload type and different identities. This
case remains a runtime identity distinction. Registration under the wrong
same-typed key leaves the required key unavailable.

The registry uses a private existential binding:

```ocaml
type binding = Binding : 'a Coeffect.t * 'a -> binding
```

Registration rejects a value with the wrong payload type. Lookup compares the
stored `Type.Id` and uses its equality witness to recover the payload type. The
public interface does not use `Obj`.

### Typed declarations

`'a Requirement.t` describes a fixed set of coeffects and resolves them into
one value of type `'a`. Its core constructors are:

```ocaml
val one : 'a Coeffect.t -> 'a Requirement.t
val both :
  'a Requirement.t ->
  'b Requirement.t ->
  ('a * 'b) Requirement.t
val map : ('a -> 'b) -> 'a Requirement.t -> 'b Requirement.t
```

`'a Provision.t` describes a fixed set of coeffects and stages one value of
type `'a` under those keys. Its core constructors are:

```ocaml
val one : 'a Coeffect.t -> 'a Provision.t
val both :
  'a Provision.t ->
  'b Provision.t ->
  ('a * 'b) Provision.t
val contramap : ('b -> 'a) -> 'a Provision.t -> 'b Provision.t
```

`none` represents an empty declaration in each module. `map` and `contramap`
let component authors use named records instead of nested tuples.

The runtime resolves a complete requirement value before activation. It does
not give activation code a registry or a lookup function. Thus, activation
code can access only its declared input.

The activation returns one complete provision value. The provision schema
stages every declared output from this value. An activation cannot omit one
declared provision or stage an undeclared provision through this interface.

Provider availability remains dynamic. A missing exact key prevents activation
and produces an installation diagnostic.

### Component shape

The conceptual representation is:

```ocaml
type t =
  | Component : {
      requirements : 'requirements Requirement.t;
      provisions : 'provisions Provision.t;
      activate :
        'requirements ->
        Activation.t ->
        ('provisions, 'error) Effect.t;
    } -> t
```

`Activation.t` is the later lifecycle ticket's narrow tracked-work interface.
It does not expose dynamic coeffect lookup.

`Component.make` checks the relationships while all types remain visible. It
also rejects duplicate requirement keys, duplicate provision keys, and a key
that occurs in both schemas. It returns a typed declaration error for these
cases. It then hides the requirement, provision, and error types in
`Component.t`. This shape permits heterogeneous component and desired-state
storage.

The public component type therefore has no requirement, provision, or error
parameters. Reject the original three-parameter component type. Its parameters
would expose declaration details after the runtime needs to hide them.

This design does not change `Effect.t`. Dependencies remain ordinary values
that the component runtime supplies to the activation function.

### Rejected alternatives

An open existential declaration list keeps each key and value typed. However,
it detects undeclared access and incomplete provisions only at runtime.

An extensible GADT gives nominal constructors but not runtime-generative key
values. Generic heterogeneous lookup must know each extension or add another
identity witness. Adding `Type.Id` again gives more syntax without a stronger
contract.

A functor can enforce a closed static subsystem contract. It cannot represent
dynamic provider availability. Packing the resulting modules also hides the
relationships that dynamic component storage needs.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-typed-key-contract` at commit `fe2d2171`. See the
[prototype source](https://github.com/ribelo/eta/tree/fe2d2171300030335d62a3c1be02af3b6dabd6aa/.scratch/eta-component-runtime-typed-keys).

The OxCaml gate compiled separate units, heterogeneous storage, typed schemas,
and the portable key probe. Expected compiler failures showed:

- a wrong provider value fails at the `provide` call.
- undeclared typed access fails at the missing record field.
- an incorrect provision result fails at the activation result.
- an incorrect static provider module fails at functor application.
- the full coeffect descriptor cannot cross a portable boundary.

The executable also showed runtime diagnostics for missing providers, distinct
same-typed keys, undeclared dynamic access, and incomplete dynamic provisions.

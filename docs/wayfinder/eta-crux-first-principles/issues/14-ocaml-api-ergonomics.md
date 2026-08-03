# OCaml API syntax and ergonomics

Type: prototype
Status: resolved
Blocked by: 03, 04, 05, 07, 08, 11

## Question

What does ordinary Eta Crux application code look like after the semantic API
is known?

Build the same small dynamic application with the viable styles:

- plain functions and labeled arguments.
- `let*` and `let+` syntax over computations.
- local modules, first-class modules, or generative functors.
- a narrow PPX only where normal OCaml cannot express acceptable syntax or
  diagnostics.

Include local state, two independent child instances, a dynamic branch, keyed
children, one staged effect, one source, and typed root output. Compare inferred
signatures, compiler errors, source locations, refactor behavior, and generated
code.

Prototype a clear surface for the two-phase source producer, spec equality,
changing mappers, terminal outcomes, and the target endpoint. Keep readiness in
the type structure instead of an application callback. Compare the rank-2
emitter record with any equally precise, simpler syntax.

Also fix the exact surface for `Endpoint.admission_error`, explicit handling in
typed-infallible staged effects, `Post_commit.start_result`, crash detection,
and final settlement. Include packed causes, trigger kinds, diagnostic snapshots,
and identity fields. The API must expose no public root typestate.

Use OCaml strengths rather than reproducing another language's syntax. Do not
make a PPX part of V1 unless the prototype shows a concrete semantic or
diagnostic advantage.

## Answer

### Application style

Eta Crux uses normal OCaml functions, modules, labeled arguments, and binding
operators. V1 has no PPX.

The computation algebra keeps its plain functions:

```ocaml
type 'a t
type never = |

val return : 'a -> 'a t
val map : 'a t -> f:('a -> 'b) -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val cutoff : 'a t -> equal:('a -> 'a -> bool) -> 'a t
val bind : 'a t -> f:('a -> 'b t) -> 'b t
```

`Eta_crux.Syntax` gives local syntax for these same operations:

```ocaml
module Syntax : sig
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
  val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
end
```

Applications use `let+` and `and+` for fixed applicative structure. They use
`let*` only when a value selects dynamic structure.

Applications open `Eta_crux.Syntax` locally. Eta Crux does not add global
operators or replace the plain functions.

Binding syntax expands to direct operator calls. It keeps compiler source
locations and generates no PPX code.

### Names and constructors

An action is the typed input of one cell transition. A message is the runtime
or boundary envelope that carries an action or an internal root event.

A model is the application value that one cell owns. State is the general name
for runtime state or aggregate application state.

Ordinary functions construct reusable children. A constructor call creates one
description-node identity.

State machines use a module constructor with one positional input:

```ocaml
module State_machine : sig
  val create :
    ?equal:('model -> 'model -> bool) ->
    ?diagnostics:('model, 'action) Diagnostic.state_machine ->
    'input t ->
    default_model:'model ->
    apply_action:
      (self:'action Endpoint.t ->
       input:'input ->
       model:'model ->
       action:'action ->
       'model * (unit, never) Eta.Effect.t) ->
    ('model * 'action Endpoint.t) t
end
```

The positional input erases the preceding optional arguments. Thus, callers do
not need a final `()` or an explicit absent optional argument.

`apply_action` keeps labeled arguments because the values have several distinct
roles. It returns the immutable next model and one staged Eta effect.

The lifecycle constructor remains:

```ocaml
val lifecycle : (unit, never) Eta.Effect.t t -> unit t
```

Keyed applications use the selected map functor:

```ocaml
module Assoc (M : Map.S) : sig
  val assoc :
    ?data_equal:('data -> 'data -> bool) ->
    'data M.t t ->
    f:(key:M.key -> data:'data t -> 'result t) ->
    'result M.t t
end
```

A local `module Items = Assoc (Item_map)` keeps the dependent map type clear.
First-class map modules cannot return `M.t` without existential escape.

Generative application functors add no useful identity. Description nodes and
structural scopes already define identity.

### Endpoint admission and staged effects

The endpoint surface is:

```ocaml
module Endpoint : sig
  type 'message t
  type admission_error = Ingress_closed

  val send :
    'message t ->
    'message ->
    (unit, admission_error) Eta.Effect.t

  val contramap :
    'target t ->
    f:('source -> 'target) ->
    'source t
end
```

A typed-infallible staged effect must handle `Ingress_closed` explicitly. Eta
Crux adds no helper that discards this error.

For example, an application can fold the admission result into the empty error
channel:

```ocaml
let handle_admission send_effect =
  Eta.Effect.fold
    ~ok:Fun.id
    ~error:(function Endpoint.Ingress_closed -> ())
    send_effect
```

The compiler rejects a direct `Endpoint.send` where `(unit, never)
Eta.Effect.t` is required.

### Source surface

The source producer uses a labeled emitter closure:

```ocaml
module Source : sig
  type 'error terminal =
    | Completed
    | Failed of 'error

  type 'item emit =
    'item ->
    (unit, Endpoint.admission_error) Eta.Effect.t

  type ('item, 'error) producer =
    emit:'item emit ->
    ((unit, 'error) Eta.Effect.t, 'error) Eta.Effect.t

  val create :
    spec_equal:('spec -> 'spec -> bool) ->
    spec:'spec t ->
    producer:('spec -> ('item, 'error) producer) t ->
    target:'action Endpoint.t t ->
    on_item:('item -> 'action) t ->
    on_terminal:('error terminal -> 'action) t ->
    unit t
end
```

The outer effect is the opening phase. Its success value is the long-lived
producer effect. Therefore, readiness stays in the nested type.

`spec` and `spec_equal` control producer continuity. The producer factory,
target, item mapper, and terminal mapper are changing computation values.

Committed mapper changes do not restart the producer. A new active interval
samples the latest committed producer factory and spec.

The rank-2 emitter alternative adds a phantom scope, a record field, and
explicit polymorphism. It prevents no invalid lifetime use.

The labeled closure has the same authority and error precision with less
syntax. Eta Crux therefore does not expose the rank-2 record.

### Diagnostics and packed causes

Diagnostic hooks return redacted values:

```ocaml
module Diagnostic : sig
  type snapshot = {
    summary : string;
    fields : (string * string) list;
  }

  type ('model, 'action) state_machine = {
    model : 'model -> snapshot;
    action : 'action -> snapshot;
  }
end
```

Eta Crux calls these hooks only for failure diagnostics. Raw models and actions
do not enter failure reports.

The packed cause surface keeps the original same-domain cause and its error
printer:

```ocaml
module Failure : sig
  module Packed_cause : sig
    type t

    val make :
      pp_error:(Format.formatter -> 'error -> unit) ->
      'error Eta.Cause.t ->
      t

    val portable : t -> string Eta.Cause.Portable.t
    val pp : Format.formatter -> t -> unit
  end
end
```

`portable` renders the hidden typed failures as strings. It preserves the
portable Eta cause tree.

The remaining types also stay inside `Failure`. Its identity modules expose
comparison and formatting:

```ocaml
module Cell_id : sig
  type t
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Endpoint_id : sig
  type t
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Observation_position : sig
  type t
  val compare : t -> t -> int
  val to_int64 : t -> int64
end
```

The public classification stays detailed:

```ocaml
type origin =
  | Transition
  | Owned_work
  | Adapter_delivery
  | Export_dispatch
  | Cleanup
  | Crash_handler

type trigger_kind =
  | Initial_start
  | Endpoint_message
  | Transition_effect
  | Lifecycle_program
  | Source_opening
  | Source_producer
  | Local_export_invocation
  | Serialized_export_invocation
  | Output_delivery
  | Stop_teardown
  | Crash_teardown
  | Application_crash_handler
```

`origin` identifies the boundary that observed the cause. `trigger_kind`
identifies the operation that was active at that boundary.

The complete failure values are:

```ocaml
type record = {
  cause : Packed_cause.t;
  origin : origin;
  cell : Cell_id.t option;
  endpoint : Endpoint_id.t option;
  trigger : trigger_kind;
  position : Observation_position.t;
  action_snapshot : Diagnostic.snapshot option;
  model_snapshot : Diagnostic.snapshot option;
}

type t = {
  primary : record;
  secondary : record list;
}

type settlement = {
  failure : t;
  teardown_settled : bool;
}
```

### Advancement and settlement

`Post_commit.start` keeps batch admission and terminal settlement distinct:

```ocaml
module Post_commit : sig
  type t
  type start_error = Already_started

  type start_result =
    | Admitted
    | Stop_settled
    | Crash_settled of Failure.settlement

  val start : t -> (start_result, start_error) Eta.Effect.t
end
```

The root surface has no public typestate:

```ocaml
module Root : sig
  type 'output description := 'output t
  type 'output t

  type delivery_error = Stale_endpoint

  type advance_error =
    | Already_advancing
    | Awaiting_post_commit
    | Closed

  type 'output outcome =
    | Idle
    | Rejected of delivery_error
    | Committed of {
        output : 'output;
        post_commit : Post_commit.t;
      }
    | Stopped of {
        post_commit : Post_commit.t;
      }
    | Failed of {
        failure : Failure.t;
        post_commit : Post_commit.t;
      }

  val create : ingress_capacity:int -> 'output description -> 'output t
  val advance : 'output t -> ('output outcome, advance_error) result
  val request_stop : 'output t -> unit
end
```

`ingress_capacity` is mandatory and positive. `Root.create` raises
`Invalid_argument` for zero or negative values.

`Root.Failed` reports crash detection. `Post_commit.Crash_settled` reports final
settlement after complete teardown.

Drivers must handle `Post_commit.Already_started`. Stop and crash transformations
do not invalidate the batch token.

### Compiler and refactor behavior

The plain and syntax applications infer the same types:

```ocaml
val application : unit -> App_domain.output Eta_crux.t
val root : App_domain.output Eta_crux.Root.t
```

Both styles use a typed output record. The compiler detects a missing or wrongly
typed output field in both styles.

Adding one applicative input changes the plain `both` chain and its distant tuple
pattern. One new `and+` binding keeps the expression and name together.

Both styles compile if a programmer swaps two same-typed children. The syntax
improves locality, not type safety.

The compiler errors remain direct. They reject an unhandled admission error, a
root used as a description, and `let+` used for dynamic structure.

### Prototype evidence

The prototype is on branch `prototype/eta-crux-ocaml-api` at commit `8a646517`:

- [prototype](https://github.com/ribelo/eta/tree/8a646517/.scratch/prototypes/eta-crux-ocaml-api)
- [design](https://github.com/ribelo/eta/blob/8a646517/.scratch/prototypes/eta-crux-ocaml-api/DESIGN.md)
- [public surface](https://github.com/ribelo/eta/blob/8a646517/.scratch/prototypes/eta-crux-ocaml-api/eta_crux.mli)

The prototype compiles in the OxCaml and upstream OCaml 5.4 Nix shells. Its
negative cases produce the expected compiler errors.

### Rejected alternatives

V1 has no PPX, public construction context, first-class application component,
generative application API, or rank-2 emitter record.

Eta Crux also exposes no public root typestate, root-to-description bridge, or
helper that silently discards endpoint admission failure.

# Eta Crux V1 public API

## Status

This file defines the complete V1 public surface. The signatures are the
implementation target. Representation types remain abstract unless this file
shows their constructors.

Behavior is defined only in [Semantic laws](semantic-laws.md).

## Core computations

```ocaml
module Cutoff : sig
  type 'a t

  val always : 'a t
  val never : 'a t
  val phys_equal : 'a t
  val of_equal : ('a -> 'a -> bool) -> 'a t
  val of_compare : ('a -> 'a -> int) -> 'a t
end

type 'a t
type never = |

val return : 'a -> 'a t
val map : 'a t -> f:('a -> 'b) -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val cutoff : 'a t -> cutoff:'a Cutoff.t -> 'a t
val bind : 'a t -> f:('a -> 'b t) -> 'b t

module Syntax : sig
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
  val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
end
```

```ocaml
module Time : sig
  type monotonic_time
  type arithmetic_error = [ `Deadline_overflow | `Past_deadline ]

  val to_ms : monotonic_time -> int

  val add :
    monotonic_time ->
    Eta.Duration.t ->
    (monotonic_time, arithmetic_error) result

  val now : every:Eta.Duration.t -> monotonic_time t
  val deadline : monotonic_time -> bool t
  val after : Eta.Duration.t -> bool t
  val interval : Eta.Duration.t -> int t
end
```

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

```ocaml
module State_machine : sig
  val create :
    ?model_cutoff:'model Cutoff.t ->
    ?diagnostics:('model, 'action) Diagnostic.state_machine ->
    ?reset:
      (self:'action Endpoint.t ->
       input:'input ->
       model:'model ->
       'model * (unit, never) Eta.Effect.t option) ->
    'input t ->
    default_model:'model ->
    apply_action:
      (self:'action Endpoint.t ->
       input:'input ->
       model:'model ->
       action:'action ->
       'model * (unit, never) Eta.Effect.t option) ->
    ('model * 'action Endpoint.t) t
end

val lifecycle : (unit, never) Eta.Effect.t t -> unit t

module Assoc
    (Order : Eta_signal_map.Map.Ordered_type) : sig
  val assoc :
    ?data_cutoff:'data Cutoff.t ->
    'data Eta_signal_map.Map.Make(Order).t t ->
    f:(key:Order.t -> data:'data t -> 'result t) ->
    'result Eta_signal_map.Map.Make(Order).t t
end
```

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
    spec_cutoff:'spec Cutoff.t ->
    spec:'spec t ->
    producer:('spec -> ('item, 'error) producer) t ->
    target:'action Endpoint.t t ->
    on_item:('item -> 'action) t ->
    on_terminal:('error terminal -> 'action) t ->
    unit t
end
```

`Reset` and `Poll` are computation modules for structural reset and
graph-owned effect runs.

```ocaml
module Reset : sig
  type 'a computation := 'a t
  type t

  val scope :
    'input computation ->
    f:
      (reset:t computation ->
       input:'input computation ->
       'output computation) ->
    'output computation

  val trigger :
    t ->
    (unit, Endpoint.admission_error) Eta.Effect.t
end
```

```ocaml
module Poll : sig
  type 'a computation := 'a t

  module Starting : sig
    type ('result, 'output) t

    val empty : ('result, 'result option) t
    val initial : 'result -> ('result, 'result) t
  end

  val effect_on_change :
    input_cutoff:'input Cutoff.t ->
    ?result_cutoff:'result Cutoff.t ->
    starting:('result, 'output) Starting.t ->
    input:'input computation ->
    effect:
      ('input -> ('result, never) Eta.Effect.t) computation ->
    unit ->
    'output computation

  val manual_refresh :
    ?result_cutoff:'result Cutoff.t ->
    starting:('result, 'output) Starting.t ->
    effect:(('result, never) Eta.Effect.t) computation ->
    unit ->
    'output computation
    * (unit, Endpoint.admission_error) Eta.Effect.t computation
end
```

## Exports and requests

`Codec` is shared by projection kinds, exports, requests, and host operations.

```ocaml
module Codec : sig
  type encode_error = { message : string }
  type decode_error = { message : string }
  type 'a t

  val make :
    encode:('a -> (bytes, encode_error) result) ->
    decode:(bytes -> ('a, decode_error) result) ->
    'a t

  val encode : 'a t -> 'a -> (bytes, encode_error) result
  val decode : 'a t -> bytes -> ('a, decode_error) result
end
```

## Typed projections

A projection is the only outward value of a root commit. The local result of
the root computation does not enter the commit.

```ocaml
module Projection : sig
  module Incarnation : sig
    type t
    val equal : t -> t -> bool
    val compare : t -> t -> int
  end

  module Kind : sig
    type ('key, 'value) t
    type packed = Pack : ('key, 'value) t -> packed

    val define :
      name:string ->
      key_compare:('key -> 'key -> int) ->
      key_codec:'key Codec.t ->
      value_codec:'value Codec.t ->
      value_equal:('value -> 'value -> bool) ->
      cutoff:'value Cutoff.t ->
      ('key, 'value) t
  end

  module Catalog : sig
    type t
    val create : Kind.packed list -> t
  end

  type preflight_error =
    | Unknown_kind
    | Identity_collision
    | Projection_capacity_exceeded
    | Incarnation_exhausted

  type ('key, 'value) entry = {
    key : 'key;
    incarnation : Incarnation.t;
    value : 'value;
  }

  type ('key, 'value) update =
    | Attached of ('key, 'value) entry
    | Changed of ('key, 'value) entry
    | Removed of {
        key : 'key;
        incarnation : Incarnation.t;
      }

  module Snapshot : sig
    type t

    val find_opt :
      ('key, 'value) Kind.t ->
      key:'key ->
      t ->
      ('key, 'value) entry option

    type packed_entry =
      | Pack :
          ('key, 'value) Kind.t * ('key, 'value) entry ->
          packed_entry

    val fold :
      t ->
      init:'acc ->
      f:('acc -> packed_entry -> 'acc) ->
      'acc
  end

  module Batch : sig
    type t

    val find_opt :
      ('key, 'value) Kind.t ->
      key:'key ->
      t ->
      ('key, 'value) update list

    type packed_update =
      | Pack :
          ('key, 'value) Kind.t * ('key, 'value) update ->
          packed_update

    val fold :
      t ->
      init:'acc ->
      f:('acc -> packed_update -> 'acc) ->
      'acc
  end

  module Commit : sig
    type t
    val snapshot : t -> Snapshot.t
    val batch : t -> Batch.t
  end

  type delivery =
    | Updates of Batch.t
    | Bootstrap of Snapshot.t

  val publish :
    ('key, 'value) Kind.t ->
    key:'key ->
    'value t ->
    'value t
end
```

Each `Kind.define` call creates a distinct kind. `Catalog.create` fixes the
canonical kind order for all roots that use the catalog.

A kind name starts with a lowercase ASCII letter. Later bytes can be lowercase
ASCII letters, digits, periods, underscores, or hyphens. The limit is 128
bytes.

The `key_compare` function defines identity, lookup, collision, and key order.
It must be a stable total order.

A projection key must be independent of a serialized session. A key must not
contain an `Exported_endpoint.t` or a `Request_export.t`.

Equivalent keys must have equal successful encodings or equal encode failure.
Non-equivalent keys must have different successful encodings. Key decode must
return an equivalent key.

Value decode must return a value that is equal under `value_equal`. The
publication cutoff changes only the outward image.

`Snapshot.t`, `Batch.t`, `Commit.t`, and `Incarnation.t` are abstract. A
commit exposes only its complete snapshot and ordered batch.

```ocaml
module Exported_endpoint : sig
  type 'a computation := 'a t
  type 'payload t

  type availability_error =
    | Stale
    | Revoked

  type capacity_error = Full
  type admission = (unit, Endpoint.admission_error) result
  type try_result = (admission, capacity_error) result

  val create :
    'payload Endpoint.t computation ->
    codec:'payload Codec.t ->
    'payload t computation

  val try_invoke :
    'payload t ->
    'payload ->
    (try_result, availability_error) result

  val remote_handle : 'payload t -> bytes
end
```

`remote_handle` is valid only while a serialized binding calls a projection
value codec. It raises `Invalid_argument` outside that encoding boundary.

```ocaml
module Request : sig
  type closure_reason =
    | Initiator_cancelled
    | Owner_disposed
    | Root_stopped
    | Root_crashed
    | Session_closed

  type not_pending = Not_pending

  module Driver_event : sig
    type t
    type completion_error = Already_completed

    type 'error handler = {
      handle :
        'request 'response.
        operation:('request, 'response) Host_operation.t ->
        request:'request ->
        resolve:
          ('response ->
           ((unit, not_pending) result, never) Eta.Effect.t) ->
        on_cancel:((closure_reason -> unit) -> unit) ->
        (unit, 'error) Eta.Effect.t;
    }

    type dispatch_result =
      | Dispatched
      | Already_handled
      | Closed of closure_reason

    type handle_result =
      | Handled
      | Different_operation
      | Already_handled
      | Closed of closure_reason

    val dispatch :
      t ->
      'error handler ->
      (dispatch_result, 'error) Eta.Effect.t

    val handle :
      t ->
      ('request, 'response) Host_operation.t ->
      f:
        ('request ->
         resolve:
           ('response ->
            ((unit, not_pending) result, never) Eta.Effect.t) ->
         on_cancel:((closure_reason -> unit) -> unit) ->
         (unit, 'error) Eta.Effect.t) ->
      (handle_result, 'error) Eta.Effect.t

    val accepted :
      t ->
      ((unit, completion_error) result, never) Eta.Effect.t

    val failed :
      t ->
      Failure.Packed_cause.t ->
      ((unit, completion_error) result, never) Eta.Effect.t
  end
end

module Requester : sig
  type ('request, 'response) t

  type error =
    | Ingress_closed
    | Encode_failed of Codec.encode_error
    | Decode_failed of Codec.decode_error
    | Dispatch_failed
    | Closed of Request.closure_reason

  val request :
    ('request, 'response) t ->
    'request ->
    ('response, error) Eta.Effect.t
end

module Responder : sig
  type 'response t

  type error =
    | Not_pending
    | Encode_failed of Codec.encode_error

  val resolve :
    'response t ->
    'response ->
    (unit, error) Eta.Effect.t
end
```

Executing the first matching `handle` or total `dispatch` claims the event before
user work starts. Constructing the returned effect does not claim the event.
Descriptor mismatch does not claim it. A typed handler failure retains the claim.

```ocaml
module Request_export : sig
  type 'a computation := 'a t
  type ('request, 'response) t
  type availability_error = Stale | Revoked

  type invoke_error =
    | Unavailable of availability_error
    | Request_capacity_full
    | Ingress_capacity_full
    | Ingress_closed
    | Closed of Request.closure_reason

  val create :
    ('request * 'response Responder.t) Endpoint.t computation ->
    request:'request Codec.t ->
    response:'response Codec.t ->
    ('request, 'response) t computation

  val invoke :
    ('request, 'response) t ->
    'request ->
    ('response, invoke_error) Eta.Effect.t

  val remote_handle : ('request, 'response) t -> bytes
end
```

```ocaml
module Host_operation : sig
  type ('request, 'response) t
  type packed = Pack : ('request, 'response) t -> packed

  val define :
    name:string ->
    request:'request Codec.t ->
    response:'response Codec.t ->
    ('request, 'response) t

  val name : ('request, 'response) t -> string
  val request_codec : ('request, 'response) t -> 'request Codec.t
  val response_codec : ('request, 'response) t -> 'response Codec.t
end
```

The driver binding creates requesters from descriptors before the application
description is built. Duplicate operation names fail binding construction.

## Failures and roots

```ocaml
module Failure : sig
  module Packed_cause : sig
    type t

    val make :
      pp_error:(Format.formatter -> 'error -> unit) ->
      'error Eta.Cause.t ->
      t

    val portable : t -> string Eta.Cause.Portable.t
    val projection_preflight : t -> Projection.preflight_error option
    val pp : Format.formatter -> t -> unit
  end

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

  type origin =
    | Transition
    | Owned_work
    | Graph_clock
    | Adapter_delivery
    | Request_dispatch
    | Export_dispatch
    | Cleanup
    | Crash_handler

  type trigger_kind =
    | Initial_start
    | Endpoint_action
    | Clock_sample
    | Clock_due
    | Transition_effect
    | Lifecycle_program
    | Source_opening
    | Source_producer
    | Local_export_invocation
    | Serialized_export_invocation
    | Outbound_request
    | Inbound_response
    | Request_cancellation
    | Projection_preflight
    | Projection_delivery
    | Stop_teardown
    | Crash_teardown
    | Application_crash_handler
    | Structural_reset
    | Poll_effect

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

  type portable_record = {
    cause : string Eta.Cause.Portable.t;
    origin : origin;
    trigger : trigger_kind;
    position : int64;
  }

  type portable = {
    primary : portable_record;
    secondary : portable_record list;
  }
  val portable : t -> portable
  val encode_portable : portable -> bytes
  val decode_portable : bytes -> (portable, string) result
end
```

`Testing` is the post-commit effect observation SPI. It exposes shared
observation types and one opaque observer attachment for `Root.create`. The
test-owned controller lives in `eta_crux_test`. The identity modules are
opaque and root-local.

```ocaml
module Testing : sig
  module Effect_id : sig
    type t
  end

  module Commit_index : sig
    type t
  end

  module Event_position : sig
    type t
  end

  type settlement =
    | Succeeded
    | Interrupted
    | Failed

  type event =
    | Staged of {
        position : Event_position.t;
        commit : Commit_index.t;
        effects : Effect_id.t list;
      }
    | Started of {
        position : Event_position.t;
        effect : Effect_id.t;
      }
    | Settled of {
        position : Event_position.t;
        effect : Effect_id.t;
        settlement : settlement;
      }
    | Discarded_before_start of {
        position : Event_position.t;
        effect : Effect_id.t;
      }

  type post_commit_effect_observer
end
```

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

module Root : sig
  type 'a computation := 'a t
  type t

  type delivery_error =
    | Stale_endpoint
    | Stale_reset

  type advance_error =
    | Already_advancing
    | Awaiting_post_commit
    | Closed
    | Driver_attached

  type outcome =
    | Idle
    | Rejected of delivery_error
    | Committed of {
        commit : Projection.Commit.t;
        post_commit : Post_commit.t;
      }
    | Stopped of {
        post_commit : Post_commit.t;
      }
    | Failed of {
        failure : Failure.t;
        post_commit : Post_commit.t;
      }

  val create :
    ?post_commit_effect_observer:Testing.post_commit_effect_observer ->
    catalog:Projection.Catalog.t ->
    projection_capacity:int ->
    ingress_capacity:int ->
    request_capacity:int ->
    _ computation ->
    t

  val advance :
    t ->
    ((outcome, advance_error) result, never) Eta.Effect.t
  val request_stop : t -> unit
end
```

`Root.create` fixes one catalog and one positive projection capacity. The root
uses separate state and incarnation allocation when another root uses the same
catalog.

`Root.advance` computes projection preflight before it installs the root frame.
A preflight error returns `Failed`. The packed cause exposes the exact
`Projection.preflight_error`.

## Driver and adapter

```ocaml
module Driver : sig
  type t

  module Binding : sig
    type t

    val identity :
      Host_operation.packed list ->
      t

    val serialized :
      operations:Host_operation.packed list ->
      session:Serialized_session.candidate ->
      t * Serialized_session.admin

    val requester :
      t ->
      ('request, 'response) Host_operation.t ->
      ('request, 'response) Requester.t
  end

  type terminal =
    | Stopped
    | Crashed of Failure.settlement

  module Delivery : sig
    type reason =
      | Advancement
      | Session_replacement

    type t
    type completion_error = Already_completed

    val projection : t -> Projection.delivery
    val reason : t -> reason

    val delivered :
      t ->
      ((unit, completion_error) result, never) Eta.Effect.t

    val failed :
      t ->
      Failure.Packed_cause.t ->
      ((unit, completion_error) result, never) Eta.Effect.t
  end

  type event =
    | Deliver of Delivery.t
    | Request of Request.Driver_event.t
    | Rejected of Root.delivery_error
    | Crash_detected of Failure.t
    | Closed of terminal

  val create : Binding.t -> Root.t -> t

  val poll : t -> (event option, never) Eta.Effect.t
  val await : t -> (event, never) Eta.Effect.t
  val latest_committed_snapshot : t -> Projection.Snapshot.t option
  val request_stop : t -> unit
end
```

`Driver.create` attaches one unstarted root exclusively. A started or attached
root, or a reused binding, raises `Invalid_argument`. A rejected attachment
claim leaves each otherwise-unused argument available for a later attachment.
Direct `Root.advance` on a driver-owned root returns `Error Driver_attached`.
`latest_committed_snapshot` is a synchronous pull. It returns `None` before the
first commit.

Each commit publishes the snapshot before delivery. Delivery failure and
terminal state do not clear the snapshot. The pull performs no delivery or
post-commit work.

```ocaml
module Adapter : sig
  type 'error resource

  type delivery = {
    projection : Projection.delivery;
    reason : Driver.Delivery.reason;
  }

  val resource :
    pp_error:(Format.formatter -> 'error -> unit) ->
    acquire:('binding, 'error) Eta.Effect.t ->
    release:
      ('binding ->
       (unit, 'error) Eta.Effect.t) ->
    deliver:
      ('binding ->
       delivery ->
       (unit, 'error) Eta.Effect.t) ->
    request_event:
      ('binding ->
       Request.Driver_event.t ->
       (unit, 'error) Eta.Effect.t) ->
    crash_detected:
      ('binding ->
       Failure.t ->
       (unit, 'error) Eta.Effect.t) ->
    'error resource
end
```

```ocaml
module Hosted : sig
  module Control : sig
    type t
    val request_stop : t -> unit
  end

  val run :
    Driver.t ->
    adapter:(Control.t -> 'error Adapter.resource) ->
    (Driver.terminal, 'error) Eta.Effect.t
end
```

An adapter receives `Updates` for an advancement. A replacement session
receives `Bootstrap`.

One delivery token accepts one answer. Successful acknowledgment admits the
owned post-commit work.

Delivery failure keeps the commit published. It latches `Adapter_delivery`
with trigger `Projection_delivery`, discards ordinary post-commit work, and
does not retry.

Session replacement is absent from `Hosted.Control`. The separate serialized
administration capability prevents an identity driver from returning a
`Not_serialized` error.

## Serialized protocol

```ocaml
module Serialized_session : sig
  type candidate
  type admin
  type peer

  type receive_error =
    | Session_closed
    | Protocol_error of Wire.protocol_error

  type replace_error =
    | Starting
    | Replacement_pending
    | Awaiting_delivery
    | Terminating
    | Closed

  type replace_outcome =
    | Replaced
    | Stopped
    | Crashed of Failure.t

  val candidate :
    max_frame_bytes:int ->
    format:(module Wire.FORMAT) ->
    candidate * peer

  val receive :
    peer ->
    bytes ->
    ((unit, receive_error) result, never) Eta.Effect.t

  val poll_outgoing :
    peer ->
    (bytes option, never) Eta.Effect.t

  val await_outgoing :
    peer ->
    (bytes, receive_error) Eta.Effect.t

  val replace :
    admin ->
    candidate ->
    (replace_outcome, replace_error) Eta.Effect.t

  val close_candidate : candidate -> unit
end
```

```ocaml
module Wire : sig
  module Frame : sig
    type t
  end

  type protocol_error =
    | Frame_too_large
    | Malformed_frame
    | Unknown_tag
    | Invalid_field
    | Noncanonical_bytes
    | Invalid_operation_name
    | Bad_sequence
    | Unknown_reply
    | Wrong_result_family
    | Sequence_exhausted

  module type FORMAT = sig
    val encode : Frame.t -> bytes
    val decode : bytes -> (Frame.t, protocol_error) result
  end
end
```

`Wire.Frame.t` is the concrete semantic variant defined in
[Wire protocol](wire-protocol.md). This is the narrow shared seam used by the
two codec packages.

`Eta_crux_json.Format` and `Eta_crux_sexp.Format` implement `Wire.FORMAT`.

## Test package

`Eta_crux_test` exports:

- `Incoming`, `Test_shell`, and `Handle`
- `Projection_harness`
- `Controlled_source`
- `Post_commit_effect_observer`
- a recording `Adapter.resource`

`Handle.create` and `Handle.use` require an explicit `clock:Eta_test.Test_clock.t`.
`Handle` exposes `advance_time_by` and `advance_time_to` for deterministic time
movement. It also exposes `latest_committed_snapshot` and the test-only
`latest_delivered_snapshot`.

The committed query reads the production driver. The delivered query reads the
successful-delivery shadow. Test injection uses the delivered shadow.

`Projection_harness` supplies unit-key and keyed kind helpers. It also supplies
the wire recipient, an incarnation-counter seed, and capacity controls.

The wire recipient decodes and checks one complete delivery before
installation. A failed check or installation keeps the prior delivered state.

```ocaml
module Post_commit_effect_observer : sig
  module Effect_id = Eta_crux.Testing.Effect_id
  module Commit_index = Eta_crux.Testing.Commit_index
  module Event_position = Eta_crux.Testing.Event_position

  type settlement = Eta_crux.Testing.settlement =
    | Succeeded
    | Interrupted
    | Failed

  type event = Eta_crux.Testing.event =
    | Staged of {
        position : Event_position.t;
        commit : Commit_index.t;
        effects : Effect_id.t list;
      }
    | Started of {
        position : Event_position.t;
        effect : Effect_id.t;
      }
    | Settled of {
        position : Event_position.t;
        effect : Effect_id.t;
        settlement : settlement;
      }
    | Discarded_before_start of {
        position : Event_position.t;
        effect : Effect_id.t;
      }

  type t

  val create : unit -> t
  val attachment : t -> Eta_crux.Testing.post_commit_effect_observer
  val poll : t -> event option
  val drain : t -> event list
  val expect_empty : t -> unit
end
```

The exact test signatures and ownership rules are in
[Verification](verification.md).

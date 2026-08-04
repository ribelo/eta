# Eta Crux V1 public API

## Status

This file defines the complete V1 public surface. The signatures are the
implementation target. Representation types remain abstract unless this file
shows their constructors.

Behavior is defined only in [Semantic laws](semantic-laws.md).

## Core computations

```ocaml
type 'a t
type never = |

val return : 'a -> 'a t
val map : 'a t -> f:('a -> 'b) -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t
val cutoff : 'a t -> equal:('a -> 'a -> bool) -> 'a t
val bind : 'a t -> f:('a -> 'b t) -> 'b t

module Syntax : sig
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
  val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
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

val lifecycle : (unit, never) Eta.Effect.t t -> unit t

module Assoc (M : Map.S) : sig
  val assoc :
    ?data_equal:('data -> 'data -> bool) ->
    'data M.t t ->
    f:(key:M.key -> data:'data t -> 'result t) ->
    'result M.t t
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
    spec_equal:('spec -> 'spec -> bool) ->
    spec:'spec t ->
    producer:('spec -> ('item, 'error) producer) t ->
    target:'action Endpoint.t t ->
    on_item:('item -> 'action) t ->
    on_terminal:('error terminal -> 'action) t ->
    unit t
end
```

## Exports and requests

`Codec` is shared by exports, requests, host operations, and root output.

```ocaml
module Codec : sig
  type decode_error = { message : string }
  type 'a t

  val make :
    encode:('a -> bytes) ->
    decode:(bytes -> ('a, decode_error) result) ->
    'a t
end
```

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
end
```

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
    | Dispatch_failed
    | Closed of Request.closure_reason

  val request :
    ('request, 'response) t ->
    'request ->
    ('response, error) Eta.Effect.t
end

module Responder : sig
  type 'response t
  type error = Request.not_pending

  val resolve :
    'response t ->
    'response ->
    (unit, error) Eta.Effect.t
end
```

```ocaml
module Request_export : sig
  type ('request, 'response) t
  type availability_error = Stale | Revoked

  type invoke_error =
    | Unavailable of availability_error
    | Request_capacity_full
    | Ingress_capacity_full
    | Ingress_closed
    | Closed of Request.closure_reason

  val create :
    ('request * 'response Responder.t) Endpoint.t t ->
    request:'request Codec.t ->
    response:'response Codec.t ->
    ('request, 'response) t t

  val invoke :
    ('request, 'response) t ->
    'request ->
    ('response, invoke_error) Eta.Effect.t
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
    | Adapter_delivery
    | Request_dispatch
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
    | Outbound_request
    | Inbound_response
    | Request_cancellation
    | Output_delivery
    | Stop_teardown
    | Crash_teardown
    | Application_crash_handler

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

  type portable
  val portable : t -> portable
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

  val create :
    ingress_capacity:int ->
    request_capacity:int ->
    'output description ->
    'output t

  val advance : 'output t -> ('output outcome, advance_error) result
  val request_stop : 'output t -> unit
end
```

## Driver and adapter

```ocaml
module Driver : sig
  type 'output t

  module Binding : sig
    type 'output t

    val identity :
      Host_operation.packed list ->
      'output t

    val serialized :
      output:'output Codec.t ->
      operations:Host_operation.packed list ->
      session:Serialized_session.candidate ->
      'output t * Serialized_session.admin

    val requester :
      'output t ->
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

    type 'output t
    type completion_error = Already_completed

    val output : 'output t -> 'output
    val reason : 'output t -> reason

    val delivered :
      'output t ->
      ((unit, completion_error) result, never) Eta.Effect.t

    val failed :
      'output t ->
      Failure.Packed_cause.t ->
      ((unit, completion_error) result, never) Eta.Effect.t
  end

  type 'output event =
    | Deliver of 'output Delivery.t
    | Request of Request.Driver_event.t
    | Rejected of Root.delivery_error
    | Crash_detected of Failure.t
    | Closed of terminal

  val create : 'output Binding.t -> 'output Root.t -> 'output t

  val poll : 'output t -> ('output event option, never) Eta.Effect.t
  val await : 'output t -> ('output event, never) Eta.Effect.t
  val request_stop : 'output t -> unit
end
```

```ocaml
module Adapter : sig
  type ('output, 'error) binding
  type ('output, 'error) resource

  type 'output delivery = {
    output : 'output;
    reason : Driver.Delivery.reason;
  }

  val resource :
    pp_error:(Format.formatter -> 'error -> unit) ->
    acquire:(('output, 'error) binding, 'error) Eta.Effect.t ->
    release:
      (('output, 'error) binding ->
       (unit, 'error) Eta.Effect.t) ->
    deliver:
      (('output, 'error) binding ->
       'output delivery ->
       (unit, 'error) Eta.Effect.t) ->
    request_event:
      (('output, 'error) binding ->
       Request.Driver_event.t ->
       (unit, 'error) Eta.Effect.t) ->
    crash_detected:
      (('output, 'error) binding ->
       Failure.t ->
       (unit, 'error) Eta.Effect.t) ->
    ('output, 'error) resource
end
```

```ocaml
module Hosted : sig
  module Control : sig
    type t
    val request_stop : t -> unit
  end

  val run :
    'output Driver.t ->
    adapter:(Control.t -> ('output, 'error) Adapter.resource) ->
    (Driver.terminal, 'error) Eta.Effect.t
end
```

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

`Eta_crux_json.Format` and `Eta_crux_sexp.Format` implement `Wire.FORMAT`.

## Test package

`Eta_crux_test` exports:

- `Incoming`, `Test_shell`, and `Handle`
- `Controlled_source`
- a recording `Adapter.resource`

The exact test signatures and ownership rules are in
[Verification](verification.md).

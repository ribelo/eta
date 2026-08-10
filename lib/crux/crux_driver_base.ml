open Crux_engine
open Crux_boundary

module Failure = Crux_failure.Failure
module Host_operation = Crux_boundary.Host_operation
module Request = Crux_boundary.Request
module Wire = Crux_wire.Wire
module Serialized_session = Crux_wire.Serialized_session
module Root = Crux_root.Root
module Post_commit = Crux_root.Post_commit
module Remote_registry = Crux_remote_registry
module Seq_map = Map.Make (Int32)
module String_map = Map.Make (String)

type request_command =
  | Request_dispatch_command of string
  | Request_cancel_command of string
  | Inbound_resolve_command of string

type 'output serialized_binding = {
  output_codec : 'output Codec.t;
  mutable candidate : Serialized_session.candidate;
  mutable replacement_pending : bool;
  authentication_key : string;
  mutable next_session : int64;
  mutable registry : Remote_registry.t;
  registry_lock : Eta.Sync_lock.t;
  mutable closure_observed : bool;
}

type 'output binding_mode =
  | Identity
  | Serialized of 'output serialized_binding

type 'output binding = {
  core : binding_core;
  mode : 'output binding_mode;
  mutable replace :
    Serialized_session.candidate ->
    (Serialized_session.replace_outcome,
     Serialized_session.replace_error)
    Eta.Effect.t;
}

type terminal =
  | Stopped
  | Crashed of Failure.settlement

type reason =
  | Advancement
  | Session_replacement

type 'output t = {
  binding : 'output binding;
  root : 'output Root.t;
  requests : (Request.Driver_event.t, never) Eta.Queue.t;
  lock : Eta.Sync_lock.t;
  mutable state : 'output state;
  mutable last_output : 'output option;
  mutable next_request_token : int64;
  mutable request_commands : request_command Seq_map.t;
  mutable remote_requests : Request.Driver_event.t String_map.t;
  mutable inbound_requests :
    boundary_remote_request String_map.t;
}

and 'output state =
  | Running
  | Delivering of 'output delivery * int32 option
  | Replacement_delivering of
      int32 * (Serialized_session.replace_outcome, never) Eta.Promise.t
  | Crash_detected_pending of Failure.t * Post_commit.t
  | Crash_notifying of Failure.t * Post_commit.t * int32
  | Crash_teardown of Failure.t * Post_commit.t
  | Crash_settled_pending of Failure.settlement
  | Crash_settled_notifying of Failure.settlement * int32
  | Crash_closed_pending of Failure.settlement
  | Stopped_closed_pending
  | Closed_done

and 'output delivery = {
  output : 'output;
  reason : reason;
  lock : Eta.Sync_lock.t;
  mutable completed : bool;
  answer :
    [ `Delivered | `Failed of Failure.Packed_cause.t ] ->
    ((unit, delivery_completion_error) result, never) Eta.Effect.t;
}

and delivery_completion_error = Already_completed

type 'output event =
  | Deliver of 'output delivery
  | Request of Request.Driver_event.t
  | Rejected of Root.delivery_error
  | Crash_detected of Failure.t
  | Closed of terminal

let set_state driver state =
  Eta.Sync_lock.use driver.lock @@ fun () ->
  driver.state <- state

let state driver =
  Eta.Sync_lock.use driver.lock @@ fun () -> driver.state

let wake driver =
  ignore (Eta.Queue.try_offer_now driver.root.core.wake () : _)

let adapter_delivery_cause message =
  Failure.Packed_cause.make
    ~pp_error:Format.pp_print_string
    (Eta.Cause.fail message)

let latch_adapter_delivery_failure driver cause =
  latch_failure_record driver.root.core
    (failure_record driver.root.core
       ~origin:Failure.Adapter_delivery
       ~trigger:Failure.Output_delivery cause);
  Eta.Sync_lock.use driver.root.core.lock @@ fun () ->
  Option.get (Atomic.get driver.root.core.failure)

module Delivery = struct
  type 'output t = 'output delivery
  type nonrec reason = reason =
    | Advancement
    | Session_replacement

  type completion_error = delivery_completion_error =
    Already_completed

  let output delivery = delivery.output
  let reason delivery = delivery.reason
  let delivered delivery = delivery.answer `Delivered
  let failed delivery cause = delivery.answer (`Failed cause)
end

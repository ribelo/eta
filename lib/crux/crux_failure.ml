type never = |

module Diagnostic = struct
  type snapshot = {
    summary : string;
    fields : (string * string) list;
  }

  type ('model, 'action) state_machine = {
    model : 'model -> snapshot;
    action : 'action -> snapshot;
  }
end

module Failure = struct
  module Packed_cause = struct
    type t =
      | Pack : {
          cause : 'error Eta.Cause.t;
          pp_error : Format.formatter -> 'error -> unit;
        } -> t

    let make ~pp_error cause = Pack { cause; pp_error }

    let portable (Pack { cause; pp_error }) =
      Eta.Cause.Portable.of_cause
        (fun error -> Format.asprintf "%a" pp_error error)
        cause

    let pp formatter (Pack { cause; pp_error }) =
      Eta.Cause.pp pp_error formatter cause
  end

  module Cell_id = struct
    type t = int
    let compare = Int.compare
    let pp = Format.pp_print_int
  end

  module Endpoint_id = struct
    type t = int
    let compare = Int.compare
    let pp = Format.pp_print_int
  end

  module Observation_position = struct
    type t = int64
    let compare = Int64.compare
    let to_int64 value = value
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
    | Output_delivery
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

  let portable_record (record : record) =
    {
      cause = Packed_cause.portable record.cause;
      origin = record.origin;
      trigger = record.trigger;
      position = Observation_position.to_int64 record.position;
    }

  let portable (failure : t) =
    {
      primary = portable_record failure.primary;
      secondary = List.map portable_record failure.secondary;
    }
end

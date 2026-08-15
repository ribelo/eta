type closure_reason =
  | Initiator_cancelled
  | Owner_disposed
  | Root_stopped
  | Root_crashed
  | Session_closed

type endpoint_outcome =
  | Endpoint_accepted
  | Endpoint_full
  | Endpoint_ingress_closed
  | Endpoint_malformed_handle
  | Endpoint_unknown_handle
  | Endpoint_stale_handle
  | Endpoint_revoked_handle
  | Endpoint_malformed_payload

type request_start_outcome =
  | Request_started of string
  | Start_request_capacity_full
  | Start_ingress_capacity_full
  | Start_ingress_closed
  | Start_malformed_handle
  | Start_unknown_handle
  | Start_stale_handle
  | Start_revoked_handle
  | Start_malformed_payload
  | Start_closed of closure_reason

type request_dispatch_outcome =
  | Dispatch_accepted
  | Dispatch_failed

type request_resolve_outcome =
  | Resolve_accepted
  | Resolve_not_pending
  | Resolve_malformed_request
  | Resolve_unknown_request
  | Resolve_stale_request
  | Resolve_malformed_payload

type request_cancel_outcome =
  | Cancel_accepted
  | Cancel_not_pending
  | Cancel_malformed_request
  | Cancel_unknown_request
  | Cancel_stale_request

type delivery_reason =
  | Advancement
  | Session_replacement

type callback_outcome =
  | Callback_accepted
  | Callback_failed of string

type projection_entry = {
  kind : string;
  key : string;
  incarnation : int64;
  value : string;
}

type projection_update =
  | Projection_attached of projection_entry
  | Projection_changed of projection_entry
  | Projection_removed of {
      kind : string;
      key : string;
      incarnation : int64;
    }

type projection_content =
  | Projection_updates of projection_update list
  | Projection_bootstrap of projection_entry list

type body =
  | Deliver_projection of {
      reason : delivery_reason;
      content : projection_content;
    }
  | Notify_crash of { failure : string }
  | Invoke_endpoint of {
      handle : string;
      payload : string;
    }
  | Start_request of {
      handle : string;
      payload : string;
    }
  | Dispatch_request of {
      request : string;
      operation : string;
      payload : string;
    }
  | Resolve_request of {
      request : string;
      payload : string;
    }
  | Cancel_request of { request : string }
  | Request_resolved of {
      request : string;
      payload : string;
    }
  | Request_closed of {
      request : string;
      reason : closure_reason;
    }
  | Endpoint_result of {
      reply_to : int;
      outcome : endpoint_outcome;
    }
  | Request_start_result of {
      reply_to : int;
      outcome : request_start_outcome;
    }
  | Request_dispatch_result of {
      reply_to : int;
      outcome : request_dispatch_outcome;
    }
  | Request_resolve_result of {
      reply_to : int;
      outcome : request_resolve_outcome;
    }
  | Request_cancel_result of {
      reply_to : int;
      outcome : request_cancel_outcome;
    }
  | Projection_result of {
      reply_to : int;
      outcome : callback_outcome;
    }
  | Crash_result of {
      reply_to : int;
      outcome : callback_outcome;
    }

type frame = {
  seq : int;
  body : body;
}

let tag = function
  | Deliver_projection _ -> "projection.deliver"
  | Notify_crash _ -> "crash.notify"
  | Invoke_endpoint _ -> "endpoint.invoke"
  | Start_request _ -> "request.start"
  | Dispatch_request _ -> "request.dispatch"
  | Resolve_request _ -> "request.resolve"
  | Cancel_request _ -> "request.cancel"
  | Request_resolved _ -> "request.resolved"
  | Request_closed _ -> "request.closed"
  | Endpoint_result _ -> "endpoint.result"
  | Request_start_result _ -> "request.start_result"
  | Request_dispatch_result _ -> "request.dispatch_result"
  | Request_resolve_result _ -> "request.resolve_result"
  | Request_cancel_result _ -> "request.cancel_result"
  | Projection_result _ -> "projection.result"
  | Crash_result _ -> "crash.result"

let reason_to_string = function
  | Initiator_cancelled -> "initiator_cancelled"
  | Owner_disposed -> "owner_disposed"
  | Root_stopped -> "root_stopped"
  | Root_crashed -> "root_crashed"
  | Session_closed -> "session_closed"

let reason_of_string = function
  | "initiator_cancelled" -> Ok Initiator_cancelled
  | "owner_disposed" -> Ok Owner_disposed
  | "root_stopped" -> Ok Root_stopped
  | "root_crashed" -> Ok Root_crashed
  | "session_closed" -> Ok Session_closed
  | value -> Error ("unknown closure reason: " ^ value)

let endpoint_outcome_to_string = function
  | Endpoint_accepted -> "accepted"
  | Endpoint_full -> "full"
  | Endpoint_ingress_closed -> "ingress_closed"
  | Endpoint_malformed_handle -> "malformed_handle"
  | Endpoint_unknown_handle -> "unknown_handle"
  | Endpoint_stale_handle -> "stale_handle"
  | Endpoint_revoked_handle -> "revoked_handle"
  | Endpoint_malformed_payload -> "malformed_payload"

let endpoint_outcome_of_string = function
  | "accepted" -> Ok Endpoint_accepted
  | "full" -> Ok Endpoint_full
  | "ingress_closed" -> Ok Endpoint_ingress_closed
  | "malformed_handle" -> Ok Endpoint_malformed_handle
  | "unknown_handle" -> Ok Endpoint_unknown_handle
  | "stale_handle" -> Ok Endpoint_stale_handle
  | "revoked_handle" -> Ok Endpoint_revoked_handle
  | "malformed_payload" -> Ok Endpoint_malformed_payload
  | value -> Error ("unknown endpoint outcome: " ^ value)

let dispatch_outcome_to_string = function
  | Dispatch_accepted -> "accepted"
  | Dispatch_failed -> "failed"

let dispatch_outcome_of_string = function
  | "accepted" -> Ok Dispatch_accepted
  | "failed" -> Ok Dispatch_failed
  | value -> Error ("unknown dispatch outcome: " ^ value)

let resolve_outcome_to_string = function
  | Resolve_accepted -> "accepted"
  | Resolve_not_pending -> "not_pending"
  | Resolve_malformed_request -> "malformed_request"
  | Resolve_unknown_request -> "unknown_request"
  | Resolve_stale_request -> "stale_request"
  | Resolve_malformed_payload -> "malformed_payload"

let resolve_outcome_of_string = function
  | "accepted" -> Ok Resolve_accepted
  | "not_pending" -> Ok Resolve_not_pending
  | "malformed_request" -> Ok Resolve_malformed_request
  | "unknown_request" -> Ok Resolve_unknown_request
  | "stale_request" -> Ok Resolve_stale_request
  | "malformed_payload" -> Ok Resolve_malformed_payload
  | value -> Error ("unknown resolution outcome: " ^ value)

let cancel_outcome_to_string = function
  | Cancel_accepted -> "accepted"
  | Cancel_not_pending -> "not_pending"
  | Cancel_malformed_request -> "malformed_request"
  | Cancel_unknown_request -> "unknown_request"
  | Cancel_stale_request -> "stale_request"

let cancel_outcome_of_string = function
  | "accepted" -> Ok Cancel_accepted
  | "not_pending" -> Ok Cancel_not_pending
  | "malformed_request" -> Ok Cancel_malformed_request
  | "unknown_request" -> Ok Cancel_unknown_request
  | "stale_request" -> Ok Cancel_stale_request
  | value -> Error ("unknown cancellation outcome: " ^ value)

let delivery_reason_to_string = function
  | Advancement -> "advancement"
  | Session_replacement -> "session_replacement"

let delivery_reason_of_string = function
  | "advancement" -> Ok Advancement
  | "session_replacement" -> Ok Session_replacement
  | value -> Error ("unknown delivery reason: " ^ value)

let callback_outcome_to_fields = function
  | Callback_accepted -> "accepted", None
  | Callback_failed message -> "failed", Some message

let uint64_to_string value = Printf.sprintf "%Lu" value

let encode_bytes value =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet value

let request_start_outcome_to_fields = function
  | Request_started request -> "started", Some ("request", encode_bytes request)
  | Start_request_capacity_full -> "request_capacity_full", None
  | Start_ingress_capacity_full -> "ingress_capacity_full", None
  | Start_ingress_closed -> "ingress_closed", None
  | Start_malformed_handle -> "malformed_handle", None
  | Start_unknown_handle -> "unknown_handle", None
  | Start_stale_handle -> "stale_handle", None
  | Start_revoked_handle -> "revoked_handle", None
  | Start_malformed_payload -> "malformed_payload", None
  | Start_closed reason -> "closed", Some ("reason", reason_to_string reason)

let decode_bytes value =
  if String.contains value '=' then Error "noncanonical base64url bytes"
  else
    let remainder = String.length value mod 4 in
    let padded =
      if remainder = 0 then value else value ^ String.make (4 - remainder) '='
    in
    try
      let decoded =
        Base64.decode_exn ~pad:true ~alphabet:Base64.uri_safe_alphabet padded
      in
      if String.equal (encode_bytes decoded) value then Ok decoded
      else Error "noncanonical base64url bytes"
    with _ -> Error "invalid base64url bytes"

let max_uint32 = 0xffff_ffff

let ( let* ) value f =
  match value with
  | Ok value -> f value
  | Error _ as error -> error

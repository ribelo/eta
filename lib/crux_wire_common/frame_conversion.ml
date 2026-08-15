module Frame = Eta_crux.Wire.Frame

let seq_to_int value =
  Int64.(to_int (logand (of_int32 value) 0xffff_ffffL))

let int_to_seq = Int32.of_int
let bytes_to_string = Bytes.to_string
let string_to_bytes = Bytes.of_string

let closure_to_protocol = function
  | Eta_crux.Request.Initiator_cancelled -> Protocol.Initiator_cancelled
  | Owner_disposed -> Protocol.Owner_disposed
  | Root_stopped -> Protocol.Root_stopped
  | Root_crashed -> Protocol.Root_crashed
  | Session_closed -> Protocol.Session_closed

let closure_of_protocol = function
  | Protocol.Initiator_cancelled -> Eta_crux.Request.Initiator_cancelled
  | Owner_disposed -> Owner_disposed
  | Root_stopped -> Root_stopped
  | Root_crashed -> Root_crashed
  | Session_closed -> Session_closed

let endpoint_to_protocol = function
  | `Accepted -> Protocol.Endpoint_accepted
  | `Full -> Endpoint_full
  | `Ingress_closed -> Endpoint_ingress_closed
  | `Malformed_handle -> Endpoint_malformed_handle
  | `Unknown_handle -> Endpoint_unknown_handle
  | `Stale_handle -> Endpoint_stale_handle
  | `Revoked_handle -> Endpoint_revoked_handle
  | `Malformed_payload -> Endpoint_malformed_payload

let endpoint_of_protocol = function
  | Protocol.Endpoint_accepted -> `Accepted
  | Endpoint_full -> `Full
  | Endpoint_ingress_closed -> `Ingress_closed
  | Endpoint_malformed_handle -> `Malformed_handle
  | Endpoint_unknown_handle -> `Unknown_handle
  | Endpoint_stale_handle -> `Stale_handle
  | Endpoint_revoked_handle -> `Revoked_handle
  | Endpoint_malformed_payload -> `Malformed_payload

let identity_to_resolve = function
  | `Accepted -> Protocol.Resolve_accepted
  | `Not_pending -> Resolve_not_pending
  | `Malformed_request -> Resolve_malformed_request
  | `Unknown_request -> Resolve_unknown_request
  | `Stale_request -> Resolve_stale_request

let identity_to_cancel = function
  | `Accepted -> Protocol.Cancel_accepted
  | `Not_pending -> Cancel_not_pending
  | `Malformed_request -> Cancel_malformed_request
  | `Unknown_request -> Cancel_unknown_request
  | `Stale_request -> Cancel_stale_request

let identity_of_resolve = function
  | Protocol.Resolve_accepted -> `Identity `Accepted
  | Resolve_not_pending -> `Identity `Not_pending
  | Resolve_malformed_request -> `Identity `Malformed_request
  | Resolve_unknown_request -> `Identity `Unknown_request
  | Resolve_stale_request -> `Identity `Stale_request
  | Resolve_malformed_payload -> `Malformed_payload

let identity_of_cancel = function
  | Protocol.Cancel_accepted -> `Accepted
  | Cancel_not_pending -> `Not_pending
  | Cancel_malformed_request -> `Malformed_request
  | Cancel_unknown_request -> `Unknown_request
  | Cancel_stale_request -> `Stale_request

let start_to_protocol = function
  | `Started request -> Protocol.Request_started (bytes_to_string request)
  | `Request_capacity_full -> Start_request_capacity_full
  | `Ingress_capacity_full -> Start_ingress_capacity_full
  | `Ingress_closed -> Start_ingress_closed
  | `Malformed_handle -> Start_malformed_handle
  | `Unknown_handle -> Start_unknown_handle
  | `Stale_handle -> Start_stale_handle
  | `Revoked_handle -> Start_revoked_handle
  | `Malformed_payload -> Start_malformed_payload
  | `Closed reason -> Start_closed (closure_to_protocol reason)

let start_of_protocol = function
  | Protocol.Request_started request -> `Started (string_to_bytes request)
  | Start_request_capacity_full -> `Request_capacity_full
  | Start_ingress_capacity_full -> `Ingress_capacity_full
  | Start_ingress_closed -> `Ingress_closed
  | Start_malformed_handle -> `Malformed_handle
  | Start_unknown_handle -> `Unknown_handle
  | Start_stale_handle -> `Stale_handle
  | Start_revoked_handle -> `Revoked_handle
  | Start_malformed_payload -> `Malformed_payload
  | Start_closed reason -> `Closed (closure_of_protocol reason)

let callback_to_protocol = function
  | `Accepted -> Protocol.Callback_accepted
  | `Failed message -> Callback_failed message

let callback_of_protocol = function
  | Protocol.Callback_accepted -> `Accepted
  | Callback_failed message -> `Failed message

let projection_entry_to_protocol (entry : Frame.projection_entry) =
  {
    Protocol.kind = entry.kind;
    key = bytes_to_string entry.key;
    incarnation = entry.incarnation;
    value = bytes_to_string entry.value;
  }

let projection_entry_of_protocol (entry : Protocol.projection_entry) =
  {
    Frame.kind = entry.kind;
    key = string_to_bytes entry.key;
    incarnation = entry.incarnation;
    value = string_to_bytes entry.value;
  }

let projection_update_to_protocol = function
  | Frame.Attached entry ->
      Protocol.Projection_attached (projection_entry_to_protocol entry)
  | Frame.Changed entry ->
      Protocol.Projection_changed (projection_entry_to_protocol entry)
  | Frame.Removed { kind; key; incarnation } ->
      Protocol.Projection_removed
        { kind; key = bytes_to_string key; incarnation }

let projection_update_of_protocol = function
  | Protocol.Projection_attached entry ->
      Frame.Attached (projection_entry_of_protocol entry)
  | Protocol.Projection_changed entry ->
      Frame.Changed (projection_entry_of_protocol entry)
  | Protocol.Projection_removed { kind; key; incarnation } ->
      Frame.Removed
        { kind; key = string_to_bytes key; incarnation }

let to_protocol = function
  | Frame.Projection_deliver { seq; reason; content } ->
      let content =
        match content with
        | Frame.Updates updates ->
            Protocol.Projection_updates
              (List.map projection_update_to_protocol updates)
        | Frame.Bootstrap entries ->
            Protocol.Projection_bootstrap
              (List.map projection_entry_to_protocol entries)
      in
      { Protocol.seq = seq_to_int seq;
        body = Deliver_projection {
          reason = (match reason with `Advancement -> Advancement | `Session_replacement -> Session_replacement);
          content } }
  | Projection_result { seq; reply_to; result } ->
      { seq = seq_to_int seq; body = Projection_result { reply_to = seq_to_int reply_to; outcome = callback_to_protocol result } }
  | Crash_notify { seq; failure } ->
      { seq = seq_to_int seq;
        body =
          Notify_crash
            {
              failure =
                Eta_crux.Failure.encode_portable failure
                |> Bytes.to_string;
            } }
  | Crash_result { seq; reply_to; result } ->
      { seq = seq_to_int seq; body = Crash_result { reply_to = seq_to_int reply_to; outcome = callback_to_protocol result } }
  | Endpoint_invoke { seq; handle; payload } ->
      { seq = seq_to_int seq; body = Invoke_endpoint { handle = bytes_to_string handle; payload = bytes_to_string payload } }
  | Endpoint_result { seq; reply_to; result } ->
      { seq = seq_to_int seq; body = Endpoint_result { reply_to = seq_to_int reply_to; outcome = endpoint_to_protocol result } }
  | Request_start { seq; handle; payload } ->
      { seq = seq_to_int seq; body = Start_request { handle = bytes_to_string handle; payload = bytes_to_string payload } }
  | Request_start_result { seq; reply_to; result } ->
      { seq = seq_to_int seq; body = Request_start_result { reply_to = seq_to_int reply_to; outcome = start_to_protocol result } }
  | Request_dispatch { seq; request; operation; payload } ->
      { seq = seq_to_int seq; body = Dispatch_request { request = bytes_to_string request; operation; payload = bytes_to_string payload } }
  | Request_dispatch_result { seq; reply_to; accepted } ->
      { seq = seq_to_int seq; body = Request_dispatch_result { reply_to = seq_to_int reply_to; outcome = if accepted then Dispatch_accepted else Dispatch_failed } }
  | Request_resolve { seq; request; payload } ->
      { seq = seq_to_int seq; body = Resolve_request { request = bytes_to_string request; payload = bytes_to_string payload } }
  | Request_resolve_result { seq; reply_to; result } ->
      let outcome = match result with `Identity identity -> identity_to_resolve identity | `Malformed_payload -> Resolve_malformed_payload in
      { seq = seq_to_int seq; body = Request_resolve_result { reply_to = seq_to_int reply_to; outcome } }
  | Request_cancel { seq; request } ->
      { seq = seq_to_int seq; body = Cancel_request { request = bytes_to_string request } }
  | Request_cancel_result { seq; reply_to; result } ->
      { seq = seq_to_int seq; body = Request_cancel_result { reply_to = seq_to_int reply_to; outcome = identity_to_cancel result } }
  | Request_resolved { seq; request; payload } ->
      { seq = seq_to_int seq; body = Request_resolved { request = bytes_to_string request; payload = bytes_to_string payload } }
  | Request_closed { seq; request; reason } ->
      { seq = seq_to_int seq; body = Request_closed { request = bytes_to_string request; reason = closure_to_protocol reason } }

let of_protocol frame =
  let seq = int_to_seq frame.Protocol.seq in
  match frame.body with
  | Protocol.Deliver_projection { reason; content } ->
      let content =
        match content with
        | Protocol.Projection_updates updates ->
            Frame.Updates
              (List.map projection_update_of_protocol updates)
        | Protocol.Projection_bootstrap entries ->
            Frame.Bootstrap
              (List.map projection_entry_of_protocol entries)
      in
      Ok
        (Frame.Projection_deliver
           {
             seq;
             reason =
               (match reason with
               | Advancement -> `Advancement
               | Session_replacement -> `Session_replacement);
             content;
           })
  | Projection_result { reply_to; outcome } ->
      Ok (Projection_result { seq; reply_to = int_to_seq reply_to; result = callback_of_protocol outcome })
  | Notify_crash { failure } ->
      (match
         Eta_crux.Failure.decode_portable
           (Bytes.of_string failure)
       with
      | Ok failure -> Ok (Crash_notify { seq; failure })
      | Error _ -> Error Eta_crux.Wire.Invalid_field)
  | Crash_result { reply_to; outcome } -> Ok (Crash_result { seq; reply_to = int_to_seq reply_to; result = callback_of_protocol outcome })
  | Invoke_endpoint { handle; payload } -> Ok (Endpoint_invoke { seq; handle = string_to_bytes handle; payload = string_to_bytes payload })
  | Endpoint_result { reply_to; outcome } -> Ok (Endpoint_result { seq; reply_to = int_to_seq reply_to; result = endpoint_of_protocol outcome })
  | Start_request { handle; payload } -> Ok (Request_start { seq; handle = string_to_bytes handle; payload = string_to_bytes payload })
  | Request_start_result { reply_to; outcome } -> Ok (Request_start_result { seq; reply_to = int_to_seq reply_to; result = start_of_protocol outcome })
  | Dispatch_request { request; operation; payload } -> Ok (Request_dispatch { seq; request = string_to_bytes request; operation; payload = string_to_bytes payload })
  | Request_dispatch_result { reply_to; outcome } -> Ok (Request_dispatch_result { seq; reply_to = int_to_seq reply_to; accepted = outcome = Dispatch_accepted })
  | Resolve_request { request; payload } -> Ok (Request_resolve { seq; request = string_to_bytes request; payload = string_to_bytes payload })
  | Request_resolve_result { reply_to; outcome } -> Ok (Request_resolve_result { seq; reply_to = int_to_seq reply_to; result = identity_of_resolve outcome })
  | Cancel_request { request } -> Ok (Request_cancel { seq; request = string_to_bytes request })
  | Request_cancel_result { reply_to; outcome } -> Ok (Request_cancel_result { seq; reply_to = int_to_seq reply_to; result = identity_of_cancel outcome })
  | Request_resolved { request; payload } -> Ok (Request_resolved { seq; request = string_to_bytes request; payload = string_to_bytes payload })
  | Request_closed { request; reason } -> Ok (Request_closed { seq; request = string_to_bytes request; reason = closure_of_protocol reason })

let protocol_error message =
  if String.starts_with ~prefix:"unknown tag" message then Eta_crux.Wire.Unknown_tag
  else if String.contains message 'b' && String.contains message '6' then Eta_crux.Wire.Noncanonical_bytes
  else Eta_crux.Wire.Malformed_frame

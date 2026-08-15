open Crux_engine

module Failure = Crux_failure.Failure
module Request = Crux_boundary.Request

module Wire = struct
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

  module Frame = struct
    type delivery_reason =
      [ `Advancement | `Session_replacement ]

    type delivery_result =
      [ `Accepted | `Failed of string ]

    type endpoint_result =
      [ `Accepted
      | `Full
      | `Ingress_closed
      | `Malformed_handle
      | `Unknown_handle
      | `Stale_handle
      | `Revoked_handle
      | `Malformed_payload ]

    type request_start_result =
      [ `Started of bytes
      | `Request_capacity_full
      | `Ingress_capacity_full
      | `Ingress_closed
      | `Malformed_handle
      | `Unknown_handle
      | `Stale_handle
      | `Revoked_handle
      | `Malformed_payload
      | `Closed of Request.closure_reason ]

    type request_identity_result =
      [ `Accepted
      | `Not_pending
      | `Malformed_request
      | `Unknown_request
      | `Stale_request ]

    type request_resolve_result =
      [ `Identity of request_identity_result | `Malformed_payload ]

    type projection_entry = {
      kind : string;
      key : bytes;
      incarnation : int64;
      value : bytes;
    }

    type projection_update =
      | Attached of projection_entry
      | Changed of projection_entry
      | Removed of {
          kind : string;
          key : bytes;
          incarnation : int64;
        }

    type projection_content =
      | Updates of projection_update list
      | Bootstrap of projection_entry list

    type t =
      | Projection_deliver of {
          seq : int32;
          reason : delivery_reason;
          content : projection_content;
        }
      | Projection_result of {
          seq : int32;
          reply_to : int32;
          result : delivery_result;
        }
      | Crash_notify of {
          seq : int32;
          failure : Failure.portable;
        }
      | Crash_result of {
          seq : int32;
          reply_to : int32;
          result : delivery_result;
        }
      | Endpoint_invoke of {
          seq : int32;
          handle : bytes;
          payload : bytes;
        }
      | Endpoint_result of {
          seq : int32;
          reply_to : int32;
          result : endpoint_result;
        }
      | Request_start of {
          seq : int32;
          handle : bytes;
          payload : bytes;
        }
      | Request_start_result of {
          seq : int32;
          reply_to : int32;
          result : request_start_result;
        }
      | Request_dispatch of {
          seq : int32;
          request : bytes;
          operation : string;
          payload : bytes;
        }
      | Request_dispatch_result of {
          seq : int32;
          reply_to : int32;
          accepted : bool;
        }
      | Request_resolve of {
          seq : int32;
          request : bytes;
          payload : bytes;
        }
      | Request_resolve_result of {
          seq : int32;
          reply_to : int32;
          result : request_resolve_result;
        }
      | Request_cancel of {
          seq : int32;
          request : bytes;
        }
      | Request_cancel_result of {
          seq : int32;
          reply_to : int32;
          result : request_identity_result;
        }
      | Request_resolved of {
          seq : int32;
          request : bytes;
          payload : bytes;
        }
      | Request_closed of {
          seq : int32;
          request : bytes;
          reason : Request.closure_reason;
        }
  end

  module type FORMAT = sig
    val encode : Frame.t -> bytes
    val decode : bytes -> (Frame.t, protocol_error) result
  end
end

module Serialized_session = struct
  module Seq_map = Map.Make (Int32)

  type format = Format : (module Wire.FORMAT) -> format

  type result_family =
    | Projection_result_family
    | Crash_result_family
    | Endpoint_result_family
    | Request_start_result_family
    | Request_dispatch_result_family
    | Request_resolve_result_family
    | Request_cancel_result_family

  type shared = {
    max_frame_bytes : int;
    format : format;
    incoming : (Wire.Frame.t, never) Eta.Queue.t;
    outgoing : (bytes, receive_error) Eta.Queue.t;
    lock : Eta.Sync_lock.t;
    mutable closed : bool;
    mutable expected_incoming : int32;
    mutable incoming_exhausted : bool;
    mutable next_outgoing : int32;
    mutable outgoing_exhausted : bool;
    mutable pending : result_family Seq_map.t;
    mutable wake : (unit -> unit) option;
  }

  and candidate = { shared : shared; mutable claimed : bool }
  and peer = { shared : shared }
  and admin = { replace_candidate : candidate -> replace_effect }

  and replace_effect =
    (replace_outcome, replace_error) Eta.Effect.t

  and receive_error =
    | Session_closed
    | Protocol_error of Wire.protocol_error

  and replace_error =
    | Starting
    | Replacement_pending
    | Awaiting_delivery
    | Terminating
    | Closed

  and replace_outcome =
    | Replaced
    | Stopped
    | Crashed of Failure.t

  let candidate ~max_frame_bytes ~format =
    if max_frame_bytes <= 0 then
      invalid_arg
        "Eta_crux.Serialized_session.candidate: max_frame_bytes must be positive";
    let shared =
      {
        max_frame_bytes;
        format = Format format;
        incoming = Eta.Queue.unbounded ();
        outgoing = Eta.Queue.unbounded ();
        lock = Eta.Sync_lock.create ();
        closed = false;
        expected_incoming = 0l;
        incoming_exhausted = false;
        next_outgoing = 0l;
        outgoing_exhausted = false;
        pending = Seq_map.empty;
        wake = None;
      }
    in
    ({ shared; claimed = false }, { shared })

  let frame_seq = function
    | Wire.Frame.Projection_deliver { seq; _ }
    | Projection_result { seq; _ }
    | Crash_notify { seq; _ }
    | Crash_result { seq; _ }
    | Endpoint_invoke { seq; _ }
    | Endpoint_result { seq; _ }
    | Request_start { seq; _ }
    | Request_start_result { seq; _ }
    | Request_dispatch { seq; _ }
    | Request_dispatch_result { seq; _ }
    | Request_resolve { seq; _ }
    | Request_resolve_result { seq; _ }
    | Request_cancel { seq; _ }
    | Request_cancel_result { seq; _ }
    | Request_resolved { seq; _ }
    | Request_closed { seq; _ } ->
        seq

  let valid_operation_name name =
    let length = String.length name in
    let valid_initial = function
      | 'a' .. 'z' -> true
      | _ -> false
    in
    let valid_rest = function
      | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
      | _ -> false
    in
    length > 0
    && length <= 128
    && valid_initial name.[0]
    &&
    let rec loop index =
      index = length
      || (valid_rest name.[index] && loop (index + 1))
    in
    loop 1

  let valid_utf8 value =
    let rec loop index =
      if index = String.length value then true
      else
        let decoded = String.get_utf_8_uchar value index in
        Uchar.utf_decode_is_valid decoded
        && loop (index + Uchar.utf_decode_length decoded)
    in
    loop 0

  let validate_frame = function
    | Wire.Frame.Projection_deliver
        {
          reason = `Advancement;
          content = Updates _;
          _;
        }
    | Projection_deliver
        {
          reason = `Session_replacement;
          content = Bootstrap _;
          _;
        } ->
        Ok ()
    | Projection_deliver _ -> Error Wire.Invalid_field
    | Projection_result { result = `Failed diagnostic; _ }
      when String.length diagnostic > 1024
           || not (valid_utf8 diagnostic) ->
        Error Wire.Invalid_field
    | Wire.Frame.Endpoint_invoke { handle; _ }
    | Request_start { handle; _ } ->
        if Bytes.length handle <= 64 then Ok ()
        else Error Wire.Invalid_field
    | Request_dispatch { request; operation; _ } ->
        if Bytes.length request > 64 then Error Wire.Invalid_field
        else if not (valid_operation_name operation) then
          Error Wire.Invalid_operation_name
        else Ok ()
    | Request_resolve { request; _ }
    | Request_cancel { request; _ }
    | Request_resolved { request; _ }
    | Request_closed { request; _ } ->
        if Bytes.length request <= 64 then Ok ()
        else Error Wire.Invalid_field
    | Projection_result _ | Crash_notify _
    | Crash_result _ | Endpoint_result _ | Request_start_result _
    | Request_dispatch_result _ | Request_resolve_result _
    | Request_cancel_result _ ->
        Ok ()

  let result_frame = function
    | Wire.Frame.Projection_result { reply_to; _ } ->
        Some (reply_to, Projection_result_family)
    | Crash_result { reply_to; _ } ->
        Some (reply_to, Crash_result_family)
    | Endpoint_result { reply_to; _ } ->
        Some (reply_to, Endpoint_result_family)
    | Request_start_result { reply_to; _ } ->
        Some (reply_to, Request_start_result_family)
    | Request_dispatch_result { reply_to; _ } ->
        Some (reply_to, Request_dispatch_result_family)
    | Request_resolve_result { reply_to; _ } ->
        Some (reply_to, Request_resolve_result_family)
    | Request_cancel_result { reply_to; _ } ->
        Some (reply_to, Request_cancel_result_family)
    | Projection_deliver _ | Crash_notify _ | Endpoint_invoke _
    | Request_start _ | Request_dispatch _ | Request_resolve _
    | Request_cancel _ | Request_resolved _ | Request_closed _ ->
        None

  let expected_result_family = function
    | Wire.Frame.Projection_deliver _ -> Some Projection_result_family
    | Crash_notify _ -> Some Crash_result_family
    | Endpoint_invoke _ -> Some Endpoint_result_family
    | Request_start _ -> Some Request_start_result_family
    | Request_dispatch _ -> Some Request_dispatch_result_family
    | Request_resolve _ -> Some Request_resolve_result_family
    | Request_cancel _ -> Some Request_cancel_result_family
    | Projection_result _ | Crash_result _ | Endpoint_result _
    | Request_start_result _ | Request_dispatch_result _
    | Request_resolve_result _ | Request_cancel_result _
    | Request_resolved _ | Request_closed _ ->
        None

  let close_with_protocol_error shared error =
    shared.closed <- true;
    Eta.Queue.shutdown shared.incoming;
    Eta.Queue.shutdown shared.outgoing;
    Error (Protocol_error error)

  let notify wake = Option.iter (fun wake -> wake ()) wake

  let receive (peer : peer) bytes =
    Eta.Effect.sync (fun () ->
        let result, wake =
          Eta.Sync_lock.use peer.shared.lock @@ fun () ->
          let result =
            if peer.shared.closed then Error Session_closed
            else if Bytes.length bytes > peer.shared.max_frame_bytes then
              close_with_protocol_error peer.shared
                Wire.Frame_too_large
            else
              let Format (module Format) = peer.shared.format in
              match Format.decode bytes with
              | Error error ->
                  close_with_protocol_error peer.shared error
              | Ok frame -> (
                  match validate_frame frame with
                  | Error error ->
                      close_with_protocol_error peer.shared error
                  | Ok () ->
                      let sequence = frame_seq frame in
                      if peer.shared.incoming_exhausted then
                        close_with_protocol_error peer.shared
                          Wire.Sequence_exhausted
                      else if
                        sequence <> peer.shared.expected_incoming
                      then
                        close_with_protocol_error peer.shared
                          Wire.Bad_sequence
                      else
                        let correlation =
                          match result_frame frame with
                          | None -> Ok ()
                          | Some (reply_to, family) -> (
                              match
                                Seq_map.find_opt reply_to
                                  peer.shared.pending
                              with
                              | None -> Error Wire.Unknown_reply
                              | Some expected
                                when expected <> family ->
                                  Error Wire.Wrong_result_family
                              | Some _ ->
                                  peer.shared.pending <-
                                    Seq_map.remove reply_to
                                      peer.shared.pending;
                                  Ok ())
                        in
                        (match correlation with
                        | Error error ->
                            close_with_protocol_error peer.shared
                              error
                        | Ok () ->
                            if sequence = Int32.minus_one then
                              peer.shared.incoming_exhausted <- true
                            else
                              peer.shared.expected_incoming <-
                                Int32.add sequence 1l;
                            ignore
                              (Eta.Queue.try_offer_now
                                 peer.shared.incoming frame : _);
                            Ok ()))
          in
          (result, peer.shared.wake)
        in
        notify wake;
        result)

  let send candidate make_frame =
    let result, wake =
      Eta.Sync_lock.use candidate.shared.lock @@ fun () ->
      let shared = candidate.shared in
      let result =
        if shared.closed then Error Session_closed
        else if shared.outgoing_exhausted then
          close_with_protocol_error shared Wire.Sequence_exhausted
        else
          let sequence = shared.next_outgoing in
          let frame = make_frame sequence in
          match validate_frame frame with
          | Error error -> close_with_protocol_error shared error
          | Ok () ->
              let Format (module Format) = shared.format in
              let encoded = Format.encode frame in
              if Bytes.length encoded > shared.max_frame_bytes then
                close_with_protocol_error shared Wire.Frame_too_large
              else
                match
                  Eta.Queue.try_offer_now shared.outgoing encoded
                with
                | `Sent ->
                    (match expected_result_family frame with
                    | None -> ()
                    | Some family ->
                        shared.pending <-
                          Seq_map.add sequence family
                            shared.pending);
                    if sequence = Int32.minus_one then
                      shared.outgoing_exhausted <- true
                    else
                      shared.next_outgoing <-
                        Int32.add sequence 1l;
                    Ok sequence
                | `Closed | `Closed_with_error _ ->
                    shared.closed <- true;
                    Error Session_closed
                | `Full | `Dropped ->
                    invalid_arg
                      "Eta_crux.Serialized_session: unbounded outgoing queue rejected a frame"
      in
      let wake =
        match result with
        | Ok _ -> None
        | Error _ -> shared.wake
      in
      (result, wake)
    in
    notify wake;
    result

  let poll_incoming candidate =
    Eta.Queue.poll_now candidate.shared.incoming

  let fail_protocol candidate error =
    let wake =
      Eta.Sync_lock.use candidate.shared.lock @@ fun () ->
      if not candidate.shared.closed then
        ignore
          (close_with_protocol_error candidate.shared error :
            (_, _) result);
      candidate.shared.wake
    in
    notify wake

  let poll_outgoing (peer : peer) =
    Eta.Effect.sync (fun () ->
        match Eta.Queue.poll_now peer.shared.outgoing with
        | `Item bytes -> Some bytes
        | `Empty | `Closed -> None
        | `Closed_with_error _ -> None)

  let await_outgoing (peer : peer) =
    Eta.Queue.take peer.shared.outgoing
    |> Eta.Effect.map_error (function
         | `Closed -> Session_closed
         | `Closed_with_error error -> error)

  let replace admin candidate = admin.replace_candidate candidate

  let claim candidate =
    Eta.Sync_lock.use candidate.shared.lock @@ fun () ->
    if candidate.claimed then false
    else (
      candidate.claimed <- true;
      true)

  let set_wake candidate wake =
    Eta.Sync_lock.use candidate.shared.lock @@ fun () ->
    candidate.shared.wake <- Some wake

  let close candidate =
    let wake =
      Eta.Sync_lock.use candidate.shared.lock @@ fun () ->
      if not candidate.shared.closed then (
        candidate.shared.closed <- true;
        Eta.Queue.shutdown candidate.shared.incoming;
        Eta.Queue.shutdown candidate.shared.outgoing);
      candidate.shared.wake
    in
    notify wake

  let close_candidate candidate =
    if not candidate.claimed then close candidate
end

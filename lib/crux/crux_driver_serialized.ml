open Crux_engine
open Crux_boundary
open Crux_driver_base

module Failure = Crux_failure.Failure
module Host_operation = Crux_boundary.Host_operation
module Request = Crux_boundary.Request
module Wire = Crux_wire.Wire
module Serialized_session = Crux_wire.Serialized_session
module Remote_registry = Crux_remote_registry

let serialized_incoming (driver : t) =
  match driver.binding.mode with
  | Identity -> `Empty
  | Serialized serialized -> (
      match
        Serialized_session.poll_incoming serialized.candidate
      with
      | `Closed ->
          let first =
            Eta.Sync_lock.use driver.lock @@ fun () ->
            if serialized.closure_observed then false
            else (
              serialized.closure_observed <- true;
              true)
          in
          if first then `Closed else `Empty
      | result -> result)

let fresh_request_token (driver : t) =
  Eta.Sync_lock.use driver.lock @@ fun () ->
  if driver.next_request_token = Int64.max_int then
    invalid_arg "Eta_crux.Driver: request token overflow";
  let token =
    Printf.sprintf "r%Lx" driver.next_request_token
  in
  driver.next_request_token <-
    Int64.add driver.next_request_token 1L;
  token

let close_remote_request (driver : t) token =
  Eta.Sync_lock.use driver.lock @@ fun () ->
  let event =
    String_map.find_opt token driver.remote_requests
  in
  driver.remote_requests <-
    String_map.remove token driver.remote_requests;
  event

let take_request_command (driver : t) sequence =
  Eta.Sync_lock.use driver.lock @@ fun () ->
  let command =
    Seq_map.find_opt sequence driver.request_commands
  in
  driver.request_commands <-
    Seq_map.remove sequence driver.request_commands;
  command

let close_session_requests (driver : t) =
  let events, inbound =
    Eta.Sync_lock.use driver.lock @@ fun () ->
    let events =
      driver.remote_requests
      |> String_map.bindings
      |> List.map snd
    in
    driver.remote_requests <- String_map.empty;
    let inbound =
      driver.inbound_requests
      |> String_map.bindings
      |> List.map snd
    in
    driver.inbound_requests <- String_map.empty;
    driver.request_commands <- Seq_map.empty;
    (events, inbound)
  in
  let outbound =
    events
    |> List.map
         (fun (Request.Driver_event.Event state) ->
           Request.close_state state Request.Session_closed
           |> Eta.Effect.map (fun _ -> ()))
  in
  let inbound =
    inbound
    |> List.map (fun request ->
           request.close Boundary_session_closed
           |> Eta.Effect.map (fun _ -> ()))
  in
  outbound @ inbound
  |> Eta.Effect.concat
  |> Eta.Effect.map (fun () -> ())

let adapter_delivery_cause message =
  Failure.Packed_cause.make
    ~pp_error:Format.pp_print_string
    (Eta.Cause.fail message)

let latch_adapter_delivery_failure (driver : t) cause =
  latch_failure_record driver.root.core
    (failure_record driver.root.core
       ~origin:Failure.Adapter_delivery
       ~trigger:Failure.Projection_delivery cause);
  Eta.Sync_lock.use driver.root.core.lock @@ fun () ->
  Option.get (Atomic.get driver.root.core.failure)

let handle_session_closed (driver : t) =
  let open Eta.Syntax in
  let* () = close_session_requests driver in
  let* () =
    match state driver with
    | Delivering (delivery, _) ->
        Delivery.failed delivery
          (adapter_delivery_cause
             "serialized session closed during projection delivery")
        |> Eta.Effect.map_error absurd
        |> Eta.Effect.map (fun _ -> ())
    | Replacement_delivering (_, completion) ->
        let failure =
          latch_adapter_delivery_failure driver
            (adapter_delivery_cause
               "serialized session closed during replacement delivery")
        in
        Eta.Sync_lock.use driver.lock (fun () ->
            (match driver.binding.mode with
            | Identity -> ()
            | Serialized serialized ->
                serialized.replacement_pending <- false);
            driver.state <- Running);
        Eta.Promise.resolve completion
          (Eta.Exit.Ok (Serialized_session.Crashed failure))
        |> Eta.Effect.map (fun _ -> ())
    | Crash_notifying (failure, post_commit, _) ->
        set_state driver (Crash_teardown (failure, post_commit));
        Eta.Effect.unit
    | Crash_settled_notifying (settlement, _) ->
        set_state driver (Crash_closed_pending settlement);
        Eta.Effect.unit
    | Running | Advancing | Crash_detected_pending _ | Crash_teardown _
    | Crash_settled_pending _ | Crash_closed_pending _
    | Stopped_closed_pending | Closed_done ->
        Eta.Effect.unit
  in
  Eta.Effect.sync (fun () -> wake driver)

let send_request_cancellation (driver : t)
    (serialized : serialized_binding) token =
  match
    Serialized_session.send serialized.candidate
      (fun seq ->
        Wire.Frame.Request_cancel
          { seq; request = Bytes.of_string token })
  with
  | Error _ ->
      ignore (close_remote_request driver token)
  | Ok sequence ->
      Eta.Sync_lock.use driver.lock @@ fun () ->
      driver.request_commands <-
        Seq_map.add sequence
          (Request_cancel_command token)
          driver.request_commands

let dispatch_serialized_request (driver : t)
    (serialized : serialized_binding)
    ((Request.Driver_event.Event state as event) :
      Request.Driver_event.t) =
  let token = fresh_request_token driver in
  let dispatch_lock = Eta.Sync_lock.create () in
  let cancelled = ref false in
  let dispatched = ref false in
  Request.Driver_event.on_cancel state (fun _reason ->
      let send_now =
        Eta.Sync_lock.use dispatch_lock @@ fun () ->
        cancelled := true;
        !dispatched
      in
      if send_now then
        send_request_cancellation driver serialized token);
  let pending =
    Eta.Sync_lock.use state.lock @@ fun () -> state.pending
  in
  if not pending then (
    Eta.Sync_lock.use dispatch_lock @@ fun () ->
    cancelled := true);
  let cancelled_before_encode =
    Eta.Sync_lock.use dispatch_lock @@ fun () -> !cancelled
  in
  if cancelled_before_encode then Eta.Effect.pure None
  else
    let payload = state.encoded in
    let cancelled_before_dispatch =
          Eta.Sync_lock.use dispatch_lock @@ fun () ->
          !cancelled
        in
        if cancelled_before_dispatch then Eta.Effect.pure None
        else (
          match
            Serialized_session.send serialized.candidate
              (fun seq ->
                Wire.Frame.Request_dispatch
                  {
                    seq;
                    request = Bytes.of_string token;
                    operation =
                      Host_operation.name state.operation;
                    payload;
                  })
          with
          | Error _ ->
              Request.close_state state Request.Session_closed
              |> Eta.Effect.map (fun _ -> None)
          | Ok sequence ->
              Eta.Sync_lock.use driver.lock (fun () ->
                  driver.request_commands <-
                    Seq_map.add sequence
                      (Request_dispatch_command token)
                      driver.request_commands;
                  driver.remote_requests <-
                    String_map.add token event
                      driver.remote_requests);
              let send_cancellation =
                Eta.Sync_lock.use dispatch_lock @@ fun () ->
                dispatched := true;
                !cancelled
              in
              if send_cancellation then
                send_request_cancellation driver serialized token;
              Eta.Effect.pure None)

let send_serialized_result (driver : t) make_frame =
  match driver.binding.mode with
  | Identity -> Eta.Effect.pure None
  | Serialized serialized ->
      ignore
        (Serialized_session.send serialized.candidate make_frame :
          (_, _) result);
      Eta.Effect.pure None

let request_closure_frame = function
  | Boundary_initiator_cancelled ->
      Request.Initiator_cancelled
  | Boundary_owner_disposed -> Request.Owner_disposed
  | Boundary_root_stopped -> Request.Root_stopped
  | Boundary_root_crashed -> Request.Root_crashed
  | Boundary_session_closed -> Request.Session_closed

let remove_inbound_request (driver : t) token =
  Eta.Sync_lock.use driver.lock @@ fun () ->
  driver.inbound_requests <-
    String_map.remove token driver.inbound_requests

let monitor_inbound_request (driver : t) candidate token request =
  let open Eta.Syntax in
  let* completion = request.completion in
  match completion with
  | Boundary_request_cancelled_by_peer ->
      Eta.Effect.sync (fun () ->
          remove_inbound_request driver token)
  | Boundary_request_closed reason ->
      Eta.Effect.sync (fun () ->
          remove_inbound_request driver token;
          ignore
            (Serialized_session.send candidate
               (fun seq ->
                 Wire.Frame.Request_closed
                   {
                     seq;
                     request = Bytes.of_string token;
                     reason = request_closure_frame reason;
                   }) : (_, _) result))
  | Boundary_request_resolved payload ->
      Eta.Effect.sync (fun () ->
          match
            Serialized_session.send candidate
              (fun seq ->
                Wire.Frame.Request_resolve
                  {
                    seq;
                    request = Bytes.of_string token;
                    payload;
                  })
          with
          | Error _ ->
              remove_inbound_request driver token
          | Ok sequence ->
              Eta.Sync_lock.use driver.lock @@ fun () ->
              driver.request_commands <-
                Seq_map.add sequence
                  (Inbound_resolve_command token)
                  driver.request_commands)

let handle_serialized_frame (driver : t) frame =
  match frame with
  | Wire.Frame.Projection_result { reply_to; result; _ } -> (
      match state driver with
      | Replacement_delivering (expected, completion)
        when expected = reply_to ->
          let outcome =
            match result with
            | `Accepted ->
                Eta.Sync_lock.use driver.root.core.lock @@ fun () ->
                (match Atomic.get driver.root.core.failure with
                | Some failure ->
                    Serialized_session.Crashed failure
                | None when Atomic.get driver.root.core.stop_requested ->
                    Serialized_session.Stopped
                | None -> Serialized_session.Replaced)
            | `Failed message ->
                let cause =
                  Failure.Packed_cause.make
                    ~pp_error:Format.pp_print_string
                    (Eta.Cause.fail message)
                in
                latch_failure_record driver.root.core
                  (failure_record driver.root.core
                     ~origin:Failure.Adapter_delivery
                     ~trigger:Failure.Projection_delivery cause);
                let failure =
                  Eta.Sync_lock.use driver.root.core.lock @@ fun () ->
                  Option.get (Atomic.get driver.root.core.failure)
                in
                Serialized_session.Crashed failure
          in
          Eta.Sync_lock.use driver.lock (fun () ->
              (match driver.binding.mode with
              | Identity -> ()
              | Serialized serialized ->
                  serialized.replacement_pending <- false);
              driver.state <- Running);
          Eta.Promise.resolve completion (Eta.Exit.Ok outcome)
          |> Eta.Effect.map (fun _ -> None)
      | Delivering (delivery, Some expected) when expected = reply_to ->
          let answer =
            match result with
            | `Accepted -> Delivery.delivered delivery
            | `Failed message ->
                let cause =
                  Failure.Packed_cause.make
                    ~pp_error:Format.pp_print_string
                    (Eta.Cause.fail message)
                in
                Delivery.failed delivery cause
          in
          answer
          |> Eta.Effect.map_error absurd
          |> Eta.Effect.map (fun _ -> None)
      | Running | Advancing | Delivering _ | Replacement_delivering _
      | Crash_detected_pending _ | Crash_notifying _
      | Crash_teardown _ | Crash_settled_pending _
      | Crash_settled_notifying _
      | Crash_closed_pending _ | Stopped_closed_pending
      | Closed_done ->
          Eta.Effect.pure None)
  | Crash_result { reply_to; result; _ } ->
      let record_delivery_failure message =
        let cause =
          Failure.Packed_cause.make
            ~pp_error:Format.pp_print_string
            (Eta.Cause.fail message)
        in
        latch_failure_record driver.root.core
          (failure_record driver.root.core
             ~origin:Failure.Adapter_delivery
             ~trigger:Failure.Projection_delivery cause)
      in
      (match state driver with
      | Crash_notifying (failure, post_commit, expected)
        when expected = reply_to ->
          (match result with
          | `Accepted -> ()
          | `Failed message ->
              record_delivery_failure message);
          set_state driver (Crash_teardown (failure, post_commit));
          Eta.Effect.pure None
      | Crash_settled_notifying (settlement, expected)
        when expected = reply_to ->
          (match result with
          | `Accepted -> ()
          | `Failed message ->
              record_delivery_failure message);
          set_state driver (Crash_closed_pending settlement);
          Eta.Effect.pure None
      | Running | Advancing | Delivering _ | Replacement_delivering _
      | Crash_detected_pending _ | Crash_notifying _
      | Crash_teardown _ | Crash_settled_pending _
      | Crash_settled_notifying _
      | Crash_closed_pending _ | Stopped_closed_pending
      | Closed_done ->
          Eta.Effect.pure None)
  | Request_dispatch_result
      { reply_to; accepted; _ } -> (
      match take_request_command driver reply_to with
      | Some (Request_dispatch_command token) -> (
          match
            Eta.Sync_lock.use driver.lock @@ fun () ->
            String_map.find_opt token driver.remote_requests
          with
          | None -> Eta.Effect.pure None
          | Some event ->
              if accepted then
                Request.Driver_event.accepted event
                |> Eta.Effect.map_error absurd
                |> Eta.Effect.map (fun _ -> None)
              else
                let _ = close_remote_request driver token in
                let cause =
                  Failure.Packed_cause.make
                    ~pp_error:Format.pp_print_string
                    (Eta.Cause.fail
                       "remote request dispatch failed")
                in
                Request.Driver_event.failed event cause
                |> Eta.Effect.map_error absurd
                |> Eta.Effect.map (fun _ -> None))
      | Some (Request_cancel_command _)
      | Some (Inbound_resolve_command _) | None ->
          Eta.Effect.pure None)
  | Request_cancel_result { reply_to; _ } -> (
      match take_request_command driver reply_to with
      | Some (Request_cancel_command token) ->
          ignore (close_remote_request driver token);
          Eta.Effect.pure None
      | Some (Request_dispatch_command _)
      | Some (Inbound_resolve_command _) | None ->
          Eta.Effect.pure None)
  | Request_resolve_result { reply_to; _ } -> (
      match take_request_command driver reply_to with
      | Some (Inbound_resolve_command token) ->
          remove_inbound_request driver token;
          Eta.Effect.pure None
      | Some (Request_dispatch_command _)
      | Some (Request_cancel_command _) | None ->
          Eta.Effect.pure None)
  | Request_resolved { request; payload; _ } ->
      let token = Bytes.to_string request in
      (match close_remote_request driver token with
      | None -> Eta.Effect.pure None
      | Some (Request.Driver_event.Event state) -> (
          let decoded =
            try
              `Result
                (Codec.decode
                   (Host_operation.response_codec
                      state.operation)
                   payload)
            with exn -> `Raised exn
          in
          match decoded with
          | `Raised exn ->
              let cause =
                Failure.Packed_cause.make
                  ~pp_error:(fun _ (value : never) ->
                    absurd value)
                  (Eta.Cause.die exn)
              in
              Request.Driver_event.failed_inbound_response
                (Request.Driver_event.Event state)
                cause
              |> Eta.Effect.map_error absurd
              |> Eta.Effect.map (fun _ -> None)
          | `Result (Error error) ->
              Request.fail_decode state error
              |> Eta.Effect.map (fun _ -> None)
          | `Result (Ok response) ->
              Request.Driver_event.resolve state response
              |> Eta.Effect.map (fun _ -> None)))
  | Request_closed { request; reason; _ } ->
      let token = Bytes.to_string request in
      (match close_remote_request driver token with
      | None -> Eta.Effect.pure None
      | Some (Request.Driver_event.Event state) ->
          Request.close_state state reason
          |> Eta.Effect.map (fun _ -> None))
  | Endpoint_invoke { seq = reply_to; handle; payload } ->
      let result =
        match driver.binding.mode with
        | Identity -> `Unknown_handle
        | Serialized serialized -> (
            let lookup =
              Eta.Sync_lock.use serialized.registry_lock
                (fun () ->
                  Remote_registry.lookup serialized.registry
                    handle)
            in
            match lookup with
            | Remote_registry.Malformed -> `Malformed_handle
            | Remote_registry.Unknown -> `Unknown_handle
            | Remote_registry.Stale -> `Stale_handle
            | Remote_registry.Revoked -> `Revoked_handle
            | Remote_registry.Found
                {
                  kind =
                    Boundary_endpoint { invoke };
                  _;
                } -> (
                match invoke payload with
                | Boundary_endpoint_accepted -> `Accepted
                | Boundary_endpoint_full -> `Full
                | Boundary_endpoint_ingress_closed ->
                    `Ingress_closed
                | Boundary_endpoint_revoked ->
                    `Revoked_handle
                | Boundary_endpoint_malformed_payload ->
                    `Malformed_payload)
            | Remote_registry.Found
                { kind = Boundary_request _; _ } ->
                `Unknown_handle)
      in
      send_serialized_result driver (fun seq ->
          Wire.Frame.Endpoint_result
            { seq; reply_to; result })
  | Request_start { seq = reply_to; handle; payload } ->
      let open Eta.Syntax in
      let candidate, start =
        match driver.binding.mode with
        | Identity ->
            (None, Eta.Effect.pure Boundary_request_revoked)
        | Serialized serialized ->
            let lookup =
              Eta.Sync_lock.use serialized.registry_lock
                (fun () ->
                  Remote_registry.lookup serialized.registry
                    handle)
            in
            let start =
              match lookup with
              | Remote_registry.Malformed ->
                  Eta.Effect.pure
                    Boundary_request_malformed_handle
              | Remote_registry.Unknown ->
                  Eta.Effect.pure
                    Boundary_request_unknown_handle
              | Remote_registry.Stale ->
                  Eta.Effect.pure
                    Boundary_request_stale_handle
              | Remote_registry.Revoked ->
                  Eta.Effect.pure Boundary_request_revoked
              | Remote_registry.Found
                  {
                    kind = Boundary_request { start; _ };
                    _;
                  } ->
                  start payload
              | Remote_registry.Found
                  { kind = Boundary_endpoint _; _ } ->
                  Eta.Effect.pure Boundary_request_revoked
            in
            (Some serialized.candidate, start)
      in
      let* started = start in
      (match started, candidate with
      | Boundary_request_started request,
        Some candidate ->
          let token = fresh_request_token driver in
          Eta.Sync_lock.use driver.lock (fun () ->
              driver.inbound_requests <-
                String_map.add token request
                  driver.inbound_requests);
          let sent =
            Serialized_session.send candidate (fun seq ->
                Wire.Frame.Request_start_result
                  {
                    seq;
                    reply_to;
                    result =
                      `Started (Bytes.of_string token);
                  })
          in
          (match sent with
          | Error _ ->
              remove_inbound_request driver token;
              let+ _ =
                request.close Boundary_session_closed
              in
              None
          | Ok _ ->
              let+ () =
                Eta.Spi.daemon
                  (monitor_inbound_request driver candidate
                     token request)
              in
              None)
      | result, _ ->
          let result =
            match result with
            | Boundary_request_started _ ->
                `Unknown_handle
            | Boundary_request_capacity_full ->
                `Request_capacity_full
            | Boundary_ingress_capacity_full ->
                `Ingress_capacity_full
            | Boundary_request_ingress_closed ->
                `Ingress_closed
            | Boundary_request_malformed_handle ->
                `Malformed_handle
            | Boundary_request_unknown_handle ->
                `Unknown_handle
            | Boundary_request_stale_handle ->
                `Stale_handle
            | Boundary_request_revoked ->
                `Revoked_handle
            | Boundary_request_malformed_payload ->
                `Malformed_payload
          in
          send_serialized_result driver (fun seq ->
              Wire.Frame.Request_start_result
                { seq; reply_to; result }))
  | Request_resolve { seq = reply_to; _ } ->
      send_serialized_result driver (fun seq ->
          Wire.Frame.Request_resolve_result
            {
              seq;
              reply_to;
              result = `Identity `Unknown_request;
            })
  | Request_cancel { seq = reply_to; request } ->
      let token = Bytes.to_string request in
      let inbound =
        Eta.Sync_lock.use driver.lock @@ fun () ->
        String_map.find_opt token driver.inbound_requests
      in
      (match inbound with
      | None ->
          send_serialized_result driver (fun seq ->
              Wire.Frame.Request_cancel_result
                {
                  seq;
                  reply_to;
                  result = `Unknown_request;
                })
      | Some request ->
          let open Eta.Syntax in
          let* result = request.cancel_by_peer () in
          let result =
            match result with
            | Boundary_request_accepted -> `Accepted
            | Boundary_request_not_pending -> `Not_pending
          in
          send_serialized_result driver (fun seq ->
              Wire.Frame.Request_cancel_result
                { seq; reply_to; result }))
  | Endpoint_result _
  | Request_start_result _
  | Request_dispatch _
  | Projection_deliver _ | Crash_notify _ ->
      Eta.Effect.pure None

open Crux_engine
open Crux_boundary
open Crux_driver_base

module Failure = Crux_failure.Failure
module Host_operation = Crux_boundary.Host_operation
module Request = Crux_boundary.Request
module Wire = Crux_wire.Wire
module Serialized_session = Crux_wire.Serialized_session
module Projection = Crux_projection
module Remote_registry = Crux_remote_registry

let serialized_incoming (driver : t) =
  match driver.binding.mode with
  | Identity -> `Empty
  | Serialized serialized ->
      Eta.Sync_lock.use driver.lock @@ fun () ->
      if serialized.replacement_installing || serialized.incoming_claimed then
        `Empty
      else
        match
          Serialized_session.poll_incoming serialized.candidate
        with
        | `Item _ as result ->
            serialized.incoming_claimed <- true;
            result
        | `Closed ->
            if serialized.closure_observed then `Empty
            else (
              serialized.closure_observed <- true;
              serialized.incoming_claimed <- true;
              `Closed)
        | (`Closed_with_error _ | `Empty) as result -> result

let release_serialized_incoming (driver : t) =
  Eta.Effect.sync (fun () ->
      match driver.binding.mode with
      | Identity -> ()
      | Serialized serialized ->
          Eta.Sync_lock.use driver.lock (fun () ->
              serialized.incoming_claimed <- false);
          wake driver)

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

let take_session_requests_locked (driver : t) =
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

let close_requests events inbound =
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

let close_session_requests (driver : t) =
  let events, inbound =
    Eta.Sync_lock.use driver.lock @@ fun () ->
    take_session_requests_locked driver
  in
  close_requests events inbound

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

let prepare_remote_handles (driver : t)
    (serialized : serialized_binding) registry =
  let exports =
    Eta.Sync_lock.use driver.root.core.lock @@ fun () ->
    driver.root.core.boundary_exports
  in
  Eta.Sync_lock.use serialized.registry_lock @@ fun () ->
  Remote_registry.synchronize registry exports;
  Remote_registry.handles registry

let remote_handles driver serialized registry =
  let handles = prepare_remote_handles driver serialized registry in
  fun f ->
    with_remote_handles
      (fun identity -> Int_map.find_opt identity handles)
      f

let encode_entry with_handles kind
    (entry : (_, _) Projection.entry) =
  match Codec.encode (Projection.Kind.key_codec kind) entry.key with
  | Error (error : Codec.encode_error) -> Error error.message
  | Ok key -> (
      match
        with_handles (fun () ->
            Codec.encode
              (Projection.Kind.value_codec kind)
              entry.value)
      with
      | Error (error : Codec.encode_error) -> Error error.message
      | Ok value ->
          Ok
            {
              Wire.Frame.kind = Projection.Kind.name kind;
              key;
              incarnation =
                Projection.Incarnation.to_int64 entry.incarnation;
              value;
            })

let encode_snapshot driver serialized registry snapshot =
  let with_handles = remote_handles driver serialized registry in
  Projection.Snapshot.fold snapshot ~init:(Ok [])
    ~f:(fun encoded (Projection.Snapshot.Pack (kind, entry)) ->
      match encoded with
      | Error _ as error -> error
      | Ok reversed -> (
          match encode_entry with_handles kind entry with
          | Error _ as error -> error
          | Ok entry -> Ok (entry :: reversed)))
  |> Result.map List.rev

let encode_batch driver serialized registry batch =
  let with_handles = remote_handles driver serialized registry in
  Projection.Batch.fold batch ~init:(Ok [])
    ~f:(fun encoded (Projection.Batch.Pack (kind, update)) ->
      match encoded with
      | Error _ as error -> error
      | Ok reversed -> (
          match update with
          | Projection.Attached entry -> (
              match encode_entry with_handles kind entry with
              | Error _ as error -> error
              | Ok entry ->
                  Ok (Wire.Frame.Attached entry :: reversed))
          | Projection.Changed entry -> (
              match encode_entry with_handles kind entry with
              | Error _ as error -> error
              | Ok entry ->
                  Ok (Wire.Frame.Changed entry :: reversed))
          | Projection.Removed { key; incarnation } -> (
              match Codec.encode (Projection.Kind.key_codec kind) key with
              | Error (error : Codec.encode_error) -> Error error.message
              | Ok key ->
                  Ok
                    (Wire.Frame.Removed
                       {
                         kind = Projection.Kind.name kind;
                         key;
                         incarnation =
                           Projection.Incarnation.to_int64 incarnation;
                       }
                    :: reversed))))
  |> Result.map List.rev

let encode_projection driver serialized registry = function
  | Projection.Updates batch ->
      encode_batch driver serialized registry batch
      |> Result.map (fun updates -> Wire.Frame.Updates updates)
  | Projection.Bootstrap snapshot ->
      encode_snapshot driver serialized registry snapshot
      |> Result.map (fun entries -> Wire.Frame.Bootstrap entries)

let encoded_projection_or_delivery_cause driver serialized registry projection =
  match encode_projection driver serialized registry projection with
  | Ok content -> Ok content
  | Error message -> Error (adapter_delivery_cause message)

let send_advancement driver serialized projection =
  try
    match
      encoded_projection_or_delivery_cause driver serialized
        serialized.registry projection
    with
    | Error cause -> Error cause
    | Ok content -> (
        match
          Serialized_session.send serialized.candidate (fun seq ->
              Wire.Frame.Projection_deliver
                {
                  seq;
                  reason = `Advancement;
                  content;
                })
        with
        | Ok reply_to -> Ok reply_to
        | Error _ ->
            Error
              (adapter_delivery_cause
                 "serialized session closed during projection delivery"))
  with exn ->
    Error
      (Failure.Packed_cause.make
         ~pp_error:(fun _ (value : never) -> absurd value)
         (Eta.Cause.die exn))

let replace_session (driver : t) (serialized : serialized_binding)
    candidate =
  let open Eta.Syntax in
  let initiate =
    let rec claim_snapshot () =
      let* claim =
        Eta.Effect.sync (fun () ->
            Eta.Sync_lock.use driver.lock @@ fun () ->
            if serialized.replacement_pending then
              `Error Serialized_session.Replacement_pending
            else if serialized.incoming_claimed then `Retry
            else
              match driver.state, driver.last_snapshot with
              | Advancing, _ -> `Retry
              | Closed_done, _ -> `Error Serialized_session.Closed
              | (Crash_detected_pending _ | Crash_notifying _
                | Crash_teardown _ | Crash_settled_pending _
                | Crash_settled_notifying _ | Crash_closed_pending _
                | Stopped_closed_pending),
                _ ->
                  `Error Serialized_session.Terminating
              | Delivering _, _ | Replacement_delivering _, _ ->
                  `Error Serialized_session.Awaiting_delivery
              | Running, None -> `Error Serialized_session.Starting
              | Running, Some snapshot ->
                  serialized.replacement_pending <- true;
                  serialized.replacement_installing <- true;
                  `Snapshot snapshot)
      in
      match claim with
      | `Snapshot snapshot -> Eta.Effect.pure snapshot
      | `Error error -> Eta.Effect.fail error
      | `Retry ->
          let* () = Eta.Effect.yield in
          claim_snapshot ()
    in
    let* snapshot = claim_snapshot () in
    let candidate_claimed = ref false in
    let body =
      let* registry =
        Eta.Effect.sync (fun () ->
            Eta.Sync_lock.use driver.lock @@ fun () ->
            if serialized.next_session = Int64.max_int then
              invalid_arg
                "Eta_crux.Driver: serialized session identity exhausted";
            let registry =
              Remote_registry.create
                ~session:serialized.next_session
                ~authentication_key:serialized.authentication_key
            in
            serialized.next_session <-
              Int64.add serialized.next_session 1L;
            registry)
      in
      let* () =
        Eta.Effect.sync (fun () ->
            if not (Serialized_session.claim candidate) then
              invalid_arg
                "Eta_crux.Serialized_session.replace: candidate claimed";
            candidate_claimed := true;
            Serialized_session.set_wake candidate (fun () ->
                wake driver))
      in
      let failed_completion cause =
        let failure = latch_adapter_delivery_failure driver cause in
        Serialized_session.close candidate;
        Eta.Sync_lock.use driver.lock (fun () ->
            serialized.replacement_pending <- false;
            serialized.replacement_installing <- false);
        let completion = Eta.Promise.create () in
        let+ _ =
          Eta.Promise.resolve completion
            (Eta.Exit.Ok (Serialized_session.Crashed failure))
        in
        completion
      in
      let* encoded =
        Eta.Effect.sync (fun () ->
            try
              encoded_projection_or_delivery_cause driver serialized
                registry (Projection.Bootstrap snapshot)
            with exn ->
              Error
                (Failure.Packed_cause.make
                   ~pp_error:(fun _ (value : never) -> absurd value)
                   (Eta.Cause.die exn)))
      in
      match encoded with
      | Error cause -> failed_completion cause
      | Ok encoded ->
          let* installed =
            Eta.Effect.sync (fun () ->
                let completion = Eta.Promise.create () in
                Eta.Sync_lock.use driver.lock (fun () ->
                    Serialized_session.close serialized.candidate;
                    match
                      Serialized_session.send candidate (fun seq ->
                          Wire.Frame.Projection_deliver
                            {
                              seq;
                              reason = `Session_replacement;
                              content = encoded;
                            })
                    with
                    | Error _ -> Error ()
                    | Ok reply_to ->
                        let requests, inbound =
                          take_session_requests_locked driver
                        in
                        serialized.candidate <- candidate;
                        serialized.registry <- registry;
                        serialized.closure_observed <- false;
                        serialized.replacement_installing <- false;
                        driver.state <-
                          Replacement_delivering
                            (reply_to, completion);
                        Ok (completion, requests, inbound)))
          in
          (match installed with
          | Error () ->
              failed_completion
                (adapter_delivery_cause
                   "serialized replacement projection delivery failed")
          | Ok (completion, requests, inbound) ->
              let+ () = close_requests requests inbound in
              completion)
    in
    body
    |> Eta.Effect.map_error (fun (value : never) -> absurd value)
    |> Eta.Effect.on_error (fun _ ->
           Eta.Effect.sync (fun () ->
               if !candidate_claimed then
                 Serialized_session.close candidate;
               Eta.Sync_lock.use driver.lock (fun () ->
                   serialized.replacement_pending <- false;
                   serialized.replacement_installing <- false)))
  in
  let* completion = Eta.Effect.uninterruptible initiate in
  Eta.Promise.await completion |> Eta.Effect.map_error absurd

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

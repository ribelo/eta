open Crux_graph

module Failure = Crux_failure.Failure

module Codec = struct
  type decode_error = { message : string }
  type 'a t = {
    encode : 'a -> bytes;
    decode : bytes -> ('a, decode_error) result;
  }

  let make ~encode ~decode = { encode; decode }
  let encode codec value = codec.encode value
  let decode codec bytes = codec.decode bytes
end

let remote_handles :
    (int -> bytes option) option Domain.DLS.key =
  (Domain.DLS.new_key [@alert "-unsafe_multidomain"]) (fun () -> None)

let with_remote_handles lookup f =
  let previous =
    (Domain.DLS.get [@alert "-unsafe_multidomain"]) remote_handles
  in
  (Domain.DLS.set [@alert "-unsafe_multidomain"]) remote_handles
    (Some lookup);
  Fun.protect
    ~finally:(fun () ->
      (Domain.DLS.set [@alert "-unsafe_multidomain"]) remote_handles
        previous)
    f

let find_remote_handle identity =
  match
    (Domain.DLS.get [@alert "-unsafe_multidomain"]) remote_handles
  with
  | Some lookup -> lookup identity
  | None -> None

module Exported_endpoint = struct
  type 'a computation = 'a t

  type 'payload t = {
    identity : int;
    root : root_core;
    scope : int;
    codec : 'payload Codec.t;
    lock : Eta.Sync_lock.t;
    mutable target : 'payload Endpoint.t;
    mutable active : bool;
  }

  type availability_error =
    | Stale
    | Revoked

  type capacity_error = Full
  type admission = (unit, Endpoint.admission_error) result
  type try_result = (admission, capacity_error) result

  let remote_handle export =
    match find_remote_handle export.identity with
    | Some handle -> handle
    | None ->
        invalid_arg
          "Eta_crux.Exported_endpoint.remote_handle: not encoding serialized output"

  let serialized_invoke export payload =
    let target =
      Eta.Sync_lock.use export.lock @@ fun () ->
      if not export.active then Error Boundary_endpoint_revoked
      else Ok export.target
    in
    match target with
    | Error error -> error
    | Ok target -> (
        let decoded =
          try Codec.decode export.codec payload
          with exn ->
            latch_exception export.root
              ~origin:Failure.Export_dispatch
              ~trigger:Failure.Serialized_export_invocation exn;
            raise exn
        in
        match decoded with
        | Error _ -> Boundary_endpoint_malformed_payload
        | Ok payload -> (
            try
              match
                Eta.Queue.try_offer_now export.root.ingress
                  (Message
                     {
                       endpoint = target.core;
                       action = target.encode payload;
                       owner_scope = None;
                     })
              with
              | `Sent ->
                  ignore
                    (Eta.Queue.try_offer_now export.root.wake () : _);
                  Boundary_endpoint_accepted
              | `Full -> Boundary_endpoint_full
              | `Closed -> Boundary_endpoint_ingress_closed
              | `Dropped ->
                  invalid_arg
                    "Eta_crux.Exported_endpoint: bounded ingress dropped"
              | `Closed_with_error (_ : never) -> .
            with exn ->
              latch_exception export.root
                ~origin:Failure.Export_dispatch
                ~trigger:Failure.Serialized_export_invocation exn;
              raise exn))

  let register export =
    export.root.boundary_exports <-
      Int_map.add export.identity
        {
          identity = export.identity;
          kind =
            Boundary_endpoint
              { invoke = serialized_invoke export };
        }
        export.root.boundary_exports

  let unregister export =
    export.root.boundary_exports <-
      Int_map.remove export.identity
        export.root.boundary_exports

  let create target_description ~codec =
    let node = next_global "export node" in
    make_description @@ fun transaction scope ->
    let target = target_description.eval transaction scope in
    let key = (scope, node) in
    match transaction_get transaction key with
    | Some packed ->
        let export = (Obj.obj packed : _ t) in
        transaction.commit_hooks <-
          (fun () ->
            Eta.Sync_lock.use export.lock @@ fun () ->
            export.target <- target.value)
          :: transaction.commit_hooks;
        { value = export; version = target.version }
    | None ->
        let export =
          {
            identity = node;
            root = transaction.root;
            scope;
            codec;
            lock = Eta.Sync_lock.create ();
            target = target.value;
            active = false;
          }
        in
        transaction.commit_hooks <-
          (fun () ->
            export.active <- true;
            register export)
          :: transaction.commit_hooks;
        transaction.added_revokers <-
          ( scope,
            (fun () ->
              Eta.Sync_lock.use export.lock @@ fun () ->
              export.active <- false;
              unregister export) )
          :: transaction.added_revokers;
        transaction_set transaction key export;
        { value = export; version = fresh_version transaction.root }

  let try_invoke export payload =
    let target =
      Eta.Sync_lock.use export.lock @@ fun () ->
      if not export.active then Error Revoked
      else Ok export.target
    in
    let result =
      match target with
      | Error _ as error -> error
      | Ok target -> (
          try
            match
              Eta.Queue.try_offer_now export.root.ingress
                (Message
                   {
                     endpoint = target.core;
                     action = target.encode payload;
                     owner_scope = None;
                   })
            with
            | `Sent -> Ok (Ok (Ok ()))
            | `Full -> Ok (Error Full)
            | `Closed -> Ok (Ok (Error Endpoint.Ingress_closed))
            | `Dropped ->
                invalid_arg
                  "Eta_crux.Exported_endpoint.try_invoke: bounded ingress dropped"
            | `Closed_with_error (_ : never) -> .
          with exn ->
            latch_exception export.root ~origin:Failure.Export_dispatch
              ~trigger:Failure.Local_export_invocation exn;
            raise exn)
    in
    (match result with
    | Ok (Ok (Ok ())) ->
        ignore (Eta.Queue.try_offer_now export.root.wake () : _)
    | Ok (Ok (Error _)) | Ok (Error _) | Error _ -> ());
    result
end

module Host_operation = struct
  type ('request, 'response) t = {
    id : int;
    name : string;
    request : 'request Codec.t;
    response : 'response Codec.t;
  }

  type packed = Pack : ('request, 'response) t -> packed

  let valid_name name =
    let length = String.length name in
    let valid_first = function 'a' .. 'z' -> true | _ -> false in
    let valid_rest = function
      | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
      | _ -> false
    in
    length > 0
    && length <= 128
    && valid_first name.[0]
    &&
    let rec loop index =
      index = length || (valid_rest name.[index] && loop (index + 1))
    in
    loop 1

  let define ~name ~request ~response =
    if not (valid_name name) then
      invalid_arg "Eta_crux.Host_operation.define: invalid operation name";
    { id = next_global "host operation"; name; request; response }

  let name operation = operation.name
  let request_codec operation = operation.request
  let response_codec operation = operation.response
  let same
      (type request response other_request other_response)
      (left : (request, response) t)
      (right : (other_request, other_response) t) =
    left.id = right.id
end

module Request = struct
  type closure_reason =
    | Initiator_cancelled
    | Owner_disposed
    | Root_stopped
    | Root_crashed
    | Session_closed

  type not_pending = Not_pending

  type outbound_error =
    | Ingress_closed
    | Dispatch_failed
    | Closed of closure_reason

  type ('request, 'response) state = {
    operation : ('request, 'response) Host_operation.t;
    request : 'request;
    response : ('response, outbound_error) Eta.Promise.t;
    root : root_core;
    lock : Eta.Sync_lock.t;
    mutable pending : bool;
    mutable dispatch_completed : bool;
    mutable cancellation_handlers : (closure_reason -> unit) list;
    mutable closure_reason : closure_reason option;
  }

  module Driver_event = struct
    type t = Event : ('request, 'response) state -> t
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

    type handle_result =
      | Handled
      | Different_operation

    let resolve state response =
      let won =
        Eta.Sync_lock.use state.lock @@ fun () ->
        if state.pending then (
          state.pending <- false;
          true)
        else false
      in
      if not won then Eta.Effect.pure (Error Not_pending)
      else
        Eta.Promise.resolve state.response (Eta.Exit.Ok response)
        |> Eta.Effect.map (fun _ -> Ok ())

    let on_cancel state handler =
      let reason =
        Eta.Sync_lock.use state.lock @@ fun () ->
        if state.pending then (
          state.cancellation_handlers <-
            handler :: state.cancellation_handlers;
          None)
        else state.closure_reason
      in
      Option.iter handler reason

    let dispatch (Event state) handler =
      handler.handle ~operation:state.operation ~request:state.request
        ~resolve:(resolve state) ~on_cancel:(on_cancel state)

    let handle (type request response error) (Event state)
        (operation : (request, response) Host_operation.t) ~f :
        (handle_result, error) Eta.Effect.t =
      if not (Host_operation.same state.operation operation) then
        Eta.Effect.pure Different_operation
      else
        let state : (request, response) state = Obj.magic state in
        f state.request ~resolve:(resolve state) ~on_cancel:(on_cancel state)
        |> Eta.Effect.map (fun () -> Handled)

    let complete state =
      Eta.Sync_lock.use state.lock @@ fun () ->
      if state.dispatch_completed then Error Already_completed
      else (
        state.dispatch_completed <- true;
        Ok ())

    let accepted (Event state) =
      Eta.Effect.sync (fun () -> complete state)

    let fail_with_trigger state cause trigger =
      let completion = complete state in
      match completion with
      | Error _ -> Eta.Effect.pure completion
      | Ok () ->
          let won =
            Eta.Sync_lock.use state.lock @@ fun () ->
            if state.pending then (
              state.pending <- false;
              true)
            else false
          in
          let record_failure () =
            latch_failure_record state.root
              (failure_record state.root ~origin:Failure.Request_dispatch
                 ~trigger cause)
          in
          if won then
            let open Eta.Syntax in
            let* () = Eta.Effect.sync record_failure in
            let+ _ =
              Eta.Promise.resolve state.response
                (Eta.Exit.Error (Eta.Cause.Fail Dispatch_failed))
            in
            completion
          else Eta.Effect.pure completion

    let failed (Event state) cause =
      fail_with_trigger state cause Failure.Outbound_request

    let failed_inbound_response (Event state) cause =
      let won =
        Eta.Sync_lock.use state.lock @@ fun () ->
        if state.pending then (
          state.pending <- false;
          true)
        else false
      in
      if not won then Eta.Effect.pure (Error Already_completed)
      else
        let open Eta.Syntax in
        let* () =
          Eta.Effect.sync (fun () ->
              latch_failure_record state.root
                (failure_record state.root
                   ~origin:Failure.Request_dispatch
                   ~trigger:Failure.Inbound_response cause))
        in
        let+ _ =
          Eta.Promise.resolve state.response
            (Eta.Exit.Error (Eta.Cause.Fail Dispatch_failed))
        in
        Ok ()
  end

  let cancel_state state reason =
    let handlers =
      Eta.Sync_lock.use state.lock @@ fun () ->
      if state.pending then (
        state.pending <- false;
        state.dispatch_completed <- true;
        state.closure_reason <- Some reason;
        let handlers = List.rev state.cancellation_handlers in
        state.cancellation_handlers <- [];
        Some handlers)
      else None
    in
    match handlers with
    | None -> false
    | Some handlers ->
        List.iter (fun handler -> handler reason) handlers;
        true

  let close_state state reason =
    let won = cancel_state state reason in
    if not won then Eta.Effect.pure false
    else
      Eta.Promise.resolve state.response
        (Eta.Exit.Error (Eta.Cause.Fail (Closed reason)))
end

type binding_core = {
  operations : (string, Host_operation.packed) Hashtbl.t;
  mutable root : root_core option;
  mutable push_request : (Request.Driver_event.t -> unit) option;
}

let make_binding operations =
  let table = Hashtbl.create (List.length operations) in
  List.iter
    (fun ((Host_operation.Pack operation as packed) :
           Host_operation.packed) ->
      if Hashtbl.mem table operation.name then
        invalid_arg
          ("Eta_crux.Driver.Binding: duplicate operation " ^ operation.name);
      Hashtbl.add table operation.name packed)
    operations;
  { operations = table; root = None; push_request = None }

module Requester = struct
  type ('request, 'response) t = {
    binding : binding_core;
    operation : ('request, 'response) Host_operation.t;
  }

  type error = Request.outbound_error =
    | Ingress_closed
    | Dispatch_failed
    | Closed of Request.closure_reason

  let request requester request =
    let open Eta.Syntax in
    let* owner = current_owned_context () in
    let* root, push =
      Eta.Effect.sync_result (fun () ->
          match requester.binding.root, requester.binding.push_request with
          | Some root, Some push -> Ok (root, push)
          | None, _ | _, None -> Error Ingress_closed)
    in
    let* () = Eta.Semaphore.acquire root.request_slots 1 in
    let response = Eta.Promise.create () in
    let state =
      {
        Request.operation = requester.operation;
        request;
        response;
        root;
        lock = Eta.Sync_lock.create ();
        pending = true;
        dispatch_completed = false;
        cancellation_handlers = [];
        closure_reason = None;
      }
    in
    let body =
      let* () =
        Eta.Effect.sync (fun () ->
            push (Request.Driver_event.Event state);
            ignore (Eta.Queue.try_offer_now root.wake () : _))
      in
      Eta.Promise.await response
      |> Eta.Effect.on_interrupt (fun _ ->
             Eta.Effect.sync (fun () ->
                 let reason =
                   Eta.Sync_lock.use root.lock @@ fun () ->
                   match root.failure with
                   | Some _ -> Request.Root_crashed
                   | None when root.stop_requested ->
                       Request.Root_stopped
                   | None -> (
                       match owner with
                       | Some owned when owned.root == root -> (
                           match
                             Int_map.find_opt owned.scope root.scopes
                           with
                           | Some scope when scope.active ->
                               Request.Initiator_cancelled
                           | Some _ | None ->
                               Request.Owner_disposed)
                       | Some _ | None ->
                           Request.Initiator_cancelled)
                 in
                 ignore
                   (Request.cancel_state state
                      reason : bool)))
    in
    Eta.Effect.finally
      (Eta.Effect.sync (fun () -> Eta.Semaphore.release root.request_slots 1))
      body
end

module Responder = struct
  type 'response t = {
    resolve_response :
      'response -> ((unit, Request.not_pending) result, never) Eta.Effect.t;
  }

  type error = Request.not_pending

  let resolve responder response =
    responder.resolve_response response
    |> Eta.Effect.map_error absurd
    |> Eta.Effect.bind (function
         | Ok () -> Eta.Effect.unit
         | Error error -> Eta.Effect.fail error)
end

module Request_export = struct
  type 'a computation = 'a t

  type pending_request = {
    identity : int;
    close_now : boundary_request_closure -> unit;
  }

  type ('request, 'response) t = {
    identity : int;
    root : root_core;
    scope : int;
    request_codec : 'request Codec.t;
    response_codec : 'response Codec.t;
    lock : Eta.Sync_lock.t;
    mutable target : ('request * 'response Responder.t) Endpoint.t;
    mutable active : bool;
    mutable pending_requests : pending_request list;
  }

  type availability_error =
    | Stale
    | Revoked

  type invoke_error =
    | Unavailable of availability_error
    | Request_capacity_full
    | Ingress_capacity_full
    | Ingress_closed
    | Closed of Request.closure_reason

  let remote_handle export =
    match find_remote_handle export.identity with
    | Some handle -> handle
    | None ->
        invalid_arg
          "Eta_crux.Request_export.remote_handle: not encoding serialized output"

  let remove_pending export identity =
    Eta.Sync_lock.use export.lock @@ fun () ->
    export.pending_requests <-
      List.filter
        (fun (pending : pending_request) ->
          pending.identity <> identity)
        export.pending_requests

  let public_closure_reason = function
    | Boundary_initiator_cancelled -> Request.Initiator_cancelled
    | Boundary_owner_disposed -> Request.Owner_disposed
    | Boundary_root_stopped -> Request.Root_stopped
    | Boundary_root_crashed -> Request.Root_crashed
    | Boundary_session_closed -> Request.Session_closed

  let await_completion completion =
    Eta.Queue.take completion
    |> Eta.Effect.map_error (function
         | `Closed ->
             invalid_arg
               "Eta_crux.Request_export: completion queue closed"
         | `Closed_with_error (_ : never) -> .)

  let serialized_start export payload =
    let decoded =
      try Codec.decode export.request_codec payload
      with exn ->
        latch_exception export.root ~origin:Failure.Export_dispatch
          ~trigger:Failure.Serialized_export_invocation exn;
        raise exn
    in
    match decoded with
    | Error _ -> Eta.Effect.pure Boundary_request_malformed_payload
    | Ok request ->
        let result =
          Eta.Sync_lock.use export.lock @@ fun () ->
          if not export.active then Boundary_request_revoked
          else if
            not (Eta.Semaphore.try_acquire export.root.request_slots 1)
          then Boundary_request_capacity_full
          else
            let identity = next_global "pending request export" in
            let completion = Eta.Queue.dropping ~capacity:1 () in
            let request_lock = Eta.Sync_lock.create () in
            let pending = ref true in
            let finish_now completion_value =
              let won =
                Eta.Sync_lock.use request_lock @@ fun () ->
                if !pending then (
                  pending := false;
                  true)
                else false
              in
              if won then (
                Eta.Semaphore.release export.root.request_slots 1;
                remove_pending export identity;
                match
                  Eta.Queue.try_offer_now completion completion_value
                with
                | `Sent -> Boundary_request_accepted
                | `Dropped | `Full | `Closed ->
                    invalid_arg
                      "Eta_crux.Request_export: completion handoff failed"
                | `Closed_with_error (_ : never) -> .)
              else Boundary_request_not_pending
            in
            let responder =
              {
                Responder.resolve_response =
                  (fun response ->
                    let encoded =
                      try Codec.encode export.response_codec response
                      with exn ->
                        latch_exception export.root
                          ~origin:Failure.Export_dispatch
                          ~trigger:
                            Failure.Serialized_export_invocation exn;
                        raise exn
                    in
                    Eta.Effect.sync (fun () ->
                        match
                          finish_now
                            (Boundary_request_resolved encoded)
                        with
                        | Boundary_request_accepted -> Ok ()
                        | Boundary_request_not_pending ->
                            Error Request.Not_pending));
              }
            in
            let close_now reason =
              ignore
                (finish_now (Boundary_request_closed reason) :
                  boundary_request_identity_result)
            in
            export.pending_requests <-
              { identity; close_now } :: export.pending_requests;
            let abandon () =
              pending := false;
              export.pending_requests <-
                List.filter
                  (fun (request : pending_request) ->
                    request.identity <> identity)
                  export.pending_requests;
              Eta.Semaphore.release export.root.request_slots 1
            in
            let admission =
              try
                Eta.Queue.try_offer_now export.root.ingress
                  (Message
                     {
                       endpoint = export.target.core;
                       action =
                         export.target.encode (request, responder);
                       owner_scope = None;
                     })
              with exn ->
                abandon ();
                latch_exception export.root
                  ~origin:Failure.Export_dispatch
                  ~trigger:Failure.Serialized_export_invocation exn;
                raise exn
            in
            match admission with
            | `Full ->
                abandon ();
                Boundary_ingress_capacity_full
            | `Closed ->
                abandon ();
                Boundary_request_ingress_closed
            | `Dropped ->
                abandon ();
                invalid_arg
                  "Eta_crux.Request_export: bounded ingress dropped"
            | `Closed_with_error (_ : never) -> .
            | `Sent ->
                ignore (Eta.Queue.try_offer_now export.root.wake () : _);
                Boundary_request_started
                  {
                    completion = await_completion completion;
                    cancel_by_peer =
                      (fun () -> Eta.Effect.sync (fun () ->
                           finish_now
                             Boundary_request_cancelled_by_peer));
                    close =
                      (fun reason -> Eta.Effect.sync (fun () ->
                           finish_now
                             (Boundary_request_closed reason)));
                  }
        in
        Eta.Effect.pure result

  let unregister export =
    export.root.boundary_exports <-
      Int_map.remove export.identity export.root.boundary_exports

  let revoke export reason =
    let pending =
      Eta.Sync_lock.use export.lock @@ fun () ->
      export.active <- false;
      let pending = export.pending_requests in
      export.pending_requests <- [];
      pending
    in
    unregister export;
    List.iter (fun request -> request.close_now reason) pending

  let register export =
    export.root.boundary_exports <-
      Int_map.add export.identity
        {
          identity = export.identity;
          kind =
            Boundary_request
              {
                start = serialized_start export;
                close_all = revoke export;
              };
        }
        export.root.boundary_exports

  let create target_description ~request ~response =
    let node = next_global "request export node" in
    make_description @@ fun transaction scope ->
    let target = target_description.eval transaction scope in
    let key = (scope, node) in
    match transaction_get transaction key with
    | Some packed ->
        let export = (Obj.obj packed : (_, _) t) in
        transaction.commit_hooks <-
          (fun () ->
            Eta.Sync_lock.use export.lock @@ fun () ->
            export.target <- target.value)
          :: transaction.commit_hooks;
        { value = export; version = target.version }
    | None ->
        let export =
          {
            identity = node;
            root = transaction.root;
            scope;
            request_codec = request;
            response_codec = response;
            lock = Eta.Sync_lock.create ();
            target = target.value;
            active = false;
            pending_requests = [];
          }
        in
        transaction.commit_hooks <-
          (fun () ->
            export.active <- true;
            register export)
          :: transaction.commit_hooks;
        transaction.added_revokers <-
          ( scope,
            (fun () -> revoke export Boundary_owner_disposed) )
          :: transaction.added_revokers;
        transaction_set transaction key export;
        { value = export; version = fresh_version transaction.root }

  let invoke export request =
    let setup =
      Eta.Sync_lock.use export.lock @@ fun () ->
      if not export.active then `Error (Unavailable Revoked)
      else if
        not (Eta.Semaphore.try_acquire export.root.request_slots 1)
      then `Error Request_capacity_full
      else
        let identity = next_global "pending local request export" in
        let completion = Eta.Queue.dropping ~capacity:1 () in
        let request_lock = Eta.Sync_lock.create () in
        let pending = ref true in
        let finish_now result =
          let won =
            Eta.Sync_lock.use request_lock @@ fun () ->
            if !pending then (
              pending := false;
              true)
            else false
          in
          if won then (
            Eta.Semaphore.release export.root.request_slots 1;
            remove_pending export identity;
            match Eta.Queue.try_offer_now completion result with
            | `Sent -> true
            | `Dropped | `Full | `Closed ->
                invalid_arg
                  "Eta_crux.Request_export: local completion handoff failed"
            | `Closed_with_error (_ : never) -> .)
          else false
        in
        let responder =
          {
            Responder.resolve_response =
              (fun value ->
                Eta.Effect.sync (fun () ->
                    if finish_now (Ok value) then Ok ()
                    else Error Request.Not_pending));
          }
        in
        let close_now reason =
          ignore
            (finish_now (Error (public_closure_reason reason)) : bool)
        in
        export.pending_requests <-
          { identity; close_now } :: export.pending_requests;
        let abandon () =
          pending := false;
          export.pending_requests <-
            List.filter
              (fun (request : pending_request) ->
                request.identity <> identity)
              export.pending_requests;
          Eta.Semaphore.release export.root.request_slots 1
        in
        let admission =
          try
            Eta.Queue.try_offer_now export.root.ingress
              (Message
                 {
                   endpoint = export.target.core;
                   action =
                     export.target.encode (request, responder);
                   owner_scope = None;
                 })
          with exn ->
            abandon ();
            latch_exception export.root ~origin:Failure.Export_dispatch
              ~trigger:Failure.Local_export_invocation exn;
            raise exn
        in
        match admission with
        | `Full ->
            abandon ();
            `Error Ingress_capacity_full
        | `Closed ->
            abandon ();
            `Error Ingress_closed
        | `Dropped ->
            abandon ();
            invalid_arg
              "Eta_crux.Request_export.invoke: bounded ingress dropped"
        | `Closed_with_error (_ : never) -> .
        | `Sent ->
            ignore (Eta.Queue.try_offer_now export.root.wake () : _);
            `Started (completion, finish_now)
    in
    match setup with
    | `Error error -> Eta.Effect.fail error
    | `Started (completion, finish_now) ->
        let open Eta.Syntax in
        Eta.Effect.finally
          (Eta.Effect.sync (fun () ->
               ignore
                 (finish_now
                    (Error Request.Initiator_cancelled) : bool)))
          (let* result = await_completion completion in
           match result with
           | Ok response -> Eta.Effect.pure response
           | Error reason -> Eta.Effect.fail (Closed reason))
end

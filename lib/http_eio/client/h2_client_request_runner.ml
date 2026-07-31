(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module Body_source = Source
module H2_proto = Eta_http_h2

module Errors = H2_client_errors
module Request_writer = H2_client_request_writer
module Response_reader = H2_client_response_reader

let informational_status = Response_reader.informational_status

let rec has_finalizer_diagnostic = function
  | Eta.Cause.Finalizer _ | Eta.Cause.Suppressed _ -> true
  | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
      List.exists has_finalizer_diagnostic causes
  | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _ -> false

let cause_of_list = function
  | [] -> invalid_arg "eta_http.h2.race_upload_response: empty cause list"
  | [ cause ] -> cause
  | causes -> Eta.Cause.concurrent causes

let race_upload_response response writer =
  Eta.Spi.Expert.make ~leaf_name:"eta_http.h2.race_upload_response" (fun context ->
      let contract = Eta.Spi.Expert.contract context in
      let results = contract.create_stream 2 in
      let outcome = ref None in
      let switch_diagnostics = ref [] in
      let exception Race_finished in
      let rec contains_race_finished exn =
        match exn with
        | Race_finished -> true
        | exn -> (
            match contract.multiple_exceptions exn with
            | None -> false
            | Some exceptions ->
                List.exists
                  (fun (exn, _backtrace) -> contains_race_finished exn)
                  exceptions)
      in
      let rec causes_without_race_finished exn =
        match exn with
        | Race_finished -> []
        | exn -> (
            match contract.multiple_exceptions exn with
            | Some exceptions ->
                List.concat_map
                  (fun (exn, _backtrace) ->
                    if contains_race_finished exn then
                      causes_without_race_finished exn
                    else
                      match Eta.Spi.Expert.exit_of_exn context exn with
                      | Eta.Exit.Error cause -> [ cause ]
                      | Eta.Exit.Ok _ -> [])
                  exceptions
            | None -> (
                match Eta.Spi.Expert.exit_of_exn context exn with
                | Eta.Exit.Error cause -> [ cause ]
                | Eta.Exit.Ok _ -> []))
      in
      let run race_scope eff =
        let exit =
          try Eta.Spi.Expert.eval_in_scope context race_scope eff
          with exn -> Eta.Spi.Expert.exit_of_exn context exn
        in
        contract.stream_add results exit
      in
      let finish race_scope first =
        contract.fail_scope race_scope Race_finished;
        let loser = ref None in
        (try
           contract.protect (fun () ->
               loser := Some (contract.stream_take results))
         with exn ->
           if Option.is_none (contract.cancellation_reason exn) then
             match exn with Race_finished -> () | exn -> raise exn);
        let diagnostics =
          match !loser with
          | Some (Eta.Exit.Error cause) when has_finalizer_diagnostic cause ->
              [ cause ]
          | Some (Eta.Exit.Ok _) | Some (Eta.Exit.Error _) | None -> []
        in
        outcome := Some (first, diagnostics);
        raise Race_finished
      in
      (try
         contract.run_scope ~name:"eta_http.h2.race_upload_response"
           (fun race_scope ->
             contract.fork race_scope (fun () ->
                 run race_scope
                   (response
                   |> Eta.Effect.map (fun value -> `Response value)));
             contract.fork race_scope (fun () ->
                 run race_scope
                   (writer |> Eta.Effect.map (fun () -> `Writer)));
             match contract.stream_take results with
             | Eta.Exit.Ok `Writer ->
                 (* Keep the original response waiter and its deadline alive. *)
                 outcome := Some (contract.stream_take results, [])
             | first -> finish race_scope first)
       with
       | Race_finished -> ()
       | exn when contains_race_finished exn ->
           switch_diagnostics :=
             causes_without_race_finished exn
             |> List.filter has_finalizer_diagnostic);
      match !outcome with
      | Some (Eta.Exit.Ok (`Response response), diagnostics) ->
          let diagnostics = diagnostics @ !switch_diagnostics in
          if diagnostics = [] then Eta.Exit.Ok response
          else Eta.Exit.Error (cause_of_list diagnostics)
      | Some (Eta.Exit.Error primary, diagnostics) ->
          let diagnostics = diagnostics @ !switch_diagnostics in
          if diagnostics = [] then Eta.Exit.Error primary
          else Eta.Exit.Error (cause_of_list (primary :: diagnostics))
      | Some (Eta.Exit.Ok `Writer, _) ->
          Eta.Spi.Expert.exit_of_exn context
            (Failure "eta_http.h2.race_upload_response: duplicate writer exit")
      | None ->
          Eta.Spi.Expert.exit_of_exn context
            (Failure "eta_http.h2.race_upload_response: missing outcome"))

let request_on_connection connection request url =
  let response_idle_timeout =
    Request.Response_idle_timeout.to_ms request.Request.response_idle_timeout
  in
  let with_timeout ~on_timeout eff =
    match response_idle_timeout with
    | None -> eff
    | Some milliseconds ->
        Eta.Effect.timeout_as
          (Eta.Duration.ms milliseconds)
          ~on_timeout eff
  in
  let header_timeout =
    Errors.error request
      (Response_header_timeout
         { timeout_ms = response_idle_timeout })
  in
  let body_timeout =
    Errors.error request
      (Response_body_idle_timeout
         { timeout_ms = response_idle_timeout })
  in
  let with_body_timeout body =
    match response_idle_timeout with
    | None -> body
    | Some milliseconds ->
        Body.of_reader ~release:(fun () -> Body.discard body) (fun () ->
            Eta.Effect.timeout_as
              (Eta.Duration.ms milliseconds)
              ~on_timeout:body_timeout (Body.read body)
            |> Eta.Effect.map (function
                 | None -> Body.End
                 | Some chunk -> Body.Chunk chunk))
  in
  let header_progress_mutex = Eio.Mutex.create () in
  let header_progress = ref 0 in
  let progress_promise, progress_resolver = Eio.Promise.create () in
  let header_progress_promise = ref progress_promise in
  let header_progress_resolver = ref progress_resolver in
  let note_header_progress () =
    Eio.Mutex.lock header_progress_mutex;
    let resolver = !header_progress_resolver in
    incr header_progress;
    let promise, next_resolver = Eio.Promise.create () in
    header_progress_promise := promise;
    header_progress_resolver := next_resolver;
    Eio.Mutex.unlock header_progress_mutex;
    ignore (Eio.Promise.try_resolve resolver ())
  in
  let await_header_progress observed =
    Eta.Effect.sync (fun () ->
        Eio.Mutex.lock header_progress_mutex;
        let state =
          if !header_progress <> observed then `Progress !header_progress
          else `Wait !header_progress_promise
        in
        Eio.Mutex.unlock header_progress_mutex;
        match state with
        | `Progress progress -> progress
        | `Wait promise ->
            Eio.Promise.await promise;
            Eio.Mutex.lock header_progress_mutex;
            let progress = !header_progress in
            Eio.Mutex.unlock header_progress_mutex;
            progress)
  in
  let mux = Connection.mux connection in
  let result, resolver = Eio.Promise.create () in
  let body_error = ref None in
  let response_started = ref false in
  let response_returned = ref false in
  let body_wake = ref (fun () -> ()) in
  let unregister_failure = ref (fun () -> ()) in
  let trailers, resolve_trailers, resolve_empty_trailers, resolve_trailer_error =
    Response_reader.trailer_result request
  in
  let unregister () =
    let f = !unregister_failure in
    unregister_failure := (fun () -> ());
    f ()
  in
  let resolve_result value = ignore (Eio.Promise.try_resolve resolver value) in
  let resolve_error error =
    unregister ();
    resolve_result (Error error)
  in
  let set_body_error error =
    body_error := Some error;
    resolve_trailer_error error;
    !body_wake ()
  in
  let open_request h2_request =
    Connection.request connection ~tag:0 h2_request
      ~trailers_handler:(fun headers -> resolve_trailers headers)
      ~error_handler:(fun stream error ->
        Multiplexer.mark_remote_reset mux
          (Stream_state.id stream);
        let error =
          Errors.protocol_violation request "stream"
            (Errors.pp_client_error error)
        in
        if !response_started then set_body_error error else resolve_error error)
      ~response_handler:(fun stream response body ->
        let status = response.H2_proto.Connection.Client.status in
        let headers = Response_reader.response_headers response in
        match Security.validate_headers headers with
        | Some kind ->
            H2_proto.Body.Reader.close body;
            ignore (Multiplexer.release mux stream);
            resolve_error (Errors.error request kind)
        | None when Response_reader.informational_status status ->
            note_header_progress ()
        | None when Response_reader.response_has_body request status ->
            response_started := true;
            let body =
              Response_reader.response_body ~request ~mux ~body_error ~body_wake
                ~unregister ~resolve_empty_trailers ~resolve_trailer_error
                stream body
              |> with_body_timeout
            in
            let response = Response.make ~status ~headers ~trailers ~body () in
            resolve_result (Ok response)
        | None ->
            response_started := true;
            let response =
              Response.make ~status ~headers ~trailers ~body:(Body.empty ()) ()
            in
            resolve_result (Ok response);
            Response_reader.close_no_body ~mux ~unregister
              ~resolve_empty_trailers stream body)
  in
  let rec wait_for_response_from observed =
    let response =
      Eta.Effect.sync (fun () -> Eio.Promise.await result)
      |> Eta.Effect.map (fun response -> `Response response)
    in
    let progress =
      await_header_progress observed
      |> Eta.Effect.map (fun progress -> `Progress progress)
    in
    Eta.Effect.race [ response; progress ]
    |> with_timeout ~on_timeout:header_timeout
    |> Eta.Effect.bind (function
         | `Progress progress -> wait_for_response_from progress
         | `Response (Ok response) ->
             response_returned := true;
             Eta.Effect.pure response
         | `Response (Error error) -> Eta.Effect.fail error)
  in
  let wait_for_response () = wait_for_response_from !header_progress in
  Body_source.with_owned_stream (Request.body_source request.body) (fun upload ->
      unregister_failure :=
        Connection.register_failure_handler connection (fun kind ->
            let error = Errors.error request kind in
            if !response_started then set_body_error error
            else resolve_error error);
      match Request_writer.request_of_request request url with
      | Error error ->
          resolve_error error;
          Eta.Effect.fail error
      | Ok h2_request -> (
          match open_request h2_request with
          | Error (Admission_rejected { limit }) ->
              let error =
                Errors.error request (Stream_admission_rejected { limit })
              in
              resolve_error error;
              Eta.Effect.fail error
          | Error Connection_closed ->
              let error = Errors.closed request Http_request in
              resolve_error error;
              Eta.Effect.fail error
          | Error (Request_failed message) ->
              let error = Errors.protocol_violation request "request" message in
              resolve_error error;
              Eta.Effect.fail error
          | Ok opened ->
              let release_unreturned_request () =
                if !response_returned then Eta.Effect.unit
                else
                  Eta.Effect.sync (fun () ->
                      unregister ();
                      (try
                         H2_proto.Body.Writer.close opened.request_body
                       with _ -> ());
                      ignore (Multiplexer.release mux opened.stream))
              in
              let write_request =
                Request_writer.write_body opened.request_body request.body upload
                |> Eta.Effect.bind (fun () ->
                       Request_writer.close_request_body opened.request_body)
              in
              let race_response_and_writer () =
                let write_request =
                  write_request
                  |> Eta.Effect.bind_error (fun error ->
                         if not !response_started then resolve_error error;
                         Eta.Effect.fail error)
                in
                Eta.Effect.race
                  [
                    wait_for_response () |> Eta.Effect.to_result;
                    (write_request
                    |> Eta.Effect.bind (fun () -> wait_for_response ())
                    |> Eta.Effect.map Result.ok);
                  ]
                |> Eta.Effect.bind (function
                     | Ok response -> Eta.Effect.pure response
                     | Error error -> Eta.Effect.fail error)
              in
              let race_one_shot_response_and_writer () =
                race_upload_response (wait_for_response ()) write_request
              in
              let response_or_writer =
                match request.body with
                | Empty ->
                    Request_writer.close_request_body opened.request_body
                    |> Eta.Effect.bind (fun () -> wait_for_response ())
                | Fixed [] ->
                    Request_writer.close_request_body opened.request_body
                    |> Eta.Effect.bind (fun () -> wait_for_response ())
                | One_shot_stream _ -> race_one_shot_response_and_writer ()
                | Fixed _ | Stream _ | Rewindable_stream _ ->
                    race_response_and_writer ()
              in
              Eta.Effect.with_scope
                (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
                   ~release:(fun () ->
                     Request_writer.close_request_body opened.request_body)
                |> Eta.Effect.bind (fun () -> response_or_writer))
              |> fun request_effect ->
              Eta.Effect.with_scope
                (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
                   ~release:release_unreturned_request
                |> Eta.Effect.bind (fun () -> request_effect))))
